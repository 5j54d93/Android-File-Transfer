//
//  TransferOverlayView.swift
//  Android-File-Transfer
//
//  Created by Ricky on 2026/6/4.
//

import SwiftUI

/// A full-window frosted-glass overlay shown while files are transferring — in the spirit of
/// Google's Android File Transfer. It blurs the whole app, centres a live progress card, and
/// disappears the moment everything finishes (no lingering history). If a batch ends with
/// failures it stays put, listing them with Retry All / Close.
struct TransferOverlayView: View {
    @Bindable var transfers: TransferManager

    var body: some View {
        ZStack {
            // A light scrim: dims the app so the card is the focus, but the file list stays
            // visible underneath, and still swallows clicks so nothing behind can be touched
            // mid-transfer. Deliberately a plain translucent colour, NOT `.ultraThinMaterial`:
            // a full-window material is a live backdrop blur, and animating it in/out forces the
            // whole window (the file table) to re-render every frame — which caused a ~2s
            // main-thread hang when navigating right after a transfer finished.
            Rectangle()
                .fill(Color.black.opacity(0.18))
                .ignoresSafeArea()

            // Solid panel — deliberately NOT `.glassEffect` (Liquid Glass). The paused main-thread
            // stack during the hang showed CA::Transaction::commit blocked in
            // RB::SharedSurfaceGroup::wait_for_allocations: the Liquid Glass backdrop kept churning
            // GPU shared surfaces, so the *next* CoreAnimation commit (the file-table re-render
            // right after a transfer) stalled ~1s waiting for surface allocation. A flat fill
            // needs no off-screen surface, so the commit no longer blocks.
            card
                .frame(width: 400)
                .padding(28)
                .background(.background, in: .rect(cornerRadius: 16))
                .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
        }
    }

    @ViewBuilder
    private var card: some View {
        // Show the failure card only when a finished batch genuinely has failures. Otherwise —
        // in flight, *or* during the brief fade-out after a fully successful batch — show the
        // progress card, so a successful finish doesn't flash the failure screen on its way out.
        if transfers.activeCount == 0 && transfers.hasFailures {
            failureCard
        } else {
            progressCard
        }
    }

    // MARK: Progress

    private var progressCard: some View {
        VStack(spacing: 0) {
            Image(systemName: directionIcon)
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse)
                .padding(.bottom, 10)

            Text(transferTitleText)
                .font(.headline)
                .contentTransition(.numericText())
                .padding(.bottom, 12)

            VStack(spacing: 4) {
                if let name = transfers.currentItem?.name {
                    Text(name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let destination = destinationFolderText {
                    Label {
                        Text(destination)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } icon: {
                        Image(systemName: "folder")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(destination)
                }
            }
            .padding(.bottom, 22)

            VStack(spacing: 0) {
                // Keep the count/speed/ETA close to the progress bar; hide only during the
                // brief successful fade-out when the batch has already cleared.
                if shouldShowTransferStats {
                    HStack {
                        Text(sizeText)
                            .contentTransition(.numericText())
                        Spacer(minLength: 8)
                        if !detailText.isEmpty {
                            Text(detailText)
                                .contentTransition(.numericText(countsDown: true))
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .animation(.easeInOut(duration: 0.2), value: detailText)
                    .padding(.bottom, 2)
                }

                ProgressView(value: transfers.batchProgress)

                Button { transfers.cancelAll() } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .controlSize(.large)
                .padding(.top, 12)
            }
        }
    }

    /// Up/down arrow matching the in-flight item's direction (falls back to both when idle).
    private var directionIcon: String {
        guard let direction = transfers.currentItem?.direction else { return "arrow.up.arrow.down.circle" }
        return direction == .download ? "arrow.down.circle" : "arrow.up.circle"
    }

    private var destinationFolderText: String? {
        let text = transfers.currentItem?.destinationFolder?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    private var shouldShowTransferStats: Bool {
        transfers.batchTotal > 0
    }

    private var transferTitleText: String {
        guard transfers.batchTotal > 1 else {
            return NSLocalizedString("Transferring", comment: "")
        }
        return String(
            format: NSLocalizedString("Transferring (%lld/%lld)", comment: ""),
            Int64(transfers.batchCompleted),
            Int64(transfers.batchTotal)
        )
    }

    /// Current file's byte progress, e.g. "1.1 GB / 2.8 GB".
    private var sizeText: String {
        guard let item = transfers.currentItem, item.totalBytes > 0 else { return "" }
        return "\(Format.size(item.completedBytes)) / \(Format.size(item.totalBytes))"
    }

    /// Speed · ETA for the current item, e.g. "2.4 MB/s · about 12s".
    private var detailText: String {
        guard let item = transfers.currentItem else { return "" }
        let parts = [Format.speed(item.bytesPerSecond), Format.eta(item.etaSeconds)].compactMap { $0 }
        return parts.joined(separator: " · ")
    }

    // MARK: Failure

    private var failureCard: some View {
        VStack(spacing: 18) {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.yellow)

                Text("Some Transfers Failed")
                    .font(.headline)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(transfers.failedItems) { item in
                        HStack(spacing: 8) {
                            Image(systemName: item.direction == .download
                                  ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                                .foregroundStyle(.red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).lineLimit(1)
                                if case .failed(let message) = item.status {
                                    Text(message)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)

            HStack {
                Button("Close") { transfers.clearFinished() }
                    .controlSize(.large)
                Spacer()
                Button("Retry All") { transfers.retryAll() }
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
