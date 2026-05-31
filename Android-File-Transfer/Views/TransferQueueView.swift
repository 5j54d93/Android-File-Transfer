//
//  TransferQueueView.swift
//  Android-File-Transfer
//
//  Created by Ricky on 2026/5/29.
//

import SwiftUI

/// Popover showing the transfer queue: active, waiting, and finished items with live
/// speed/ETA, cancel, and retry-on-failure.
struct TransferQueueView: View {
    @Bindable var transfers: TransferManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Transfers").font(.headline)
                if transfers.activeCount > 0 {
                    Text(String(format: NSLocalizedString("%d in progress", comment: ""), transfers.activeCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear Finished") { transfers.clearFinished() }
                    .buttonStyle(.link)
                    .disabled(!transfers.hasFinished)
            }

            if transfers.items.isEmpty {
                Text("No active transfers")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(transfers.items) { item in
                            TransferRow(
                                item: item,
                                onCancel: { transfers.cancel(item) },
                                onRetry: { transfers.retry(item) }
                            )
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}

private struct TransferRow: View {
    @Bindable var item: TransferManager.Item
    let onCancel: () -> Void
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).lineLimit(1)
                if item.status == .running || item.status == .waiting {
                    ProgressView(value: item.fraction)
                }
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            trailingControl
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch item.status {
        case .running, .waiting:
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Cancel")
        case .failed:
            Button(action: onRetry) {
                Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .help("Retry")
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .cancelled:
            EmptyView()
        }
    }

    private var isFailed: Bool { if case .failed = item.status { return true } else { return false } }

    private var iconName: String {
        item.direction == .download ? "arrow.down.circle.fill" : "arrow.up.circle.fill"
    }
    private var iconColor: Color {
        switch item.status {
        case .failed: return .red
        case .cancelled: return .secondary
        default: return .accentColor
        }
    }

    private var statusText: String {
        switch item.status {
        case .waiting:
            return NSLocalizedString("Waiting…", comment: "")
        case .running:
            let progress = "\(Format.size(item.completedBytes)) / \(Format.size(item.totalBytes))"
            let extras = [Format.speed(item.bytesPerSecond), Format.eta(item.etaSeconds)].compactMap { $0 }
            return extras.isEmpty ? progress : "\(progress) · \(extras.joined(separator: " · "))"
        case .completed:
            return String(format: NSLocalizedString("Completed · %@", comment: ""), Format.size(item.totalBytes))
        case .cancelled:
            return NSLocalizedString("Cancelled", comment: "")
        case .failed(let message):
            return String(format: NSLocalizedString("Failed: %@", comment: ""), message)
        }
    }
}
