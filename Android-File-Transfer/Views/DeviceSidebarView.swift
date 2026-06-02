//
//  DeviceSidebarView.swift
//  Android-File-Transfer
//
//  Created by Ricky on 2026/5/29.
//

import SwiftUI
import MTPKit

/// Finder-style source list. Each device is a small section header; its storages are the
/// selectable items underneath. A locked device shows a selectable "file transfer off"
/// row so the detail pane can explain how to enable it.
struct DeviceSidebarView: View {
    @Bindable var deviceManager: DeviceManager

    var body: some View {
        List(selection: $deviceManager.selection) {
            ForEach(deviceManager.devices) { device in
                Section {
                    if device.storages.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.fill")
                            Text("File transfer is off")
                        }
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                        .tag(SidebarSelection.device(device.id))
                    } else {
                        ForEach(device.storages) { storage in
                            StorageRow(storage: storage)
                                .tag(SidebarSelection.storage(storage.id))
                        }
                    }
                } header: {
                    HStack(spacing: 5) {
                        Image(systemName: "iphone.gen3")
                        Text(device.name)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Devices")
        .overlay {
            if deviceManager.isSearchingWithNoDevices {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Searching…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if deviceManager.devices.isEmpty {
                ContentUnavailableView("No devices connected", systemImage: "iphone.slash",
                                       description: Text("Connect an Android device via USB and choose \"File Transfer\" mode."))
            }
        }
        .safeAreaInset(edge: .bottom) {
            SidebarFooter()
        }
    }
}

private struct StorageRow: View {
    let storage: StorageInfo

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(storage.name)
                Text(String(format: NSLocalizedString("%@ free of %@", comment: ""),
                            Format.size(storage.freeBytes), Format.size(storage.capacityBytes)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 12)
    }
}

/// Pinned bottom strip of the sidebar: the app version.
private struct SidebarFooter: View {
    private var versionText: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        HStack {
            Text(versionText)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }
}
