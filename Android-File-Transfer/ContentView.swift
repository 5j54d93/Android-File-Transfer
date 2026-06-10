//
//  ContentView.swift
//  Android-File-Transfer
//
//  Created by Ricky on 2026/5/29.
//

import AppKit
import SwiftUI
import MTPKit

struct ContentView: View {
    @Bindable var deviceManager: DeviceManager
    @State private var transfers = TransferManager()
    @State private var browser = BrowserViewModel()
    @State private var alerts = AppAlerts()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppSettingsKey.autoRefreshEnabled)
    private var autoRefreshEnabled = AppSettingsKey.defaultAutoRefreshEnabled

    // The status line under the title is system-rendered text (`navigationSubtitle`), out of
    // reach of SwiftUI's animation system — so its toggle transition is interpolated by hand:
    // the value is stepped over time and the subtitle re-renders each step, reading as a fade.
    /// Whole-line opacity multiplier, dipped and restored when auto-refresh is toggled.
    @State private var modeFade: Double = 1
    @State private var modeTask: Task<Void, Never>?

    var body: some View {
        NavigationSplitView {
            DeviceSidebarView(deviceManager: deviceManager)
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 320)
        } detail: {
            detailPane
        }
        .onChange(of: deviceManager.selection, initial: true) { _, selection in
            applySelection(selection)
        }
        .onChange(of: deviceManager.lastError) { _, message in
            if let message {
                alerts.error(message)
                deviceManager.clearError()
            }
        }
        .onChange(of: transfers.activeCount) { oldValue, newValue in
            if newValue > 0 {
                browser.cancelPendingStorageRefresh()
            } else if oldValue > 0 {
                browser.refreshStorageAfterTransferBatch()
            }
        }
        // Only run the background poll while the app is frontmost — no point syncing a window
        // the user can't see, and it keeps the serial MTP channel clear for whatever they do next.
        .onChange(of: scenePhase, initial: true) { _, phase in
            browser.setAppActive(phase == .active)
        }
        .onChange(of: autoRefreshEnabled) { _, _ in
            animateModeSwap()
        }
        .task { bindModels() }
        .sheet(isPresented: $deviceManager.showPairingSheet) {
            PairDeviceView(deviceManager: deviceManager)
        }
        // Transfer overlay and centred alerts are hosted on the window's frame view (above the
        // titlebar/toolbar), so their scrim dims the ENTIRE window — an in-content `.overlay`
        // can never cover the toolbar, which AppKit draws on top of the content view. The fade
        // in/out and the "stop swallowing clicks the moment dismissal starts" behaviour both
        // live in FullWindowOverlayHost. Deliberately not animated via SwiftUI `.animation` on
        // the split view: that once turned post-transfer list re-renders into multi-second
        // animated relayouts (the "freezes on Back right after an upload" hang).
        .background(FullWindowOverlayHost(isPresented: transfers.isPresenting) {
            TransferOverlayView(transfers: transfers)
        })
        .background(FullWindowOverlayHost(isPresented: alerts.current != nil) {
            alertOverlayContent
        })
    }

    /// Centred modal alert content (errors / connection-lost).
    @ViewBuilder
    private var alertOverlayContent: some View {
        if let notice = alerts.current {
            AlertOverlay(notice: notice) { alerts.dismiss() }
        }
    }

    /// The detail column: file browser (or empty state) plus title, status subtitle and toolbar.
    /// Split out of `body` to keep the type-checker fast.
    private var detailPane: some View {
        Group {
            if browser.storage != nil {
                FileBrowserView(browser: browser, transfers: transfers)
            } else {
                emptyState
            }
        }
        .navigationTitle("Android File Transfer")
        // Auto-refresh status lives under the title: a dot + label that brightens only while
        // a background pass is actually running. The refresh button stays a plain button —
        // it used to swap to a spinner on every (fast) background pass and flickered.
        .navigationSubtitle(refreshStatusSubtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if deviceManager.wirelessAvailable {
                    Button {
                        deviceManager.showPairingSheet = true
                    } label: {
                        Image(systemName: "wifi")
                    }
                    .help("Pair Wireless Device…")
                    .disabled(transfers.isPresenting)
                }
                Button {
                    Task { await deviceManager.refresh(); await browser.reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
                .disabled(transfers.isPresenting)
            }
        }
    }

    /// Wire the view models together (kept out of `body` to spare the type-checker).
    private func bindModels() {
        browser.alerts = alerts
        browser.isTransferActive = { transfers.activeCount > 0 }
        transfers.alerts = alerts
        // When the browser detects free space changed, refresh the sidebar's figures too.
        browser.onStorageShouldRefresh = { Task { await deviceManager.refreshStorages() } }
        // A lost USB connection offers a "Reconnect" action: reset + re-discover the device,
        // then reload. If it can't recover, the device drops and the empty state guides the
        // user to re-enable File Transfer on the phone.
        browser.onConnectionLost = { Task { await deviceManager.refresh(); await browser.reload() } }
    }

    /// Status line under the window title: a steadily-lit green dot + "Auto Refresh" when the
    /// poll is enabled, a steadily-lit red dot + "Auto Refresh Off" when disabled. (Refresh
    /// passes are far too quick to indicate live, so the dot doesn't try.) `modeFade` dips the
    /// whole line and fades it back in when the setting is toggled.
    private var refreshStatusSubtitle: Text {
        // circlebadge.fill is SF's inline status dot: small within the glyph box and vertically
        // centred against text — unlike shrinking circle.fill, which sits low on the baseline.
        let dot = Text("\(Image(systemName: "circlebadge.fill")) ")
        let coloredDot: Text = dot.foregroundColor((autoRefreshEnabled ? Color.green : Color.red).opacity(modeFade))
        let labelKey: LocalizedStringKey = autoRefreshEnabled ? "Auto Refresh" : "Auto Refresh Off"
        let label: Text = Text(labelKey).foregroundColor(Color.primary.opacity(0.55 * modeFade))
        return Text("\(coloredDot)\(label)")
    }

    /// Toggling auto-refresh in Settings: the new colour/label fades in instead of snapping.
    private func animateModeSwap() {
        modeTask?.cancel()
        modeFade = 0.15
        modeTask = stepFade(from: modeFade, to: 1, duration: 0.35) { modeFade = $0 }
    }

    /// Manually steps a value toward `target` with ease-in-out over `duration`, ~60 fps. Needed
    /// because the navigation subtitle is rendered by the system: SwiftUI can't animate it, but
    /// re-rendering it with interpolated values each step reads as a smooth fade.
    private func stepFade(from start: Double, to target: Double, duration: Double,
                          apply: @escaping @MainActor (Double) -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            let steps = max(2, Int(duration * 60))
            for i in 1...steps {
                try? await Task.sleep(for: .milliseconds(Int(duration * 1000) / steps))
                guard !Task.isCancelled else { return }
                let t = Double(i) / Double(steps)
                let eased = t * t * (3 - 2 * t)
                apply(start + (target - start) * eased)
            }
        }
    }

    /// The imaging app (Photos / Image Capture) currently running, if any. While one is open,
    /// macOS's imaging service keeps re-claiming the PTP/MTP device on its behalf, so our seize
    /// is undone moments later — the only reliable fix is quitting that app.
    private var ptpClaimant: NSRunningApplication? {
        let ids = ["com.apple.Photos", "com.apple.Image_Capture"]
        return NSWorkspace.shared.runningApplications.first { ids.contains($0.bundleIdentifier ?? "") }
    }

    private var wifiPairingButton: some View {
        Button {
            deviceManager.showPairingSheet = true
        } label: {
            Label("No cable? Connect over Wi-Fi", systemImage: "wifi")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if deviceManager.isSearchingWithNoDevices {
            searchingState
        } else if deviceManager.devices.isEmpty {
            ContentUnavailableView {
                Label("No Android Device Connected", systemImage: "iphone.slash")
            } description: {
                if let claimant = ptpClaimant {
                    // While Photos / Image Capture is open, macOS's imaging service keeps
                    // re-claiming the PTP/MTP device, so we lose the tug of war every time.
                    Text(String(format: NSLocalizedString("\"%@\" is using the USB connection to the device, so the phone can't be reached. Quit it, then rescan.", comment: ""),
                                claimant.localizedName ?? "Photos"))
                } else {
                    Text("Connect an Android device via USB and choose \"File Transfer\" mode on the phone.")
                }
            } actions: {
                if let claimant = ptpClaimant {
                    Button {
                        claimant.terminate()
                        Task {
                            try? await Task.sleep(for: .seconds(1.2))   // let it release the device
                            await deviceManager.refresh()
                        }
                    } label: {
                        Label(String(format: NSLocalizedString("Quit \"%@\" and Rescan", comment: ""),
                                     claimant.localizedName ?? "Photos"),
                              systemImage: "xmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                }
                if deviceManager.wirelessAvailable {
                    // Only one primary action at a time: Wi-Fi steps down when the quit-app
                    // button is showing.
                    if ptpClaimant == nil {
                        wifiPairingButton.buttonStyle(.borderedProminent)
                    } else {
                        wifiPairingButton.buttonStyle(.bordered)
                    }
                }
            }
        } else if case .device(let id) = deviceManager.selection,
                  let device = deviceManager.device(id: id), device.storages.isEmpty {
            ContentUnavailableView(
                "Turn On File Transfer on Your Phone",
                systemImage: "lock.open",
                description: Text(String(format: NSLocalizedString("Unlock \"%@\", then set the USB option to \"File Transfer\" in the notification shade.", comment: ""), device.name))
            )
        } else {
            ContentUnavailableView(
                "Select a Storage",
                systemImage: "externaldrive",
                description: Text("Select a storage from the sidebar to browse files.")
            )
        }
    }

    /// Shown on launch / while scanning with nothing found yet, so the user isn't told
    /// "no device" before we've actually finished looking.
    private var searchingState: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Searching for Devices…")
                .font(.title2.weight(.semibold))
            Text("Make sure your Android device is connected via USB and unlocked.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func applySelection(_ selection: SidebarSelection?) {
        if case .storage(let id) = selection,
           let device = deviceManager.device(forStorage: id),
           let storage = deviceManager.storage(id) {
            browser.open(device.transport, storage: storage)
        } else {
            browser.reset()
        }
    }
}
