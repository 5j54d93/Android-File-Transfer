//
//  PathBarView.swift
//  Android-File-Transfer
//
//  Created by Ricky on 2026/5/29.
//

import SwiftUI
import MTPKit

/// Clickable breadcrumb path, like Finder's path bar.
struct PathBarView: View {
    @Bindable var browser: BrowserViewModel

    var body: some View {
        HStack(spacing: 4) {
            crumb(label: browser.storage?.name ?? "根目錄", systemImage: "externaldrive") {
                browser.navigate(toDepth: 0)
            }
            ForEach(Array(browser.pathStack.enumerated()), id: \.element.id) { index, dir in
                Image(systemName: "chevron.compact.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                crumb(label: dir.name, systemImage: nil) {
                    browser.navigate(toDepth: index + 1)
                }
            }
            Spacer(minLength: 12)
            if let storage = browser.storage, storage.capacityBytes > 0 {
                StorageUsageLabel(storage: storage)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ViewBuilder
    private func crumb(label: String, systemImage: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage) }
                Text(label).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}

/// Compact storage gauge shown at the right of the path bar: a small capacity bar plus the
/// used/free percentages. Turns orange then red as the device fills up.
private struct StorageUsageLabel: View {
    let storage: StorageInfo

    private var usedFraction: Double {
        guard storage.capacityBytes > 0 else { return 0 }
        let used = storage.capacityBytes - storage.freeBytes
        return min(1, max(0, Double(used) / Double(storage.capacityBytes)))
    }

    private var barColor: Color {
        switch usedFraction {
        case ..<0.75: return .accentColor
        case ..<0.9: return .orange
        default: return .red
        }
    }

    var body: some View {
        let usedPct = Int((usedFraction * 100).rounded())
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(width: 90, height: 6)
                Capsule().fill(barColor).frame(width: 90 * CGFloat(usedFraction), height: 6)
            }
            Text(String(format: NSLocalizedString("Used %d%% · Free %d%%", comment: ""),
                        usedPct, 100 - usedPct))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .help(String(format: NSLocalizedString("%@ free of %@", comment: ""),
                     Format.size(storage.freeBytes), Format.size(storage.capacityBytes)))
        .fixedSize()
    }
}
