//
//  AboutView.swift
//  Android-File-Transfer
//
//  Created by Ricky on 2026/5/29.
//

import SwiftUI
import AppKit

/// Custom About panel. Replaces the system "About" window so we control the exact text:
/// app name, "<short> (<build>)" with no "Version" prefix, and the author credit.
struct AboutView: View {
    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Android File Transfer"
    }
    private var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }
    private var appIcon: NSImage {
        NSApp.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 96, height: 96)

            Text(appName)
                .font(.system(size: 18, weight: .semibold))

            Text(build.isEmpty ? shortVersion : "\(shortVersion)（\(build)）")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("Develop & Design by Ricky.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 28)
        .frame(minWidth: 320)
    }
}
