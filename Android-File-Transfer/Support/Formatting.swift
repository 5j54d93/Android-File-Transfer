//
//  Formatting.swift
//  Android-File-Transfer
//
//  Created by Ricky on 2026/5/29.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MTPKit

/// Small formatting/icon helpers shared by the browser views.
enum Format {
    static func size(_ bytes: Int64) -> String {
        bytes <= 0 ? "—" : bytes.formatted(.byteCount(style: .file))
    }

    static func date(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// e.g. "2.4 MB/s". Returns nil for negligible/zero rates.
    static func speed(_ bytesPerSecond: Double) -> String? {
        guard bytesPerSecond > 1 else { return nil }
        
        let units = ["B", "kB", "MB", "GB", "TB", "PB"]
        var value = bytesPerSecond
        var unitIndex = 0
        
        // 你原本使用的 .file style 是以 1000 為進位基準（Apple 的標準檔案大小計算方式）
        // 如果你希望用 1024 進位（顯示為 KiB, MiB），請把下面的 1000 改成 1024
        while value >= 1000 && unitIndex < units.count - 1 {
            value /= 1000
            unitIndex += 1
        }
        
        // B / kB are fine as whole numbers; MB and up get one decimal place (unitIndex ≥ 2 = MB+).
        let format = unitIndex >= 2 ? "%.1f %@/s" : "%.0f %@/s"
        return String(format: format, value, units[unitIndex])
    }

    /// Compact remaining-time string, e.g. "about 12s" / "約 12 秒".
    static func eta(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 1 else { return nil }
        
        // 小於 60 秒：顯示到小數第一位秒數
        if seconds < 60 {
            return String(format: NSLocalizedString("about %.1fs", comment: ""), seconds)
        }
        
        // 小於 3600 秒（1小時）：顯示到小數第一位分鐘數
        if seconds < 3600 {
            return String(format: NSLocalizedString("about %.1fm", comment: ""), seconds / 60)
        }
        
        // 1 小時以上：顯示到小數第一位小時數
        return String(format: NSLocalizedString("about %.1fh", comment: ""), seconds / 3600)
    }

    static func kind(for node: FileNode) -> String {
        if node.isDirectory { return NSLocalizedString("Folder", comment: "") }
        if let ext = node.fileExtension, let type = UTType(filenameExtension: ext) {
            return type.localizedDescription ?? String(format: NSLocalizedString("%@ File", comment: ""), ext.uppercased())
        }
        return NSLocalizedString("Document", comment: "")
    }

    static func utType(for node: FileNode) -> UTType {
        if node.isDirectory { return .folder }
        if let ext = node.fileExtension, let type = UTType(filenameExtension: ext) { return type }
        return .data
    }

    static func fileSize(at url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? Int64) ?? 0
    }
}

/// Renders the real Finder/system icon for a node so the list looks native.
struct FileIcon: View {
    let node: FileNode
    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(for: Format.utType(for: node)))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
    }
}
