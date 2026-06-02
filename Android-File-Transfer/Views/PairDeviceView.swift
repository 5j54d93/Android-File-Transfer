//
//  PairDeviceView.swift
//  Android-File-Transfer
//
//  Wireless pairing UI with two methods: scan a QR code, or type a pairing code.
//

import SwiftUI
import CoreImage.CIFilterBuiltins
import MTPKit

struct PairDeviceView: View {
    @Bindable var deviceManager: DeviceManager
    @Environment(\.dismiss) private var dismiss

    enum Method: Hashable { case qr, code, direct }
    @State private var method: Method = .qr
    @State private var wirelessCountAtOpen = 0
    /// When pairing succeeds but needs a manual connect, we switch to the Connect tab and
    /// prefill this host.
    @State private var prefillConnectHost: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair a Wireless Device").font(.title3).bold()

            Picker("", selection: $method) {
                Text("Scan QR Code").tag(Method.qr)
                Text("Pairing Code").tag(Method.code)
                Text("Connect").tag(Method.direct)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 420)

            Group {
                switch method {
                case .qr:
                    QRPairPane(deviceManager: deviceManager)
                case .code:
                    CodePairPane(deviceManager: deviceManager, onNeedsConnect: { host in
                        prefillConnectHost = host
                        method = .direct
                    })
                case .direct:
                    DirectConnectPane(deviceManager: deviceManager,
                                      prefillHost: prefillConnectHost,
                                      onConnected: { dismiss() })
                }
            }
            // A fresh identity per method makes switching a replace (old out, new in), so the
            // transition can cross-fade the panes; animate it whenever `method` changes.
            .id(method)
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
            .animation(.easeInOut(duration: 0.22), value: method)

            Divider()
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 440)
        .onAppear {
            wirelessCountAtOpen = deviceManager.wirelessTransports.count
            if method == .qr { _ = deviceManager.startQRPairing() }
        }
        .onChange(of: method) { _, newValue in
            if newValue == .qr { _ = deviceManager.startQRPairing() }
            else { deviceManager.cancelQRPairing() }
        }
        .onDisappear { deviceManager.cancelQRPairing() }
        // Auto-close once a new wireless device actually connects (pairing succeeded).
        .onChange(of: deviceManager.wirelessTransports.count) { _, count in
            if count > wirelessCountAtOpen { dismiss() }
        }
        // QR/code pairing succeeded but the device needs a manual connect port → guide the
        // user to the Connect tab, prefilled with the paired host.
        .onChange(of: deviceManager.pairedAwaitingConnect) { _, host in
            if let host {
                prefillConnectHost = host
                method = .direct
                deviceManager.pairedAwaitingConnect = nil
            }
        }
    }
}

/// A vertical list of numbered instruction steps (1, 2, 3 …) with circle-number icons. Keeps
/// numbering automatic so steps can be added or removed without renumbering by hand.
private struct NumberedSteps: View {
    let steps: [LocalizedStringKey]

    /// Setup steps shared by every wireless method: first enable Developer options (which is
    /// hidden until you tap Build number 7×), then open Wireless debugging.
    static let wirelessSetup: [LocalizedStringKey] = [
        "On the phone, open Settings ▸ About phone and tap \"Build number\" 7 times to enable Developer options.",
        "On the phone: Settings ▸ System ▸ Developer options ▸ Wireless debugging.",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                Label(step, systemImage: "\(index + 1).circle.fill")
            }
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - QR pane

private struct QRPairPane: View {
    @Bindable var deviceManager: DeviceManager

    var body: some View {
        VStack(spacing: 12) {
            if let payload = deviceManager.qrSession?.payload {
                QRCodeImage(string: payload)
                    .frame(width: 200, height: 200)
                    .padding(8)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
            } else {
                ProgressView().frame(width: 200, height: 200)
            }

            NumberedSteps(steps: NumberedSteps.wirelessSetup + [
                "Tap \"Pair device with QR code\", then scan this code.",
                "Keep the phone on the same Wi-Fi network as this Mac.",
            ])
        }
    }
}

/// Renders a QR code from a string using Core Image (no dependencies).
private struct QRCodeImage: View {
    let string: String
    var body: some View {
        if let cg = Self.generate(string) {
            Image(decorative: cg, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "qrcode").resizable().scaledToFit().foregroundStyle(.secondary)
        }
    }

    private static func generate(_ string: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}

// MARK: - Pairing-code pane

private struct CodePairPane: View {
    @Bindable var deviceManager: DeviceManager
    let onNeedsConnect: (String) -> Void

    @State private var pairHost = ""
    @State private var pairPort = ""
    @State private var code = ""
    @State private var isPairing = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 12) {
            NumberedSteps(steps: NumberedSteps.wirelessSetup + [
                "Tap \"Pair device with pairing code\".",
                "Enter the IP address & port and the 6-digit code shown on the phone.",
            ])

            if deviceManager.suggestedPairingEndpoint != nil {
                Label("Detected a device ready to pair — the address is filled in below.",
                      systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }

            Form {
                LabeledContent("IP address & port") {
                    HostPortField(host: $pairHost, port: $pairPort,
                                  hostPrompt: "192.168.1.23", portPrompt: "37000")
                }
                TextField("Pairing code", text: $code, prompt: Text(verbatim: "123456"))
                    .font(.system(.body, design: .monospaced))
            }
            .frame(width: 360)

            if let errorText {
                Text(errorText).font(.callout).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(isPairing ? LocalizedStringKey("Pairing…") : LocalizedStringKey("Pair")) { pair() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isPairing || pairHost.isEmpty || pairPort.isEmpty || code.isEmpty)
            }
        }
        .onAppear { prefill() }
        .onChange(of: deviceManager.suggestedPairingEndpoint) { _, _ in prefill() }
    }

    private func prefill() {
        guard pairHost.isEmpty, pairPort.isEmpty,
              let endpoint = deviceManager.suggestedPairingEndpoint else { return }
        (pairHost, pairPort) = HostPort.split(endpoint)
    }

    private func pair() {
        isPairing = true
        errorText = nil
        Task {
            let outcome = await deviceManager.pairDevice(pairHostPort: "\(pairHost):\(pairPort)", code: code, connectHostPort: nil)
            isPairing = false
            switch outcome {
            case .connected:
                break   // sheet auto-closes via wirelessTransports count change
            case .pairedNeedsConnect(let host):
                onNeedsConnect(host)   // switch to Connect tab, prefilled
            case .failed:
                errorText = String(localized: "Pairing failed. Check the address and code, then try again.")
            }
        }
    }
}

// MARK: - Direct connect pane (already-paired device)

private struct DirectConnectPane: View {
    @Bindable var deviceManager: DeviceManager
    var prefillHost: String?
    let onConnected: () -> Void

    @State private var host = ""
    @State private var port = ""
    @State private var isConnecting = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                if prefillHost != nil {
                    Label("Paired! Now enter the \"IP address & Port\" from the phone's Wireless debugging screen to connect.",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Label("Already paired this device once? Just connect — no code needed.",
                      systemImage: "checkmark.seal.fill")
                NumberedSteps(steps: NumberedSteps.wirelessSetup + [
                    "Enter the \"IP address & Port\" shown on that screen (not the pairing dialog).",
                ])
            }
            .foregroundStyle(.secondary)

            Form {
                LabeledContent("IP address & port") {
                    HostPortField(host: $host, port: $port,
                                  hostPrompt: "192.168.1.23", portPrompt: "41899")
                }
            }
            .frame(width: 360)

            if let errorText {
                Text(errorText).font(.callout).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(isConnecting ? LocalizedStringKey("Connecting…") : LocalizedStringKey("Connect")) { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isConnecting || host.isEmpty || port.isEmpty)
            }
        }
        .onAppear {
            // Prefill the host (the IP we just paired with); the user adds the port shown
            // on the phone's Wireless debugging screen.
            if host.isEmpty, let prefill = prefillHost { host = prefill }
        }
    }

    private func connect() {
        isConnecting = true
        errorText = nil
        Task {
            let ok = await deviceManager.connectDirect(hostPort: "\(host):\(port)")
            isConnecting = false
            if ok { onConnected() }
            else { errorText = String(localized: "Couldn't connect. Make sure Wireless debugging is on and the address is correct.") }
        }
    }
}

// MARK: - Host : Port field

/// Two-box `host : port` entry with the colon already drawn between the fields, so people
/// can't accidentally type a period instead of a colon. Typing or pasting a colon in the host
/// box pushes the remainder into the port box (and jumps focus there); the port box keeps
/// digits only.
private struct HostPortField: View {
    @Binding var host: String
    @Binding var port: String
    let hostPrompt: String
    let portPrompt: String

    private enum Field { case host, port }
    @FocusState private var focus: Field?

    var body: some View {
        HStack(spacing: 6) {
            TextField("IP address", text: $host, prompt: Text(verbatim: hostPrompt))
                .focused($focus, equals: .host)
                .onChange(of: host) { _, value in
                    // Tolerate a pasted/typed "host:port": keep the host, move the rest to port.
                    guard let i = value.firstIndex(of: ":") else { return }
                    let rest = String(value[value.index(after: i)...]).filter(\.isNumber)
                    host = String(value[..<i])
                    if !rest.isEmpty { port = rest }
                    focus = .port
                }
            Text(verbatim: ":").bold().foregroundStyle(.secondary)
            TextField("Port", text: $port, prompt: Text(verbatim: portPrompt))
                .focused($focus, equals: .port)
                .frame(width: 72)
                .onChange(of: port) { _, value in
                    let digits = value.filter(\.isNumber)
                    if digits != value { port = digits }
                }
        }
        .font(.system(.body, design: .monospaced))
        .labelsHidden()
    }
}

private enum HostPort {
    /// Split "host:port" on the last colon; with no colon it's all host.
    static func split(_ s: String) -> (host: String, port: String) {
        guard let i = s.lastIndex(of: ":") else { return (s, "") }
        return (String(s[..<i]), String(s[s.index(after: i)...]))
    }
}
