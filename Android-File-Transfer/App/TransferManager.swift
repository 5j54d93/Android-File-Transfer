//
//  TransferManager.swift
//  Android-File-Transfer
//
//  Created by Ricky on 2026/5/29.
//

import SwiftUI
import MTPKit

/// Runs uploads/downloads through a single serial queue. MTP allows only one
/// transaction at a time, so transfers must not run concurrently — items wait their
/// turn and run one-by-one. Tracks live speed/ETA and supports retry of failed items.
@MainActor
@Observable
final class TransferManager {
    enum Direction { case upload, download }
    enum Status: Equatable { case waiting, running, completed, failed(String), cancelled }

    /// Everything needed to (re)start a transfer, so failed items can be retried.
    enum Job {
        case download(node: FileNode, folder: URL)
        case upload(localURL: URL, parentID: String?, storageID: String)
    }

    @Observable
    final class Item: Identifiable {
        let id = UUID()
        let name: String
        let direction: Direction
        var completedBytes: Int64 = 0
        var totalBytes: Int64 = 0
        var status: Status = .waiting
        var bytesPerSecond: Double = 0
        @ObservationIgnored let job: Job
        @ObservationIgnored var task: Task<Void, Never>?
        @ObservationIgnored var startedAt: Date?
        @ObservationIgnored var lastSampleTime: Date?
        @ObservationIgnored var lastSampleBytes: Int64 = 0

        init(name: String, direction: Direction, totalBytes: Int64, job: Job) {
            self.name = name
            self.direction = direction
            self.totalBytes = totalBytes
            self.job = job
        }

        var fraction: Double {
            totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0
        }

        /// Seconds remaining, or nil if not yet estimable.
        var etaSeconds: Double? {
            guard status == .running, bytesPerSecond > 1, totalBytes > completedBytes else { return nil }
            return Double(totalBytes - completedBytes) / bytesPerSecond
        }
    }

    private(set) var items: [Item] = []
    private(set) var transport: (any DeviceTransport)?
    @ObservationIgnored var alerts: AppAlerts?

    private var queue: [Item] = []
    private var isRunning = false

    var activeCount: Int { items.filter { $0.status == .running || $0.status == .waiting }.count }
    var hasFinished: Bool { items.contains { $0.status != .running && $0.status != .waiting } }

    /// The transport is set by the browser whenever it opens a storage.
    func bind(_ transport: any DeviceTransport) { self.transport = transport }

    // MARK: Enqueue

    func download(_ node: FileNode, from transport: any DeviceTransport, to folder: URL) {
        self.transport = transport
        let item = Item(name: node.name, direction: .download, totalBytes: node.size,
                        job: .download(node: node, folder: folder))
        enqueue(item)
    }

    func upload(_ localURL: URL, toParent parentID: String?, storage storageID: String, via transport: any DeviceTransport) {
        self.transport = transport
        let item = Item(name: localURL.lastPathComponent, direction: .upload,
                        totalBytes: Format.fileSize(at: localURL),
                        job: .upload(localURL: localURL, parentID: parentID, storageID: storageID))
        enqueue(item)
    }

    func retry(_ item: Item) {
        guard case .failed = item.status else { return }
        let fresh = Item(name: item.name, direction: item.direction, totalBytes: item.totalBytes, job: item.job)
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx] = fresh
        } else {
            items.insert(fresh, at: 0)
        }
        queue.append(fresh)
        pump()
    }

    private func enqueue(_ item: Item) {
        items.insert(item, at: 0)
        queue.append(item)
        pump()
    }

    // MARK: Serial pump

    private func pump() {
        guard !isRunning, let transport else { return }
        guard let next = queue.first else { return }
        queue.removeFirst()
        isRunning = true
        next.status = .running
        next.startedAt = Date()
        next.lastSampleTime = Date()

        next.task = Task { [weak self] in
            await self?.run(next, on: transport)
            self?.isRunning = false
            self?.pump()
        }
    }

    private func run(_ item: Item, on transport: any DeviceTransport) async {
        let onProgress: ProgressHandler = { progress in
            Task { @MainActor [weak item] in
                guard let item else { return }
                item.completedBytes = progress.completedBytes
                item.totalBytes = progress.totalBytes
                self.sampleSpeed(item)
            }
        }
        do {
            switch item.job {
            case .download(let node, let folder):
                try await transport.download(node.id, to: folder.appendingPathComponent(node.name), progress: onProgress)
            case .upload(let localURL, let parentID, let storageID):
                try await transport.upload(localURL: localURL, as: localURL.lastPathComponent,
                                           toParent: parentID, in: storageID, progress: onProgress)
            }
            item.status = .completed
            item.bytesPerSecond = 0
        } catch is CancellationError {
            item.status = .cancelled
        } catch {
            let message = error.friendlyMessage
            item.status = .failed(message)
            let verb = item.direction == .download
                ? NSLocalizedString("Download", comment: "")
                : NSLocalizedString("Upload", comment: "")
            alerts?.error(String(format: NSLocalizedString("%@ \"%@\" failed: %@", comment: ""), verb, item.name, message))
        }
    }

    /// Exponentially-smoothed throughput so the number doesn't jitter every chunk.
    private func sampleSpeed(_ item: Item) {
        let now = Date()
        guard let last = item.lastSampleTime else { item.lastSampleTime = now; return }
        let dt = now.timeIntervalSince(last)
        guard dt >= 0.25 else { return }
        let delta = Double(item.completedBytes - item.lastSampleBytes)
        let instant = delta / dt
        item.bytesPerSecond = item.bytesPerSecond == 0 ? instant : item.bytesPerSecond * 0.6 + instant * 0.4
        item.lastSampleTime = now
        item.lastSampleBytes = item.completedBytes
    }

    // MARK: Controls

    func cancel(_ item: Item) {
        item.task?.cancel()
        queue.removeAll { $0.id == item.id }
        if item.status == .waiting { item.status = .cancelled }
    }

    func clearFinished() {
        items.removeAll { item in
            switch item.status {
            case .completed, .cancelled, .failed: return true
            case .running, .waiting: return false
            }
        }
    }
}
