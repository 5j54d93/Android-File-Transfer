//
//  BrowserViewModel.swift
//  Android-File-Transfer
//
//  Created by Ricky on 2026/5/29.
//

import SwiftUI
import MTPKit

/// Drives the file browser for one storage: current directory, listing, selection,
/// and (crucially) applies the transport's live `DeviceChange` events so the list
/// updates the instant a file is added/removed on the device — no refresh, no reopen.
@MainActor
@Observable
final class BrowserViewModel {
    private(set) var transport: (any DeviceTransport)?
    private(set) var storage: StorageInfo?
    /// Directories from the storage root down to the current folder. Empty == root.
    private(set) var pathStack: [FileNode] = []
    private(set) var entries: [FileNode] = []
    var selection: Set<String> = []
    private(set) var isLoading = false
    var errorMessage: String?

    @ObservationIgnored private var observeTask: Task<Void, Never>?
    @ObservationIgnored private var observingTransportID: String?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var storageRefreshTask: Task<Void, Never>?
    /// Cached directory listings (key: "storageID/parentID") so navigating back to a folder
    /// we've already seen is instant — no spinner. A silent re-fetch still runs to catch any
    /// device-side changes. Cleared when the storage changes.
    @ObservationIgnored private var listingCache: [String: [FileNode]] = [:]
    /// True while `reload()` is fetching, so the 3s poll doesn't reconcile against a folder
    /// that's mid-load (covers both spinner loads and silent cached re-fetches).
    @ObservationIgnored private var isReloading = false
    /// Reports whether a file transfer is in flight. While one is, the 3s poll and the
    /// per-change storage-gauge refreshes are skipped so they don't compete with the transfer
    /// on the single serial MTP channel (wired by the app from `TransferManager.activeCount`).
    @ObservationIgnored var isTransferActive: () -> Bool = { false }
    @ObservationIgnored var alerts: AppAlerts?
    /// Called (debounced) when the device's free space likely changed, so the sidebar's
    /// per-device storage figures can refresh too — not just this view's path-bar gauge.
    @ObservationIgnored var onStorageShouldRefresh: (() -> Void)?
    /// Called when an operation fails because the USB connection was lost, so the app can offer
    /// to reset + re-discover the device (and, if that can't recover it, fall back to the
    /// "connect / re-enable File Transfer" empty state).
    @ObservationIgnored var onConnectionLost: (() -> Void)?

    /// True while the app is frontmost. The 3s reconcile poll only runs when active — syncing a
    /// window the user can't see is pointless and just competes for the serial MTP channel.
    @ObservationIgnored private var isAppActive = true
    /// After a transfer batch the poll stays quiet for this long, so the device can finalize the
    /// file(s) — a large write leaves it rebuilding its object database — before background reads
    /// pile back onto the same serial channel and slow down whatever the user does next.
    @ObservationIgnored private var transferCooldownUntil: Date?
    private let postTransferCooldown: TimeInterval = 3

    /// Files just added (e.g. by an upload) are shown immediately from the device's "added" event,
    /// but Android can lag a few seconds before they appear in GetObjectHandles. Without this the
    /// 3s poll would briefly remove the just-uploaded file ("device doesn't list it") and then
    /// re-add it — a visible flicker/"wait". So we protect freshly-added ids from poll-removal for
    /// a short grace window; after it expires the device's real listing wins.
    @ObservationIgnored private var recentlyAddedIDs: [String: Date] = [:]
    @ObservationIgnored private var recentlyAddedNodes: [String: FileNode] = [:]
    private let recentAddGrace: TimeInterval = 8

    var currentParentID: String? { pathStack.last?.id }
    var storageID: String? { storage?.id }
    var canGoUp: Bool { !pathStack.isEmpty }
    var isMock: Bool { transport?.kind == .mock }

    // MARK: Navigation

    func open(_ transport: any DeviceTransport, storage: StorageInfo) {
        let isSameStorage = self.transport?.id == transport.id && self.storage?.id == storage.id
        self.transport = transport
        self.storage = storage
        if !isSameStorage {
            pathStack = []
            entries = []
            selection = []
            listingCache = [:]
        }
        if observingTransportID != transport.id {
            startObserving(transport)
            observingTransportID = transport.id
        }
        startPolling()
        Task { await reload() }
    }

    /// Clear back to the "nothing selected" state so the detail pane shows its placeholder.
    func reset() {
        stopPolling()
        storageRefreshTask?.cancel()
        transport = nil
        storage = nil
        pathStack = []
        entries = []
        selection = []
        errorMessage = nil
        listingCache = [:]
    }

    /// Re-fetch the current storage's capacity/free figures — they change as files are added
    /// or removed — so the path-bar gauge reflects the device's real free space.
    func refreshStorageInfo() async {
        guard let transport, let storageID else { return }
        // Run the blocking MTP read off the main actor — otherwise the USB round-trip executes on
        // the main thread and freezes the UI for its full duration (~1s right after a write).
        let all = try? await Task.detached(priority: .userInitiated) {
            try await transport.storages()
        }.value
        if let updated = all?.first(where: { $0.id == storageID }) {
            storage = updated
        }
    }

    // MARK: App-active gating

    /// Called by the app as it gains/loses frontmost focus. The poll only runs while active;
    /// on re-activation we reconcile once immediately to catch up on anything missed while away.
    func setAppActive(_ active: Bool) {
        guard active != isAppActive else { return }
        isAppActive = active
        if active { Task { await silentReconcile() } }
    }

    /// Coalesce a burst of change events (e.g. a multi-file transfer or delete) into a single
    /// storage refresh shortly after they settle.
    private func scheduleStorageRefresh() {
        // Don't refresh storage figures mid-transfer — the burst of change events would flood
        // the serial MTP channel. The app does a single refresh once transfers finish.
        guard !isTransferActive() else { return }
        storageRefreshTask?.cancel()
        storageRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled, !self.isTransferActive() else { return }
            await self.refreshStorageInfo()
            self.onStorageShouldRefresh?()
        }
    }

    func cancelPendingStorageRefresh() {
        storageRefreshTask?.cancel()
    }

    func refreshStorageAfterTransferBatch() {
        // Quiet the background poll for a moment so the device can finalize the just-written
        // file(s) before automatic reads resume on the serial channel.
        transferCooldownUntil = Date().addingTimeInterval(postTransferCooldown)
        storageRefreshTask?.cancel()
        storageRefreshTask = Task { [weak self] in
            // Brief grace period: if the user navigates right after a transfer, their folder
            // listing should reach the serial device first instead of queuing behind this
            // multi-transaction storage refresh.
            try? await Task.sleep(for: .milliseconds(800))
            guard let self, !Task.isCancelled, !self.isTransferActive() else { return }
            await self.refreshStorageInfo()
            self.onStorageShouldRefresh?()
        }
    }

    func enter(_ folder: FileNode) {
        guard folder.isDirectory else { return }
        cacheCurrentListing()
        pathStack.append(folder)
        selection = []
        showCachedListingOrLoading(forParent: folder.id)
        Task { await reload() }
    }

    func goUp() {
        guard canGoUp else { return }
        cacheCurrentListing()
        pathStack.removeLast()
        selection = []
        showCachedListingOrLoading(forParent: currentParentID)
        Task { await reload() }
    }

    /// Breadcrumb jump. `depth == 0` is the storage root; `depth == k` keeps the first k folders.
    func navigate(toDepth depth: Int) {
        guard depth < pathStack.count else { return }
        cacheCurrentListing()
        pathStack.removeLast(pathStack.count - depth)
        selection = []
        showCachedListingOrLoading(forParent: currentParentID)
        Task { await reload() }
    }

    private func cacheKey(_ parentID: String?, in storageID: String) -> String {
        "\(storageID)/\(parentID ?? "")"
    }

    private func currentCacheKey() -> String? {
        guard let storageID else { return nil }
        return cacheKey(currentParentID, in: storageID)
    }

    /// Snapshot the current folder's listing into the cache before navigating away, so coming
    /// back shows it instantly — with whatever live updates it accumulated while it was shown.
    private func cacheCurrentListing() {
        guard let key = currentCacheKey() else { return }
        listingCache[key] = entries
    }

    private func cache(_ nodes: [FileNode], forParent parentID: String?, in storageID: String) {
        listingCache[cacheKey(parentID, in: storageID)] = nodes.sorted(by: Self.order)
    }

    private func showCachedListingOrLoading(forParent parentID: String?) {
        guard let storageID else { return }
        if let cached = listingCache[cacheKey(parentID, in: storageID)] {
            entries = cached
            isLoading = false
        } else {
            entries = []
            isLoading = true
        }
    }

    private func addToCachedListing(_ node: FileNode, removingExisting: Bool = false) {
        if removingExisting {
            removeFromCachedListings(id: node.id, clearingRecent: false)
        }
        let key = cacheKey(node.parentID, in: node.storageID)
        guard var cached = listingCache[key] else { return }
        if let index = cached.firstIndex(where: { $0.id == node.id }) {
            cached[index] = node
        } else {
            cached.append(node)
        }
        cache(cached, forParent: node.parentID, in: node.storageID)
    }

    private func upsertCurrentEntry(_ node: FileNode) {
        if let index = entries.firstIndex(where: { $0.id == node.id }) {
            entries[index] = node
        } else {
            entries.append(node)
        }
        entries.sort(by: Self.order)
    }

    private func removeFromCachedListings(id: String, clearingRecent: Bool = true) {
        for key in Array(listingCache.keys) {
            listingCache[key]?.removeAll { $0.id == id }
        }
        if let storageID {
            listingCache[cacheKey(id, in: storageID)] = nil
        }
        if clearingRecent {
            recentlyAddedIDs[id] = nil
            recentlyAddedNodes[id] = nil
        }
    }

    private func updateCachedListing(with node: FileNode) {
        for key in Array(listingCache.keys) {
            guard let index = listingCache[key]?.firstIndex(where: { $0.id == node.id }) else { continue }
            listingCache[key]?[index] = node
            listingCache[key]?.sort(by: Self.order)
        }
    }

    private func rememberRecentlyAdded(_ node: FileNode) {
        recentlyAddedIDs[node.id] = Date()
        recentlyAddedNodes[node.id] = node
    }

    private func pruneRecentlyAdded(now: Date = Date()) {
        recentlyAddedIDs = recentlyAddedIDs.filter { now.timeIntervalSince($0.value) < recentAddGrace }
        recentlyAddedNodes = recentlyAddedNodes.filter { recentlyAddedIDs[$0.key] != nil }
    }

    private func protectedNode(for node: FileNode) -> FileNode {
        pruneRecentlyAdded()
        return recentlyAddedNodes[node.id] ?? node
    }

    private func locatedNode(_ node: FileNode, parentID: String?, storageID: String) -> FileNode {
        FileNode(id: node.id,
                 storageID: storageID,
                 parentID: parentID,
                 name: node.name,
                 isDirectory: node.isDirectory,
                 size: node.size,
                 modifiedDate: node.modifiedDate,
                 fileExtension: node.fileExtension)
    }

    private func listingWithRecentlyAdded(_ listed: [FileNode], parentID: String?, storageID: String) -> [FileNode] {
        pruneRecentlyAdded()
        var merged = listed.map { recentlyAddedNodes[$0.id] ?? $0 }
        var seen = Set(merged.map(\.id))
        for node in recentlyAddedNodes.values where node.storageID == storageID && node.parentID == parentID {
            guard !seen.contains(node.id) else { continue }
            merged.append(node)
            seen.insert(node.id)
        }
        return merged.sorted(by: Self.order)
    }

    func recordCompletedUpload(_ node: FileNode) {
        guard node.storageID == storageID else { return }
        rememberRecentlyAdded(node)
        addToCachedListing(node, removingExisting: true)
        guard node.parentID == currentParentID else { return }
        upsertCurrentEntry(node)
        cacheCurrentListing()
    }

    func reload() async {
        guard let transport, let storageID else { return }
        let parent = currentParentID
        let key = cacheKey(parent, in: storageID)
        // Seen this folder already? Show it instantly and skip the spinner. When no transfer is
        // active we still re-fetch below (silently) to pick up any device-side changes.
        let hadCachedListing: Bool
        if let cached = listingCache[key] {
            entries = cached
            hadCachedListing = true
        } else {
            isLoading = true
            hadCachedListing = false
        }
        if hadCachedListing, isTransferActive() {
            isLoading = false
            errorMessage = nil
            return
        }
        isReloading = true
        errorMessage = nil
        do {
            // Off the main actor: the MTP listing does blocking USB I/O, which would otherwise
            // run on the main thread and freeze the UI for the whole device round-trip.
            let listed = try await Task.detached(priority: .userInitiated) {
                try await transport.listChildren(of: parent, in: storageID)
            }.value
            // The user may have navigated elsewhere while this was in flight.
            guard parent == currentParentID, storageID == self.storageID else {
                isLoading = false
                isReloading = false
                return
            }
            let sorted = listingWithRecentlyAdded(listed, parentID: parent, storageID: storageID)
            entries = sorted
            listingCache[key] = sorted
        } catch {
            errorMessage = error.friendlyMessage
            if error.isMTPConnectionLost, let onConnectionLost {
                alerts?.error(NSLocalizedString("The connection to the device was lost. Make sure File Transfer is on, then reconnect.", comment: ""),
                              actionTitle: NSLocalizedString("Reconnect", comment: "")) { onConnectionLost() }
            } else {
                alerts?.error(String(format: NSLocalizedString("Failed to read folder: %@", comment: ""), error.friendlyMessage))
            }
        }
        isLoading = false
        isReloading = false
    }

    // MARK: Operations (the live events reconcile the list afterwards)

    // These mutations are blocking USB round-trips, so they run off the main actor (under the
    // macOS 26 SDK a nonisolated async call otherwise executes on the caller's executor — here the
    // main thread — and freezes the UI for the device's full response, longer for large objects).
    // The list updates afterwards from the live change events / poll, so there's nothing to await.

    func delete(_ ids: Set<String>) {
        guard let transport else { return }
        Task {
            for id in ids {
                do { try await Task.detached(priority: .userInitiated) { try await transport.delete(id) }.value }
                catch { alerts?.error(String(format: NSLocalizedString("Delete failed: %@", comment: ""), error.friendlyMessage)) }
            }
        }
    }

    func createFolder(named name: String) {
        guard let transport, let storageID else { return }
        let parentID = currentParentID
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try await transport.createDirectory(named: name, inParent: parentID, in: storageID)
                }.value
            }
            catch { alerts?.error(String(format: NSLocalizedString("Failed to create folder: %@", comment: ""), error.friendlyMessage)) }
        }
    }

    func rename(_ id: String, to newName: String) {
        guard let transport else { return }
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) { try await transport.rename(id, to: newName) }.value
            }
            catch { alerts?.error(String(format: NSLocalizedString("Rename failed: %@", comment: ""), error.friendlyMessage)) }
        }
    }

    func node(_ id: String) -> FileNode? { entries.first { $0.id == id } }
    func selectedNodes() -> [FileNode] { entries.filter { selection.contains($0.id) } }

    // MARK: Live sync

    private func startObserving(_ transport: any DeviceTransport) {
        observeTask?.cancel()
        let stream = transport.changes
        observeTask = Task { [weak self] in
            for await change in stream {
                guard let self else { break }
                self.apply(change)
            }
        }
    }

    // MARK: Polling fallback
    //
    // Some Android devices don't reliably emit interrupt events, so we also reconcile the
    // current folder every few seconds. It's cheap (one GetObjectHandles) and only fetches
    // metadata for genuinely new items, guaranteeing device-side adds/removes show up live
    // even when events are missing.

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                // Re-read the user's auto-refresh settings every cycle so Settings changes apply
                // immediately — toggling pauses the reconcile, the interval drives the sleep.
                let defaults = UserDefaults.standard
                let enabled = (defaults.object(forKey: AppSettingsKey.autoRefreshEnabled) as? Bool)
                    ?? AppSettingsKey.defaultAutoRefreshEnabled
                let interval = (defaults.object(forKey: AppSettingsKey.autoRefreshInterval) as? Int)
                    ?? AppSettingsKey.defaultAutoRefreshInterval
                try? await Task.sleep(for: .seconds(max(1, min(60, interval))))
                guard let self, !Task.isCancelled else { break }
                if enabled { await self.silentReconcile() }
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func silentReconcile() async {
        guard let transport, let storageID, !isReloading, !isTransferActive(), isAppActive else { return }
        // Stay quiet during the post-transfer cooldown so we don't compete with the device while
        // it's finalizing a just-written file (or with the user's own next navigation).
        if let until = transferCooldownUntil, Date() < until { return }
        let parent = currentParentID
        guard let ids = try? await Task.detached(priority: .userInitiated, operation: {
            try await transport.childIDs(of: parent, in: storageID)
        }).value else { return }
        // Bail if the user navigated away during the await.
        guard parent == currentParentID, storageID == self.storageID else { return }

        // Don't remove files we added moments ago just because the device hasn't indexed them
        // into GetObjectHandles yet; keep them until the grace window lapses (then the device wins).
        pruneRecentlyAdded()
        let current = Set(entries.map(\.id))
        let removed = current.subtracting(ids).subtracting(recentlyAddedIDs.keys)
        let added = ids.subtracting(current)
        guard !removed.isEmpty || !added.isEmpty else { return }
        scheduleStorageRefresh()   // the folder changed → free space likely did too

        if !removed.isEmpty {
            entries.removeAll { removed.contains($0.id) }
            for id in removed {
                selection.remove(id)
                removeFromCachedListings(id: id)
            }
        }
        for id in added {
            guard parent == currentParentID else { return }
            if let rawNode = try? await Task.detached(priority: .userInitiated, operation: {
                   try await transport.metadata(for: id)
               }).value,
               !entries.contains(where: { $0.id == rawNode.id }) {
                let node = locatedNode(rawNode, parentID: parent, storageID: storageID)
                entries.append(node)
                addToCachedListing(node)
            }
        }
        entries.sort(by: Self.order)
        cacheCurrentListing()
    }

    private func apply(_ change: DeviceChange) {
        switch change {
        case .added(let rawNode):
            let node = protectedNode(for: rawNode)
            scheduleStorageRefresh()   // free space dropped
            if node.storageID == storageID {
                addToCachedListing(node, removingExisting: recentlyAddedNodes[node.id] != nil)
            }
            guard node.storageID == storageID, node.parentID == currentParentID else { return }
            rememberRecentlyAdded(node)   // shield from poll/reload removal during indexing lag
            upsertCurrentEntry(node)
            cacheCurrentListing()
        case .removed(let id):
            scheduleStorageRefresh()   // free space recovered
            let wasInCurrentListing = entries.contains { $0.id == id }
            removeFromCachedListings(id: id)
            entries.removeAll { $0.id == id }
            selection.remove(id)
            if wasInCurrentListing {
                cacheCurrentListing()
            }
            // If the current folder (or an ancestor) was deleted, pop above it.
            if let idx = pathStack.firstIndex(where: { $0.id == id }) {
                pathStack.removeLast(pathStack.count - idx)
                Task { await reload() }
            }
        case .changed(let node):
            if node.storageID == storageID {
                updateCachedListing(with: node)
            }
            guard node.storageID == storageID, node.parentID == currentParentID else { return }
            if let i = entries.firstIndex(where: { $0.id == node.id }) {
                entries[i] = node
                entries.sort(by: Self.order)
                cacheCurrentListing()
            }
        case .reloadNeeded(let parentID, let sid):
            if sid == storageID, parentID == currentParentID { Task { await reload() } }
        case .storagesChanged:
            scheduleStorageRefresh()
        }
    }

    static func order(_ a: FileNode, _ b: FileNode) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    // MARK: Demo helper (mock only) — stands in for "another app on the phone changed a file"

    func simulateDeviceSideChange() {
        guard let mock = transport as? MockTransport, let storageID else { return }
        let parent = currentParentID
        let removableFiles = entries.filter { !$0.isDirectory }
        Task {
            if let victim = removableFiles.randomElement(), Bool.random() {
                await mock.simulateExternalRemove(victim.id)
            } else {
                _ = await mock.simulateExternalAdd(named: "device_\(Int.random(in: 100...999)).bin",
                                                   inParent: parent, in: storageID)
            }
        }
    }
}

extension Error {
    /// True when an MTP error means the USB connection is gone or wedged — only a reset +
    /// re-discover (or re-enabling File Transfer on the phone) recovers it. Drives the
    /// "Reconnect" alert action.
    var isMTPConnectionLost: Bool {
        guard let mtp = self as? MTPError else { return false }
        switch mtp {
        case .deviceStalled, .usb, .noDevice: return true
        default: return false
        }
    }
}
