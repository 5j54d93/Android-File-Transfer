//
//  FileBrowserView.swift
//  Android-File-Transfer
//
//  Created by Ricky on 2026/5/29.
//

import SwiftUI
import MTPKit
import UniformTypeIdentifiers

/// The Finder-like detail pane: breadcrumb + multi-column file table + toolbar.
/// Drag files from Finder onto it to upload; drag files out to Finder to download.
struct FileBrowserView: View {
    @Bindable var browser: BrowserViewModel
    @Bindable var transfers: TransferManager

    @State private var newFolderPresented = false
    @State private var newFolderName = String(localized: "untitled folder")
    @State private var renameTarget: FileNode?
    @State private var renameName = ""
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            PathBarView(browser: browser)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar { toolbarContent }
        // Drag files from Finder anywhere onto the window to upload them to the current folder.
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
            return !urls.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .sheet(isPresented: $newFolderPresented) {
            NameSheet(title: "New Folder", label: "Name", text: $newFolderName, confirmTitle: "Create") {
                browser.createFolder(named: newFolderName)
            }
        }
        .sheet(item: $renameTarget) { target in
            NameSheet(title: "Rename", label: "New Name", text: $renameName, confirmTitle: "Rename") {
                browser.rename(target.id, to: renameName)
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if browser.entries.isEmpty && !browser.isLoading {
            // While a drag hovers an empty folder, the icon opens up (a receiving tray) and
            // tints, like spring-loaded folders in Finder.
            ContentUnavailableView {
                Label {
                    Text("This Folder Is Empty")
                } icon: {
                    Image(systemName: isDropTargeted ? "tray.and.arrow.down.fill" : "folder")
                        .foregroundStyle(isDropTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .scaleEffect(isDropTargeted ? 1.12 : 1)
                        .contentTransition(.symbolEffect(.replace))
                }
            } description: {
                Text(isDropTargeted ? "Release to upload here" : "Drag files here to upload.")
            }
            .animation(.spring(duration: 0.25), value: isDropTargeted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .contextMenu {
                Button("New Folder") { presentNewFolder() }
            }
        } else {
            fileTable
                .overlay { if browser.isLoading { ProgressView() } }
        }
    }

    private var fileTable: some View {
        Table(browser.entries, selection: $browser.selection) {
            TableColumn("Name") { node in
                draggableCell(node) {
                    HStack(spacing: 6) {
                        FileIcon(node: node).frame(width: 18, height: 18)
                        Text(node.name).lineLimit(1)
                    }
                }
            }
            TableColumn("Size") { node in
                draggableCell(node) {
                    Text(node.isDirectory ? "—" : Format.size(node.size))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .width(min: 70, ideal: 90)
            TableColumn("Kind") { node in
                draggableCell(node) {
                    Text(Format.kind(for: node)).foregroundStyle(.secondary)
                }
            }
            .width(min: 90, ideal: 140)
            TableColumn("Date Modified") { node in
                draggableCell(node) {
                    Text(Format.date(node.modifiedDate)).foregroundStyle(.secondary)
                }
            }
            .width(min: 120, ideal: 170)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            menuItems(for: ids)
        } primaryAction: { ids in
            performPrimaryAction(for: ids)
        }
        .background {
            // Finder convention: Return renames the selected item (not "open"). A default-
            // action button catches Return via performKeyEquivalent *before* the Table maps
            // it to primaryAction (which would otherwise download the file). Enabled only for
            // a single selection so multi/empty selections just fall through harmlessly.
            Button("", action: renameSelected)
                .keyboardShortcut(.return, modifiers: [])
                .opacity(0)
                .allowsHitTesting(false)
                .disabled(browser.selection.count != 1)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if browser.canGoUp {
            ToolbarItem(placement: .navigation) {
                Button { browser.goUp() } label: { Image(systemName: "chevron.backward") }
                    .help("Back")
                    .disabled(transfers.isPresenting)
            }
        }
        ToolbarItemGroup {
            Button { presentNewFolder() } label: {
                Image(systemName: "folder.badge.plus")
            }
            .help("New Folder")
            .disabled(transfers.isPresenting)

            Button(role: .destructive) { browser.delete(browser.selection) } label: {
                Image(systemName: "trash")
            }
            .disabled(browser.selection.isEmpty || transfers.isPresenting)
            .help("Delete Selected")
        }
    }

    // MARK: Menu / actions

    @ViewBuilder
    private func menuItems(for ids: Set<String>) -> some View {
        let nodes = browser.entries.filter { ids.contains($0.id) }
        if nodes.isEmpty {
            // Right-clicked empty space → folder-level actions, like Finder.
            Button("New Folder") { presentNewFolder() }
        } else {
            if nodes.count == 1, let node = nodes.first, node.isDirectory {
                Button("Open") { browser.enter(node) }
            }
            let files = nodes.filter { !$0.isDirectory }
            if !files.isEmpty {
                Button("Download to Downloads") { download(nodes: files) }
            }
            if nodes.count == 1, let node = nodes.first {
                Button("Rename…") { renameName = node.name; renameTarget = node }
            }
            Divider()
            Button("Delete", role: .destructive) { browser.delete(Set(nodes.map(\.id))) }
        }
    }

    private func presentNewFolder() {
        newFolderName = String(localized: "untitled folder")
        newFolderPresented = true
    }

    /// Wraps a cell's content so the *entire* cell — across every column — is a file-promise
    /// drag source for file rows, making the whole row draggable out to Finder. The content
    /// is stretched to fill the cell so there are no dead zones, and the overlay forwards
    /// plain clicks/double-clicks back so Table selection keeps working. Folder rows keep the
    /// Table's native click behaviour (no overlay).
    @ViewBuilder
    private func draggableCell<Content: View>(_ node: FileNode,
                                              @ViewBuilder content: () -> Content) -> some View {
        if !node.isDirectory, let transport = browser.transport {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(
                    FilePromiseDragView(
                        node: node, transport: transport, transfers: transfers,
                        onClick: { selectNode(node, extend: $0) },
                        onDoubleClick: { performPrimaryAction(for: [node.id]) },
                        nodesToDrag: {
                            // Grabbing a row that's part of the selection drags all selected
                            // files; grabbing an unselected row drags just that one.
                            if browser.selection.contains(node.id) {
                                let ids = browser.selection
                                let selected = browser.entries.filter { ids.contains($0.id) && !$0.isDirectory }
                                return selected.isEmpty ? [node] : selected
                            }
                            return [node]
                        }
                    )
                )
        } else {
            content()
        }
    }

    /// Update the Table selection for a click on `node`; `extend` (command/shift) toggles it
    /// in/out of a multi-selection, otherwise it becomes the sole selection.
    private func selectNode(_ node: FileNode, extend: Bool) {
        if extend {
            if browser.selection.contains(node.id) { browser.selection.remove(node.id) }
            else { browser.selection.insert(node.id) }
        } else {
            browser.selection = [node.id]
        }
    }

    /// Open the rename sheet for the single selected item (triggered by the Return key).
    private func renameSelected() {
        guard browser.selection.count == 1, let id = browser.selection.first,
              let node = browser.entries.first(where: { $0.id == id }) else { return }
        renameName = node.name
        renameTarget = node
    }

    private func performPrimaryAction(for ids: Set<String>) {
        guard ids.count == 1, let node = browser.entries.first(where: { $0.id == ids.first }) else { return }
        if node.isDirectory {
            browser.enter(node)
        } else {
            download(nodes: [node])
        }
    }

    private func download(nodes: [FileNode]) {
        guard let transport = browser.transport, !nodes.isEmpty else { return }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        for node in nodes {
            transfers.download(node, from: transport, to: downloads)
        }
    }

    private func handleDrop(_ urls: [URL]) {
        guard let transport = browser.transport, let storageID = browser.storageID else { return }
        for url in urls where !url.hasDirectoryPath {
            transfers.upload(url, toParent: browser.currentParentID, storage: storageID, via: transport)
        }
    }
}

/// Small reusable sheet for entering a single name (new folder / rename).
private struct NameSheet: View {
    let title: LocalizedStringKey
    let label: LocalizedStringKey
    @Binding var text: String
    let confirmTitle: LocalizedStringKey
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            TextField(label, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit(confirm)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func confirm() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onConfirm()
        dismiss()
    }
}
