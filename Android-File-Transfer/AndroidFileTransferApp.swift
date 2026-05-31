//
//  AndroidFileTransferApp.swift
//  Android-File-Transfer
//
//  Created by Ricky on 2026/5/29.
//

import AppKit
import SwiftUI

@main
struct AndroidFileTransferApp: App {
    static let diagnosticsWindowID = "usb-diagnostics"
    static let aboutWindowID = "about"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(deviceManager: appDelegate.deviceManager)
        }
        .commands {
            // Replace the default "About <app>" item with our custom panel.
            CommandGroup(replacing: .appInfo) {
                AboutMenuButton()
            }
            CommandMenu("Tools") {
                DiagnosticsMenuButton()
            }
        }

        Window("USB Diagnostics", id: Self.diagnosticsWindowID) {
            USBDiagnosticsView()
        }
        .defaultSize(width: 640, height: 480)

        Window("About Android File Transfer", id: Self.aboutWindowID) {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// Owns the app-wide DeviceManager so we can close the MTP session cleanly on quit —
/// otherwise the device can be left in a wedged state needing a reset.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let deviceManager = DeviceManager()

    func applicationWillTerminate(_ notification: Notification) {
        deviceManager.shutdownSync()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// Lives in a command menu so it can reach `openWindow` from the menu bar.
private struct DiagnosticsMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("USB Diagnostics…") {
            openWindow(id: AndroidFileTransferApp.diagnosticsWindowID)
        }
        .keyboardShortcut("d", modifiers: [.command, .shift])
    }
}

/// Opens our custom About window in place of the system panel.
private struct AboutMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("About Android File Transfer") {
            openWindow(id: AndroidFileTransferApp.aboutWindowID)
        }
    }
}
