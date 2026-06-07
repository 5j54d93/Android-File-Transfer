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
                // No drop shadow: a blurred shadow is an offscreen render the CoreAnimation commit
                // re-rasterises, which is costly when the overlay tears down as the file list
                // re-renders after a transfer. The scrim already separates the card from the page.
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
            Text(transferTitleText)
                .font(.headline)
                .contentTransition(.numericText())
            
            stepBar
                .padding(18)

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
                }
                .buttonStyle(HoverFillButtonStyle())
                .padding(.top, 12)
            }
        }
    }

    // MARK: Phase step indicator
    //
    // A file goes through three perceptible phases — Prepare (announce + wait for the channel),
    // Transfer (the bytes), Complete (device commits to flash and confirms). The last one can
    // visibly stall, so the indicator highlights it and the detail line explains we're waiting on
    // the phone — rather than the bar looking stuck partway through.

    private enum Phase: Int { case preparing = 0, transferring = 1, finalizing = 2 }
    private enum StepState { case done, current, pending }

    /// Which phase the current item is in, derived purely from its byte counts.
    private var currentPhase: Phase {
        guard let item = transfers.currentItem else { return .preparing }
        if item.totalBytes > 0, item.completedBytes >= item.totalBytes { return .finalizing }
        if item.completedBytes > 0 { return .transferring }
        return .preparing
    }

    private func stepState(_ index: Int) -> StepState {
        let current = currentPhase.rawValue
        if index < current { return .done }
        if index == current { return .current }
        return .pending
    }

    private var directionArrowIcon: String {
        transfers.currentItem?.direction == .download ? "arrow.down" : "arrow.up"
    }

    private var stepBar: some View {
        HStack(alignment: .top, spacing: 6) {
            stepNode(0, label: "Prepare", icon: "hourglass")
            connector(after: 0)
            stepNode(1, label: "Transfer", icon: directionArrowIcon)
            connector(after: 1)
            stepNode(2, label: "Complete", icon: "externaldrive")
        }
        .frame(maxWidth: 280)
    }

    /// Completed steps are green; the in-progress step keeps the accent tint.
    private let stepDoneColor = Color.green

    private func stepNode(_ index: Int, label: LocalizedStringKey, icon: String) -> some View {
        let state = stepState(index)
        let circleFill: AnyShapeStyle
        switch state {
        case .done: circleFill = AnyShapeStyle(stepDoneColor)
        case .current: circleFill = AnyShapeStyle(.tint)
        case .pending: circleFill = AnyShapeStyle(Color.secondary.opacity(0.15))
        }
        return VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(circleFill)
                    .frame(width: 30, height: 30)
                Image(systemName: state == .done ? "checkmark" : icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(state == .pending ? Color.secondary : Color.white)
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(state == .pending ? .secondary : .primary)
        }
        .fixedSize()
    }

    /// Flexible connector between two nodes; top padding lifts it to the circles' centre line
    /// (the nodes' labels sit below, so a centred HStack would drop the line too low).
    private func connector(after index: Int) -> some View {
        let left = stepState(index)
        let right = stepState(index + 1)
        let fill: AnyShapeStyle
        if left == .done, right == .current {
            // The leading edge: a completed (green) step feeding the in-progress (blue) one.
            fill = AnyShapeStyle(LinearGradient(colors: [stepDoneColor, .accentColor],
                                                startPoint: .leading, endPoint: .trailing))
        } else if left == .done {
            fill = AnyShapeStyle(stepDoneColor)              // between two completed steps
        } else {
            fill = AnyShapeStyle(Color.secondary.opacity(0.2))
        }
        return Capsule()
            .fill(fill)
            .frame(height: 2)
            .padding(.top, 14)
            .frame(maxWidth: .infinity)
    }

    private var destinationFolderText: String? {
        let text = transfers.currentItem?.destinationFolder?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    private var shouldShowTransferStats: Bool {
        transfers.batchTotal > 0
    }

    private var transferTitleText: String {
        switch currentPhase {
        case .preparing:
            return NSLocalizedString("Preparing…", comment: "")
        case .finalizing:
            return NSLocalizedString("Finalizing…", comment: "")
        case .transferring:
            guard transfers.batchTotal > 1 else {
                return NSLocalizedString("Transferring", comment: "")
            }
            return String(
                format: NSLocalizedString("Transferring (%lld/%lld)", comment: ""),
                Int64(transfers.batchCompleted),
                Int64(transfers.batchTotal)
            )
        }
    }

    /// Current file's byte progress, e.g. "1.1 GB / 2.8 GB".
    private var sizeText: String {
        guard let item = transfers.currentItem, item.totalBytes > 0 else { return "" }
        return "\(Format.size(item.completedBytes)) / \(Format.size(item.totalBytes))"
    }

    /// Phase-specific subtext shown next to the byte count. During the transfer it's speed · ETA;
    /// the title carries the phase name, so here we add only what the title can't: while finalizing,
    /// *why* the bar is parked at 100% — the device is committing the file and we're awaiting its
    /// confirmation (for uploads, explicitly "waiting for phone").
    private var detailText: String {
        guard let item = transfers.currentItem else { return "" }
        switch currentPhase {
        case .finalizing:
            return item.direction == .upload
                ? NSLocalizedString("Waiting for phone to confirm…", comment: "upload bytes sent; awaiting device response")
                : NSLocalizedString("Finalizing…", comment: "download bytes received; flushing to disk")
        case .preparing:
            return ""
        case .transferring:
            return [Format.speed(item.bytesPerSecond), Format.eta(item.etaSeconds)]
                .compactMap { $0 }
                .joined(separator: "・")
        }
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

/// A full-width button that's quietly filled at rest and, on hover, fills with the accent colour
/// and flips its text to white — giving the overlay's Cancel a clear, responsive affordance.
/// (Hover state lives in a nested view because a `ButtonStyle` can't hold `@State` itself.)
private struct HoverFillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Hoverable(configuration: configuration)
    }

    private struct Hoverable: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .foregroundStyle(hovering ? Color.white : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovering ? AnyShapeStyle(Color.red) : AnyShapeStyle(Color.secondary.opacity(0.12)))
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .opacity(configuration.isPressed ? 0.7 : 1)
                .animation(.easeInOut(duration: 0.15), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}
