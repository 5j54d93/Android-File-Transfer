//
//  ContentView.swift
//  Android-File-Transfer
//
//  Created by Ricky on 2026/5/29.
//

import SwiftUI
import MTPKit

struct ContentView: View {
    @Bindable var deviceManager: DeviceManager
    @State private var transfers = TransferManager()
    @State private var browser = BrowserViewModel()
    @State private var alerts = AppAlerts()

    var body: some View {
        NavigationSplitView {
            DeviceSidebarView(deviceManager: deviceManager)
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 320)
        } detail: {
            Group {
                if browser.storage != nil {
                    FileBrowserView(browser: browser, transfers: transfers)
                } else {
                    emptyState
                }
            }
            .navigationTitle("Android File Transfer")
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
                    if deviceManager.isScanning {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .frame(width: 28, height: 22)
                            .help("Scanning…")
                    } else {
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
            .overlay(alignment: .top) {
                if let notice = alerts.current {
                    AlertBanner(notice: notice) { alerts.dismiss() }
                        .animation(.spring(duration: 0.3), value: notice)
                }
            }
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
        .task {
            browser.alerts = alerts
            browser.isTransferActive = { transfers.activeCount > 0 }
            transfers.alerts = alerts
            // When the browser detects free space changed, refresh the sidebar's figures too.
            browser.onStorageShouldRefresh = { Task { await deviceManager.refreshStorages() } }
        }
        .sheet(isPresented: $deviceManager.showPairingSheet) {
            PairDeviceView(deviceManager: deviceManager)
        }
        // Frosted-glass transfer overlay over the whole window; fades out the instant the
        // batch finishes (or stays to show failures).
        .overlay {
            if transfers.isPresenting {
                TransferOverlayView(transfers: transfers)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: transfers.isPresenting)
    }

    @ViewBuilder
    private var emptyState: some View {
        if deviceManager.isSearchingWithNoDevices {
            searchingState
        } else if deviceManager.devices.isEmpty {
            ContentUnavailableView {
                Label("No Android Device Connected", systemImage: "iphone.slash")
            } description: {
                Text("Connect an Android device via USB and choose \"File Transfer\" mode on the phone.")
            } actions: {
                if deviceManager.wirelessAvailable {
                    Button {
                        deviceManager.showPairingSheet = true
                    } label: {
                        Label("No cable? Connect over Wi-Fi", systemImage: "wifi")
                    }
                    .buttonStyle(.borderedProminent)
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
