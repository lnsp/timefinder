import SwiftUI

private enum SidebarItem: Hashable {
    case source(BackupSource.ID)
    case location(Location.ID)
}

struct SidebarView: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        List(selection: selection) {
            Section("Backups") {
                ForEach(model.sources) { source in
                    SourceRow(source: source, isActive: source.id == model.activeSourceID)
                        .tag(SidebarItem.source(source.id))
                        .contextMenu {
                            Button("Open") { model.open(source) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([source.url]) }
                                .disabled(!source.isReachable)
                            Divider()
                            Button("Remove from Sidebar", role: .destructive) { model.removeSource(source) }
                        }
                }
            }
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.locations) { location in
                        Label(location.name, systemImage: location.symbol)
                            .tag(SidebarItem.location(location.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button { model.chooseBackupToOpen() } label: { Label("Open Backup…", systemImage: "plus.circle") }
                    .help("Open a Time Machine backup from any mounted volume")
                Spacer()
                Button { model.refreshSources() } label: { Label("Refresh", systemImage: "arrow.clockwise").labelStyle(.iconOnly) }
                    .help("Look for backups on mounted volumes")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private struct LocationGroup: Identifiable {
        let title: String
        var locations: [Location]
        var id: String { title }
    }

    /// Splits the backup's places Finder-style: each user's folders, then the volumes.
    /// The backup itself (the root) is already represented by its row under "Backups".
    private var groups: [LocationGroup] {
        var homes: [LocationGroup] = []
        var volumes: [Location] = []
        for location in model.locations where !location.path.isEmpty {
            if location.symbol == "house" {
                homes.append(LocationGroup(title: location.name, locations: [location]))
            } else if location.path.count > 3, !homes.isEmpty {
                homes[homes.count - 1].locations.append(location)
            } else {
                volumes.append(location)
            }
        }
        if homes.count == 1 {
            homes[0] = LocationGroup(title: "Favorites", locations: homes[0].locations)
        }
        return homes + (volumes.isEmpty ? [] : [LocationGroup(title: "Locations", locations: volumes)])
    }

    /// Highlights the location matching the current folder; clicking a backup opens it.
    private static var isDeliberateChoice: Bool {
        guard let event = NSApp.currentEvent else { return false }
        switch event.type {
        case .leftMouseDown, .leftMouseUp: return true
        case .keyDown: return event.keyCode == 36 || event.keyCode == 76   // Return, Enter
        default: return false
        }
    }

    private var selection: Binding<SidebarItem?> {
        Binding {
            if let location = model.locations.first(where: { $0.path == model.path }) {
                return location.path.isEmpty ? model.activeSourceID.map { .source($0) } : .location(location.id)
            }
            return nil
        } set: { item in
            switch item {
            case .source(let id):
                guard let source = model.sources.first(where: { $0.id == id }) else { return }
                // The open backup's row doubles as its top level.
                if id == model.activeSourceID, model.session != nil {
                    model.navigate(to: [])
                } else if Self.isDeliberateChoice {
                    // Opening a backup unmounts the current one and may take a minute, so do it on a
                    // click or Return only — not while arrowing through the sidebar.
                    model.open(source)
                }
            case .location(let id):
                if let location = model.locations.first(where: { $0.id == id }) { model.navigate(to: location.path) }
            case nil:
                break
            }
        }
    }
}

private struct SourceRow: View {
    @Environment(BrowserModel.self) private var model
    let source: BackupSource
    let isActive: Bool

    var body: some View {
        HStack(spacing: 4) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.name).lineLimit(1)
                    if let status {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } icon: {
                Image(systemName: source.symbolName)
            }
            Spacer(minLength: 0)
            if isActive, case .working = model.phase {
                ProgressView().controlSize(.small)
            } else if isActive, model.session != nil {
                Button { model.closeSession() } label: {
                    Label("Eject", systemImage: "eject.fill").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Close “\(source.name)” and unmount its backups")
            }
        }
        .opacity(source.isReachable || source.serverURL != nil ? 1 : 0.5)
    }

    private var status: String? {
        guard !source.isReachable else { return nil }
        guard let host = source.serverURL.flatMap({ URL(string: $0)?.host }) else { return "Not available" }
        return "Not connected · \(host)"
    }
}
