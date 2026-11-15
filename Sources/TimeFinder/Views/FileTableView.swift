import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct FileTableView: View {
    @Environment(BrowserModel.self) private var model
    @SceneStorage("columns") private var columnCustomization = TableColumnCustomization<FileItem>()
    @State private var whereVisibilityBeforeSearch: Visibility?

    var body: some View {
        @Bindable var model = model
        Table(of: FileItem.self, selection: $model.selection, sortOrder: $model.sortOrder, columnCustomization: $columnCustomization) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { item in
                HStack(spacing: 6) {
                    FileIcon(item: item)
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .opacity(item.name.hasPrefix(".") ? 0.55 : 1)
            }
            .width(min: 180, ideal: 300)
            .customizationID("name")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("Where", value: \.parentPath) { item in
                Text(item.parentPath.isEmpty ? model.machineName : item.parentPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(item.parentPath)
            }
            .width(min: 120, ideal: 260)
            .customizationID("where")
            .defaultVisibility(.hidden)

            TableColumn("Date Modified", value: \.dateKey) { item in
                Text(item.modified?.formatted(date: .abbreviated, time: .shortened) ?? "--")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 130, ideal: 160, max: 220)
            .customizationID("date")

            TableColumn("Size", value: \.sizeKey) { item in
                Text(item.isFolderLike || item.size == nil ? "--" : ByteCountFormatter.string(fromByteCount: item.size ?? 0, countStyle: .file))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 64, ideal: 78, max: 120)
            .customizationID("size")

            TableColumn("Kind", value: \.kind) { item in
                Text(item.kind).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 90, ideal: 130)
            .customizationID("kind")
        } rows: {
            ForEach(model.displayedItems) { item in
                // Dragging rows out to Finder copies them out of the backup.
                TableRow(item).itemProvider { NSItemProvider(contentsOf: item.url) }
            }
        }
        .contextMenu(forSelectionType: FileItem.ID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            model.open(ids)
        }
        .quickLookPreview($model.quickLookURL, in: model.quickLookURLs)
        .onChange(of: model.quickLookURL) { model.quickLookDidMove() }
        .onChange(of: model.selection) { model.selectionDidChange() }
        // Space, Tab, type-select etc. are handled by FinderKeyboard; keep focus in the list like Finder.
        .onAppear { FinderKeyboard.shared.focusFileList() }
        .onChange(of: model.path) { FinderKeyboard.shared.focusFileList() }
        .onChange(of: model.isSearchActive) { _, searching in
            // Show "Where" for search results; afterwards restore whatever the user had chosen.
            if searching {
                whereVisibilityBeforeSearch = columnCustomization[visibility: "where"]
                columnCustomization[visibility: "where"] = .visible
            } else {
                columnCustomization[visibility: "where"] = whereVisibilityBeforeSearch ?? .hidden
            }
        }
        .overlay { emptyState }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<FileItem.ID>) -> some View {
        let items = model.displayedItems.filter { ids.contains($0.id) }
        if !items.isEmpty {
            Button("Open") { model.open(ids) }
            if items.count == 1, let item = items.first, item.isPackage {
                Button("Show Package Contents") { model.showPackageContents(item) }
            }
            if items.count == 1, let item = items.first, model.isSearchActive {
                Button("Show Enclosing Folder") { model.navigate(to: Array(item.relativePath.dropLast())) }
            }
            Divider()
            Button("Get Info") {
                model.selection = ids
                model.showInfo()
            }
            Button(items.count == 1 ? "Quick Look “\(items[0].name)”" : "Quick Look \(items.count) Items") {
                model.selection = ids
                model.toggleQuickLook()
            }
            Divider()
            Button(items.count == 1 ? "Copy “\(items[0].name)”" : "Copy \(items.count) Items") {
                model.selection = ids
                model.copySelectionToPasteboard()
            }
            Button("Copy as Pathname") {
                model.selection = ids
                model.copySelectionPaths()
            }
            Divider()
            Button("Restore To…") { model.chooseRestoreDestination(for: ids) }
            Button("Show in Finder") { model.revealInFinder(ids) }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.displayedItems.isEmpty {
            if let error = model.listingError, !model.isSearchActive {
                ContentUnavailableView("Can’t Read Folder", systemImage: "lock", description: Text(error))
            } else if model.isSearching || model.isListing {
                ProgressView().controlSize(.small)
            } else if model.isSearchActive {
                ContentUnavailableView.search(text: model.searchText)
            } else {
                Text("This folder is empty")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct FileIcon: View {
    let item: FileItem

    var body: some View {
        Image(nsImage: IconCache.shared.icon(for: item))
            .resizable()
            .interpolation(.high)
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
    }
}

/// Icons by file type. Deliberately not `NSWorkspace.icon(forFile:)`: reading each file's custom
/// icon inside a snapshot means synchronous I/O over the network on the main thread, and icon
/// services usually can't read Time Machine snapshots anyway.
@MainActor
final class IconCache {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]

    func icon(for item: FileItem) -> NSImage {
        let type: UTType
        if item.isSymlink {
            type = .aliasFile
        } else if item.isFolderLike {
            type = .folder
        } else {
            type = item.contentType ?? .data
        }
        if let cached = cache[type.identifier] { return cached }
        let image = NSWorkspace.shared.icon(for: type)
        cache[type.identifier] = image
        return image
    }
}
