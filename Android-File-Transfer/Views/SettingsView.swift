//
//  SettingsView.swift
//  Android-File-Transfer
//
//  The app's Settings window (⌘,). Controls the background auto-refresh of the file list.
//

import SwiftUI

/// UserDefaults keys shared between the Settings UI and `BrowserViewModel`'s poll loop.
enum AppSettingsKey {
    static let autoRefreshEnabled = "autoRefreshEnabled"
    static let autoRefreshInterval = "autoRefreshInterval"

    static let defaultAutoRefreshEnabled = true
    static let defaultAutoRefreshInterval = 3
}

struct SettingsView: View {
    @AppStorage(AppSettingsKey.autoRefreshEnabled)
    private var autoRefreshEnabled = AppSettingsKey.defaultAutoRefreshEnabled
    @AppStorage(AppSettingsKey.autoRefreshInterval)
    private var autoRefreshInterval = AppSettingsKey.defaultAutoRefreshInterval

    var body: some View {
        Form {
            Section {
                Toggle("Automatically refresh the file list", isOn: $autoRefreshEnabled)
                if autoRefreshEnabled {
                    Stepper(value: $autoRefreshInterval, in: 1...60) {
                        Text("Every \(autoRefreshInterval) seconds")
                    }
                }
            } footer: {
                // The whole poll-or-not tradeoff in user terms, so people can decide for
                // themselves whether to enable it and how often it should run.
                Text("When on, the current folder is checked every few seconds, so files added or removed on the phone show up automatically. A shorter interval keeps the list fresher, but the check shares the USB connection with file transfers and may occasionally delay the start of a transfer for a moment. When off, changes reported by the phone still appear, and you can always refresh manually from the toolbar.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Slide/fade the interval row in and out instead of popping when the toggle flips.
        .animation(.easeInOut(duration: 0.2), value: autoRefreshEnabled)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
