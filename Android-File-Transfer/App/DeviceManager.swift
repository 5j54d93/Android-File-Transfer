//
//  DeviceManager.swift
//  Android-File-Transfer
//
//  Created by Ricky on 2026/5/29.
//

import SwiftUI
import MTPKit

/// Sidebar selection can be a whole device (e.g. a connected-but-locked phone) or one
/// of its storages. A device-level selection lets us show a "turn on file transfer"
/// hint on the right while still showing the device in the list.
enum SidebarSelection: Hashable {
    case device(String)   // device id
    case storage(String)  // storage id
}

/// Owns connected devices and the sidebar selection. On launch (and on rescan) it
/// tries to open a real USB MTP device via the same `DeviceTransport` abstraction the
/// rest of the app uses.
@MainActor
@Observable
final class DeviceManager {
    struct Device: Identifiable {
        let transport: any DeviceTransport
        var storages: [StorageInfo]
        var id: String { transport.id }
        var name: String { transport.displayName }
        var kind: TransportKind { transport.kind }
    }

    private(set) var devices: [Device] = []
    private(set) var isScanning = false
    /// True once the first scan completes, so launch shows a "searching" state instead of
    /// prematurely flashing "no device connected" before we've actually looked.
    private(set) var hasFinishedFirstScan = false
    var selection: SidebarSelection?
    /// Set when a previously-connected device drops unexpectedly; ContentView surfaces it.
    private(set) var lastError: String?
    /// Toggled to present the wireless pairing sheet from menu/toolbar.
    var showPairingSheet = false
    /// Whether wireless is available at all (adb located/bundled).
    var wirelessAvailable: Bool { adbClient != nil }
    /// We're still looking and have nothing to show yet → the UI shows a "searching" state
    /// rather than the "no device connected" empty state.
    var isSearchingWithNoDevices: Bool { devices.isEmpty && (isScanning || !hasFinishedFirstScan) }

    private var realTransport: MTPTransport?
    private var watcher: USBWatcher?
    private var storagePollTask: Task<Void, Never>?

    // Wireless (ADB) state — see DeviceManager+Wireless.swift.
    let adbClient: ADBClient? = ADBClient()
    var adbDiscovery: ADBDiscovery?
    var wirelessTransports: [String: ADBTransport] = [:]   // keyed by adb serial (host:port)
    var discoveredServices: [ADBService] = []
    /// Active QR pairing session (payload shown to the user); nil when not pairing by QR.
    var qrSession: ADBQRPairing.Session?
    /// Drives QR pairing: polls mDNS, pairs, then connects. Cancelled when the sheet closes.
    var qrPollTask: Task<Void, Never>?
    /// Endpoints connected manually (direct IP:port). Protected from mDNS-driven removal,
    /// since some devices don't keep advertising _adb-tls-connect after connecting.
    var manualEndpoints: Set<String> = []
    /// Set after a successful pair when we couldn't auto-connect (device doesn't advertise
    /// _adb-tls-connect). Carries the paired host so the UI can prompt for the connect port.
    var pairedAwaitingConnect: String?

    // Serialize refreshes: concurrent runs corrupt each other (one discovers a transport
    // while another, seeing the seize-induced re-enumeration, closes it). `isRefreshing`
    // gates execution; `refreshPending` coalesces requests that arrive mid-refresh.
    private var isRefreshing = false
    private var refreshPending = false
    private var debounceTask: Task<Void, Never>?
    /// Consecutive failed re-discoveries while we believed a device was attached. Lets us
    /// tolerate the re-enumeration window but still clear truly-removed devices.
    private var missStreak = 0

    init() {
        // Auto re-scan when USB devices come and go. Seizing the device itself triggers a
        // brief re-enumeration, so debounce to collapse the resulting burst of events.
        watcher = USBWatcher {
            Task { @MainActor [weak self] in self?.scheduleRefresh() }
        }
        startWirelessDiscovery()
        Task { await refresh() }
    }

    /// Debounced trigger used by the hot-plug watcher.
    private func scheduleRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// Lightweight refresh of just the connected devices' storage figures (capacity/free),
    /// without re-running discovery. Lets the sidebar reflect free space changing after a
    /// transfer or delete.
    func refreshStorages() async {
        guard !isRefreshing, !devices.isEmpty else { return }
        var updated: [Device] = []
        for device in devices {
            let storages = (try? await device.transport.storages()) ?? device.storages
            updated.append(Device(transport: device.transport, storages: storages))
        }
        devices = updated
    }

    func refresh() async {
        // Reentrancy guard: if a refresh is in flight, mark that another is wanted and
        // return — the in-flight one will loop again when it finishes.
        if isRefreshing { refreshPending = true; return }
        isRefreshing = true
        isScanning = true
        defer {
            isRefreshing = false
            isScanning = false
            hasFinishedFirstScan = true
            if refreshPending {
                refreshPending = false
                Task { await refresh() }
            }
        }

        // Validate the existing transport; drop it if the device went away / re-enumerated.
        var realStorages: [StorageInfo]?
        let hadConnection = realTransport != nil
        if let real = realTransport {
            do {
                realStorages = try await real.storages()    // [] = locked (still connected)
            } catch MTPError.deviceStalled {
                // Connection wedged mid-use — reset the USB device and re-discover below.
                await real.close()
                realTransport = nil
                realStorages = nil
                MTPTransport.recoverByReset()
                try? await Task.sleep(for: .seconds(2))     // wait for re-enumeration
            } catch {
                await real.close()
                realTransport = nil
                realStorages = nil
            }
        }
        if realTransport == nil {
            realTransport = await MTPTransport.discover()
            if let real = realTransport {
                realStorages = (try? await real.storages()) ?? []
            }
        }

        // If we had a connection and discovery just failed, it's almost always the brief
        // re-enumeration window after a seize/reset, not a real unplug. Tolerate a few
        // such misses (keep the list on screen, retry shortly) before concluding the
        // device is really gone.
        if hadConnection && realTransport == nil {
            missStreak += 1
            if missStreak < 4 {
                scheduleRefresh()
                return
            }
            lastError = NSLocalizedString("Lost connection to the Android device", comment: "")
        }
        missStreak = 0

        var list: [Device] = []
        if let real = realTransport {
            list.append(Device(transport: real, storages: realStorages ?? []))
        }
        // Merge wireless (ADB) devices, de-duplicating against the USB device (USB wins).
        list.append(contentsOf: await wirelessDevices(excludingUSBModel: realTransport?.displayName))
        devices = list

        let storageIDs = list.flatMap { $0.storages.map(\.id) }
        if case .storage(let id) = selection, storageIDs.contains(id) {
            // keep a still-valid storage selection
        } else if let firstStorage = storageIDs.first {
            selection = .storage(firstStorage)
        } else if let firstDevice = list.first {
            selection = .device(firstDevice.id)   // connected but no storage yet → show hint
        } else {
            selection = nil
        }

        updateStoragePolling()
    }

    /// While a device is connected but exposes no storage (locked, or file transfer just
    /// toggled), poll briefly so the list fills in the instant the user unlocks — no
    /// manual rescan needed. Stops automatically once storage appears or the device leaves.
    private func updateStoragePolling() {
        let needsPoll = !devices.isEmpty && devices.allSatisfy { $0.storages.isEmpty }
        if needsPoll {
            if storagePollTask == nil {
                storagePollTask = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(2))
                        guard let self, !Task.isCancelled else { break }
                        await self.refresh()
                    }
                }
            }
        } else {
            storagePollTask?.cancel()
            storagePollTask = nil
        }
    }

    func clearError() { lastError = nil }

    /// Cleanly close the MTP session on quit so the device isn't left in a wedged state.
    /// Synchronous so it can run from applicationWillTerminate before the process exits.
    func shutdownSync() {
        storagePollTask?.cancel()
        adbDiscovery?.stop()
        let usb = realTransport
        let wireless = Array(wirelessTransports.values)
        let adb = adbClient
        realTransport = nil
        wirelessTransports = [:]
        guard usb != nil || !wireless.isEmpty else { return }
        let sema = DispatchSemaphore(value: 0)
        // Run closes at the SAME (high) QoS as this terminating thread to avoid a
        // priority-inversion warning from the Thread Performance Checker.
        Task.detached(priority: .userInitiated) {
            await usb?.close()
            for w in wireless { await w.close() }
            // Stop our isolated adb server so we don't leave a stray daemon.
            _ = try? await adb?.run(["kill-server"], timeout: 5)
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + 3)
    }

    func device(id: String) -> Device? {
        devices.first { $0.id == id }
    }

    func device(forStorage storageID: String) -> Device? {
        devices.first { device in device.storages.contains { $0.id == storageID } }
    }

    func storage(_ id: String) -> StorageInfo? {
        for device in devices {
            if let match = device.storages.first(where: { $0.id == id }) { return match }
        }
        return nil
    }
}
