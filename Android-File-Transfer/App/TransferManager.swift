//
//  TransferManager.swift
//  Android-File-Transfer
//
//  Created by Ricky on 2026/5/29.
//

import SwiftUI
import MTPKit

/// Runs uploads/downloads through a single serial queue. MTP allows only one
/// transaction at a time, so transfers must not run concurrently — items wait their
/// turn and run one-by-one. Tracks live speed/ETA and supports retry of failed items.
@MainActor
@Observable
final class TransferManager {
    enum Direction { case upload, download }
    enum Status: Equatable { case waiting, running, completed, failed(String), cancelled }

    /// Everything needed to (re)start a transfer, so failed items can be retried.
    enum Job {
        case download(node: FileNode, folder: URL)
        case downloadToURL(node: FileNode, destination: URL)   // drag-out: exact target URL
        case upload(localURL: URL, parentID: String?, storageID: String)
    }

    @Observable
    final class Item: Identifiable {
        let id = UUID()
        let name: String
        let direction: Direction
        let destinationFolder: String?
        var completedBytes: Int64 = 0
        var totalBytes: Int64 = 0
        var status: Status = .waiting
        var bytesPerSecond: Double = 0
        @ObservationIgnored let job: Job
        @ObservationIgnored var task: Task<Void, Never>?
        @ObservationIgnored var startedAt: Date?
        @ObservationIgnored var lastSampleTime: Date?
        @ObservationIgnored var lastSampleBytes: Int64 = 0
        /// Called on completion (success → nil, failure → error). Used by drag-out file
        /// promises to signal Finder when the destination file is ready.
        @ObservationIgnored var completion: (@Sendable (Error?) -> Void)?

        init(name: String, direction: Direction, totalBytes: Int64, destinationFolder: String? = nil, job: Job) {
            self.name = name
            self.direction = direction
            self.destinationFolder = destinationFolder
            self.totalBytes = totalBytes
            self.job = job
        }

        var fraction: Double {
            totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0
        }

        /// Seconds remaining, or nil if not yet estimable.
        var etaSeconds: Double? {
            guard status == .running, bytesPerSecond > 1, totalBytes > completedBytes else { return nil }
            return Double(totalBytes - completedBytes) / bytesPerSecond
        }
    }

    private(set) var items: [Item] = []
    private(set) var transport: (any DeviceTransport)?
    @ObservationIgnored var alerts: AppAlerts?

    private var queue: [Item] = []
    private var isRunning = false

    var activeCount: Int { items.filter { $0.status == .running || $0.status == .waiting }.count }

    /// Whether the full-window transfer overlay should show: something is in flight, or a
    /// finished batch left failures the user still needs to act on.
    var isPresenting: Bool { activeCount > 0 || hasFailures }

    var failedItems: [Item] {
        items.filter { item in
            if case .failed = item.status { return true }
            return false
        }
    }
    var hasFailures: Bool { !failedItems.isEmpty }

    /// The item currently transferring. MTP is serial, so there's at most one.
    var currentItem: Item? { items.first { $0.status == .running } }

    /// The current batch is everything not cancelled; `enqueue` clears the previous batch
    /// when a new one starts, so these stay scoped to the in-flight group.
    private var batchItems: [Item] { items.filter { $0.status != .cancelled } }
    var batchTotal: Int { batchItems.count }
    var batchCompleted: Int { batchItems.filter { $0.status == .completed }.count }

    /// Byte-weighted progress (0–1) across the batch: completed items count as full, the
    /// rest by bytes transferred so far. Drives the overlay's aggregate progress bar.
    var batchProgress: Double {
        let batch = batchItems
        let total = batch.reduce(Int64(0)) { $0 + $1.totalBytes }
        guard total > 0 else { return 0 }
        let done = batch.reduce(Int64(0)) { acc, item in
            item.status == .completed ? acc + item.totalBytes : acc + item.completedBytes
        }
        return min(1, Double(done) / Double(total))
    }

    /// The transport is set by the browser whenever it opens a storage.
    func bind(_ transport: any DeviceTransport) { self.transport = transport }

    // MARK: Enqueue

    func download(_ node: FileNode, from transport: any DeviceTransport, to folder: URL) {
        self.transport = transport
        let item = Item(name: node.name, direction: .download, totalBytes: node.size,
                        destinationFolder: Self.displayName(forFolder: folder),
                        job: .download(node: node, folder: folder))
        enqueue(item)
    }

    /// Download a node to an exact destination URL, calling `completion` when done. Used by
    /// drag-out file promises (Finder hands us the destination; we fulfil it in background).
    func downloadToURL(_ node: FileNode, from transport: any DeviceTransport, to destination: URL,
                       completion: @escaping @Sendable (Error?) -> Void) {
        self.transport = transport
        let folder = destination.deletingLastPathComponent()
        let item = Item(name: node.name, direction: .download, totalBytes: node.size,
                        destinationFolder: Self.displayName(forFolder: folder),
                        job: .downloadToURL(node: node, destination: destination))
        item.completion = completion
        enqueue(item)
    }

    func upload(_ localURL: URL, toParent parentID: String?, storage storageID: String,
                destinationFolder: String?, via transport: any DeviceTransport) {
        self.transport = transport
        let item = Item(name: localURL.lastPathComponent, direction: .upload,
                        totalBytes: Format.fileSize(at: localURL),
                        destinationFolder: destinationFolder,
                        job: .upload(localURL: localURL, parentID: parentID, storageID: storageID))
        enqueue(item)
    }

    func retry(_ item: Item) {
        guard case .failed = item.status else { return }
        let fresh = Item(name: item.name, direction: item.direction, totalBytes: item.totalBytes,
                         destinationFolder: item.destinationFolder, job: item.job)
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx] = fresh
        } else {
            items.insert(fresh, at: 0)
        }
        queue.append(fresh)
        pump()
    }

    /// Retry every failed item at once (the overlay's "Retry All").
    func retryAll() {
        for item in failedItems { retry(item) }
    }

    private func enqueue(_ item: Item) {
        // A drop made while nothing is in flight begins a fresh batch — clear the previous
        // batch's finished/failed rows first so the count and overlay start clean.
        if activeCount == 0 { clearFinished() }
        items.insert(item, at: 0)
        queue.append(item)
        pump()
    }

    private static func displayName(forFolder folder: URL) -> String {
        let displayName = FileManager.default.displayName(atPath: folder.path(percentEncoded: false))
        return displayName.isEmpty ? folder.path(percentEncoded: false) : displayName
    }

    // MARK: Serial pump

    private func pump() {
        guard !isRunning, let transport else { return }
        guard let next = queue.first else { return }
        queue.removeFirst()
        isRunning = true
        next.status = .running
        next.startedAt = Date()
        next.lastSampleTime = Date()

        next.task = Task { [weak self] in
            await self?.run(next, on: transport)
            self?.isRunning = false
            self?.pump()
        }
    }

    /// Awaits a detached transport task while forwarding cancellation, so `cancel()` still aborts
    /// the transfer. Transfers run in a *detached* task because a transport's blocking USB I/O
    /// otherwise executes on the calling `@MainActor` thread (under the macOS 26 SDK, nonisolated
    /// `async` calls run on the caller's executor) and freezes the UI for the whole transfer — a
    /// 2.5s upload becomes a 2.5s frozen window.
    @discardableResult
    private func awaitForwardingCancellation<T: Sendable>(_ task: Task<T, Error>) async throws -> T {
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func run(_ item: Item, on transport: any DeviceTransport) async {
        let onProgress: ProgressHandler = { progress in
            Task { @MainActor [weak item] in
                guard let item else { return }
                item.completedBytes = progress.completedBytes
                item.totalBytes = progress.totalBytes
                self.sampleSpeed(item)
            }
        }
        do {
            switch item.job {
            case .download(let node, let folder):
                let destination = folder.appendingPathComponent(node.name)
                try await awaitForwardingCancellation(Task.detached(priority: .userInitiated) {
                    try await transport.download(node.id, to: destination, progress: onProgress)
                })
            case .downloadToURL(let node, let destination):
                try await awaitForwardingCancellation(Task.detached(priority: .userInitiated) {
                    try await transport.download(node.id, to: destination, progress: onProgress)
                })
            case .upload(let localURL, let parentID, let storageID):
                try await awaitForwardingCancellation(Task.detached(priority: .userInitiated) {
                    try await transport.upload(localURL: localURL, as: localURL.lastPathComponent,
                                               toParent: parentID, in: storageID, progress: onProgress)
                })
            }
            item.status = .completed
            item.bytesPerSecond = 0
            item.completion?(nil)
        } catch is CancellationError {
            item.status = .cancelled
            item.completion?(CancellationError())
        } catch {
            // The failure (with its message) is surfaced in the transfer overlay's failure card,
            // so we deliberately don't also raise the top alert banner — that was redundant.
            item.status = .failed(error.friendlyMessage)
            item.completion?(error)
        }
    }

    /// Exponentially-smoothed throughput so the number doesn't jitter every chunk.
    private func sampleSpeed(_ item: Item) {
        let now = Date()
        guard let last = item.lastSampleTime else { item.lastSampleTime = now; return }
        let dt = now.timeIntervalSince(last)
        guard dt >= 0.25 else { return }
        let delta = Double(item.completedBytes - item.lastSampleBytes)
        let instant = delta / dt
        item.bytesPerSecond = item.bytesPerSecond == 0 ? instant : item.bytesPerSecond * 0.6 + instant * 0.4
        item.lastSampleTime = now
        item.lastSampleBytes = item.completedBytes
    }

    // MARK: Controls

    func cancel(_ item: Item) {
        item.task?.cancel()
        queue.removeAll { $0.id == item.id }
        if item.status == .waiting { item.status = .cancelled }
    }

    /// Cancel everything in flight at once (the overlay's "Cancel").
    func cancelAll() {
        for item in items where item.status == .running || item.status == .waiting {
            cancel(item)
        }
    }

    func clearFinished() {
        items.removeAll { item in
            switch item.status {
            case .completed, .cancelled, .failed: return true
            case .running, .waiting: return false
            }
        }
    }

}
