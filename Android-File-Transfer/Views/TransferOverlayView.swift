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
            // Frosted glass over the whole app; also swallows clicks so the blurred content
            // underneath can't be touched mid-transfer.
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            card
                .frame(width: 400)
                .padding(28)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16).strokeBorder(.separator, lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.25), radius: 30, y: 10)
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
        VStack(spacing: 18) {
            Image(systemName: directionIcon)
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse)

            VStack(spacing: 6) {
                Text("Transferring…")
                    .font(.headline)
                if let name = transfers.currentItem?.name {
                    Text(name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            VStack(spacing: 10) {
                ProgressView(value: transfers.batchProgress)

                // Only show the count/speed/ETA line when there's something to show, so an
                // empty line doesn't pad the card out before a speed estimate exists.
                if transfers.batchTotal > 1 || !detailText.isEmpty {
                    HStack {
                        if transfers.batchTotal > 1 {
                            Text("\(transfers.batchCompleted) / \(transfers.batchTotal)")
                        }
                        Spacer()
                        Text(detailText)
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.2), value: detailText)
                }

                Button { transfers.cancelAll() } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .controlSize(.large)
                .padding(.top, 2)
            }
        }
    }

    /// Up/down arrow matching the in-flight item's direction (falls back to both when idle).
    private var directionIcon: String {
        guard let direction = transfers.currentItem?.direction else { return "arrow.up.arrow.down.circle" }
        return direction == .download ? "arrow.down.circle" : "arrow.up.circle"
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
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.orange)

            Text("Some Transfers Failed")
                .font(.headline)

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
