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
                ToolbarItem(placement: .primaryAction) {
                    if deviceManager.isScanning {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .help("Scanning…")
                    } else {
                        Button {
                            Task { await deviceManager.refresh(); await browser.reload() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Refresh")
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
        .task {
            browser.alerts = alerts
            transfers.alerts = alerts
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if deviceManager.devices.isEmpty {
            ContentUnavailableView(
                "No Android Device Connected",
                systemImage: "iphone.slash",
                description: Text("Connect an Android device via USB and choose \"File Transfer\" mode on the phone.")
            )
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
