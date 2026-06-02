//
//  DeviceManager+Wireless.swift
//  Android-File-Transfer
//
//  Wireless (ADB over Wi-Fi) discovery, connection, pairing, and de-duplication.
//

import SwiftUI
import MTPKit

extension DeviceManager {

    /// Start browsing the local network for paired wireless-debugging devices. Each time
    /// the set changes we auto-connect new ones and refresh the sidebar.
    func startWirelessDiscovery() {
        guard adbClient != nil else { return }   // no adb available → wireless disabled
        let discovery = ADBDiscovery { services in
            Task { @MainActor [weak self] in self?.handleDiscovered(services) }
        }
        adbDiscovery = discovery
        discovery.start()
    }

    private func handleDiscovered(_ services: [ADBService]) {
        discoveredServices = services
        Task { await connectNewServices(services) }
        // QR pairing is driven by its own poll loop (startQRPairing), which is more robust
        // than reacting to individual NWBrowser callbacks.
    }

    // MARK: QR pairing

    /// Begin a QR pairing session: returns the payload string to render as a QR code.
    /// The phone scans it, starts a pairing server we recognise, and discovery auto-pairs.
    /// A poll loop drives matching because mDNS callbacks can fire before the sheet opens,
    /// and because the connect advertisement after pairing is short-lived.
    func startQRPairing() -> String {
        let session = ADBQRPairing.makeSession()
        qrSession = session
        qrPollTask?.cancel()
        qrPollTask = Task { [weak self] in
            // Poll for up to ~90s: match our pairing service, pair, then connect.
            for _ in 0..<90 {
                if Task.isCancelled { return }
                guard let self else { return }
                let done = await self.qrPollTick()
                if done { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        return session.payload
    }

    /// Stop the active QR session (sheet closed).
    func cancelQRPairing() {
        qrSession = nil
        qrPollTask?.cancel()
        qrPollTask = nil
    }

    /// One tick of the QR poll loop. Returns true when pairing+connect fully succeeded.
    private func qrPollTick() async -> Bool {
        guard let session = qrSession, let client = adbClient else { return true }
        // 1) Force a fresh mDNS query through adb (NWBrowser can be stale/quiet).
        let services = await currentMDNSServices()
        // 2) If our pairing service is visible, pair against it.
        if let paired = await ADBQRPairing.tryPair(session: session, services: services, client: client) {
            qrSession = nil
            // 3) After QR pairing the device exposes a connect service. Resolve & connect:
            //    try the discovered connect endpoint(s); also try the paired host with the
            //    advertised connect port if we can find it.
            await connectAfterPairing(pairedPairingEndpoint: paired)
            await refresh()
            return true
        }
        return false
    }

    /// Query adb's own mDNS for current services (more reliable than waiting on NWBrowser).
    private func currentMDNSServices() async -> [ADBService] {
        guard let client = adbClient else { return discoveredServices }
        guard let out = try? await client.run(["mdns", "services"], timeout: 8), out.ok else {
            return discoveredServices
        }
        var result: [ADBService] = []
        for line in out.stdout.split(separator: "\n") {
            // Format: "<name>\t_adb-tls-(pairing|connect)._tcp\t<host>:<port>"
            let cols = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cols.count >= 3 else { continue }
            let name = cols[0]
            let type = cols[1]
            let hostPort = cols[2]
            guard let colon = hostPort.lastIndex(of: ":"),
                  let port = Int(hostPort[hostPort.index(after: colon)...]) else { continue }
            let host = String(hostPort[..<colon])
            let kind: ADBService.Kind = type.contains("pairing") ? .pairing : .connect
            result.append(ADBService(name: name, host: host, port: port, kind: kind))
        }
        // Merge with NWBrowser's view too.
        return result + discoveredServices
    }

    /// After a successful pair, try to connect. Many devices DON'T advertise
    /// `_adb-tls-connect` after pairing (their mDNS stays empty), so we only poll briefly;
    /// if no connect endpoint appears, we record the paired host and let the UI prompt the
    /// user for the connect IP:port shown on the phone's Wireless debugging screen.
    /// Returns true if we actually connected.
    @discardableResult
    private func connectAfterPairing(pairedPairingEndpoint: String) async -> Bool {
        guard let client = adbClient else { return false }
        let pairedHost = pairedPairingEndpoint.split(separator: ":").first.map(String.init)
        // Short window — the connect advertisement, if it ever comes, is quick.
        for _ in 0..<8 {
            let connects = await currentMDNSServices().filter { $0.kind == .connect }
            let candidate = connects.first { pairedHost == nil || $0.host == pairedHost } ?? connects.first
            if let candidate,
               (try? await ADBPairing.connect(client: client, hostPort: candidate.endpoint)) != nil,
               let transport = await ADBTransport.connect(client: client, serial: candidate.endpoint) {
                manualEndpoints.insert(candidate.endpoint)
                wirelessTransports[candidate.endpoint] = transport
                pairedAwaitingConnect = nil
                return true
            }
            try? await Task.sleep(for: .seconds(1))
        }
        // Couldn't auto-connect — hand off to the UI to ask for the connect port.
        pairedAwaitingConnect = pairedHost
        return false
    }

    /// The most-recent pairing endpoint seen on the network, so the pairing sheet can
    /// pre-fill it (the user then only needs to type the 6-digit code).
    var suggestedPairingEndpoint: String? {
        discoveredServices.first { $0.kind == .pairing }?.endpoint
    }

    /// True if we already have a working transport for this physical device (same
    /// ro.serialno). Prevents the same phone showing twice when reached via both an
    /// IP:port serial and an mDNS-name serial.
    private func alreadyConnected(hardwareSerial: String) -> Bool {
        wirelessTransports.values.contains { $0.hardwareSerial == hardwareSerial }
    }

    /// `adb connect` to any newly-seen *connect* endpoint and build an ADBTransport.
    /// Pairing endpoints are not auto-connected (they need a code) — they only feed the
    /// pairing sheet's suggestion.
    private func connectNewServices(_ services: [ADBService]) async {
        guard let client = adbClient else { return }
        let connectable = services.filter { $0.kind == .connect }
        var changed = false
        for svc in connectable where wirelessTransports[svc.endpoint] == nil {
            if (try? await ADBPairing.connect(client: client, hostPort: svc.endpoint)) != nil,
               let transport = await ADBTransport.connect(client: client, serial: svc.endpoint) {
                // De-dupe: same physical device already connected another way → drop this.
                if alreadyConnected(hardwareSerial: transport.hardwareSerial) {
                    await transport.close()
                } else {
                    wirelessTransports[svc.endpoint] = transport
                    changed = true
                }
            }
        }
        // Drop transports whose connect service disappeared — but never drop a manually
        // connected endpoint (many devices stop advertising _adb-tls-connect once paired,
        // yet the connection stays perfectly usable).
        let liveEndpoints = Set(connectable.map(\.endpoint))
        for (endpoint, transport) in wirelessTransports
            where !liveEndpoints.contains(endpoint) && !manualEndpoints.contains(endpoint) {
            await transport.close()
            wirelessTransports[endpoint] = nil
            changed = true
        }
        if changed { await refresh() }
    }

    /// Connect directly to a device by IP:port (the "IP address & port" shown on the
    /// phone's Wireless debugging main screen). Works for already-paired devices and
    /// doesn't depend on mDNS — the reliable path when a device doesn't keep advertising.
    @discardableResult
    func connectDirect(hostPort: String) async -> Bool {
        guard let client = adbClient else { return false }
        guard (try? await ADBPairing.connect(client: client, hostPort: hostPort)) != nil,
              let transport = await ADBTransport.connect(client: client, serial: hostPort) else {
            return false
        }
        // Replace any existing transport for the same physical device (e.g. a stale
        // connection on an old port that no longer works).
        for (endpoint, existing) in wirelessTransports
            where existing.hardwareSerial == transport.hardwareSerial {
            await existing.close()
            wirelessTransports[endpoint] = nil
            manualEndpoints.remove(endpoint)
        }
        manualEndpoints.insert(hostPort)
        wirelessTransports[hostPort] = transport
        pairedAwaitingConnect = nil
        await refresh()
        return true
    }

    /// Manually pair + connect a device by IP:port and pairing code (from the phone).
    /// `pairHostPort` is the pairing dialog's host:port; `connectHostPort` is optional and
    /// defaults to discovery/auto-connect afterwards.
    /// Result of a pairing attempt, so the UI can react precisely.
    enum PairOutcome: Equatable {
        case failed                 // wrong code / unreachable
        case connected              // paired AND connected — ready to browse
        case pairedNeedsConnect(host: String)  // paired, but must enter the connect port
    }

    /// Pair by IP:port + code, then try to connect. If the device doesn't advertise a
    /// connect endpoint (common), returns `.pairedNeedsConnect` so the UI can ask for the
    /// "IP address & Port" from the phone's Wireless debugging screen.
    func pairDevice(pairHostPort: String, code: String, connectHostPort: String?) async -> PairOutcome {
        guard let client = adbClient else { return .failed }
        do {
            let paired = try await ADBPairing.pair(client: client, hostPort: pairHostPort, code: code)
            guard paired else { return .failed }
            // If the caller already knows the connect port, use it directly.
            if let connect = connectHostPort, await connectDirect(hostPort: connect) {
                return .connected
            }
            // Otherwise try a brief mDNS-based auto-connect; fall back to asking the user.
            if await connectAfterPairing(pairedPairingEndpoint: pairHostPort) {
                return .connected
            }
            let host = pairHostPort.split(separator: ":").first.map(String.init) ?? pairHostPort
            return .pairedNeedsConnect(host: host)
        } catch {
            return .failed
        }
    }

    /// Build Device rows for wireless transports. Prunes dead/duplicate connections:
    ///  • a transport whose storage can't be read (stale port after re-enabling debugging)
    ///    is closed and dropped, and
    ///  • when two transports map to the same physical device (ro.serialno), only one is
    ///    shown. A USB device with the same model also hides its wireless twin (USB wins).
    func wirelessDevices(excludingUSBModel usbModel: String?) async -> [Device] {
        var rows: [Device] = []
        var seenHardware = Set<String>()
        for (endpoint, transport) in wirelessTransports {
            // Probe storages — this both fetches data and detects a dead connection.
            guard let storages = try? await transport.storages(), !storages.isEmpty else {
                // Dead/unreachable (e.g. port changed) → tear it down.
                await transport.close()
                wirelessTransports[endpoint] = nil
                manualEndpoints.remove(endpoint)
                continue
            }
            // De-dupe by physical device.
            if seenHardware.contains(transport.hardwareSerial) {
                await transport.close()
                wirelessTransports[endpoint] = nil
                continue
            }
            // Hide wireless twin of the connected USB device.
            if let usbModel, !usbModel.isEmpty,
               transport.displayName.caseInsensitiveCompare(usbModel) == .orderedSame {
                continue
            }
            seenHardware.insert(transport.hardwareSerial)
            rows.append(Device(transport: transport, storages: storages))
        }
        return rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
