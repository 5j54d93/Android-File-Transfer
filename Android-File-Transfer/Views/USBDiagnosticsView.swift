//
//  USBDiagnosticsView.swift
//  Android-File-Transfer
//
//  Created by Ricky on 2026/5/29.
//

import SwiftUI
import MTPKit

/// A copyable USB scan window. Open via 工具 ▸ USB 診斷… (⇧⌘D).
/// Plug in the phone (file-transfer/MTP mode), scan, and copy the output for debugging.
struct USBDiagnosticsView: View {
    @State private var report = "掃描中…"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("USB Diagnostics", systemImage: "cable.connector")
                    .font(.headline)
                Spacer()
                Button { report = USBDiagnostics.report() } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                Button { copyReport() } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }

            ScrollView {
                Text(report)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minWidth: 560, minHeight: 360)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text("Copy the report above to share USB device details for troubleshooting.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .onAppear { report = USBDiagnostics.report() }
    }

    private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }
}
