import AppKit
import SwiftUI

/// The Time Machine–style timeline: every backup, newest first, on a vertical track that
/// shows where the selected item changed.
struct TimelineView: View {
    @Environment(BrowserModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if model.snapshots.isEmpty {
            Text("No Backups")
                .font(.title3)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                TimelineHeader()
                Divider()
                timeline
            }
        }
    }

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(entries) { entry in
                        switch entry.content {
                        case .month(let title):
                            MonthHeader(title: title, isFirst: entry.id == entries.first?.id, track: entry.track)
                        case .snapshot(let snapshot, let startsDay):
                            TimelineRow(
                                snapshot: snapshot,
                                mark: model.versionMarks[snapshot.id],
                                track: entry.track,
                                startsDay: startsDay,
                                isLatest: snapshot.id == model.snapshots.first?.id,
                                isSelected: snapshot.id == model.currentSnapshotID
                            ) {
                                model.selectSnapshot(snapshot.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            .onChange(of: model.currentSnapshotID) { _, id in
                // Keep the current backup in view when stepping with the toolbar or keyboard.
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo(id) }
            }
        }
    }

    /// Which halves of the track to draw in a row, so the line stops where the item is absent.
    struct Track: Equatable {
        var above = false
        var below = false
    }

    private struct Entry: Identifiable {
        enum Content {
            case month(String)
            case snapshot(Snapshot, startsDay: Bool)
        }

        let id: String
        let content: Content
        let track: Track
    }

    private var entries: [Entry] {
        let snapshots = model.snapshots
        let marks = model.versionMarks
        let calendar = Calendar.current
        func isPresent(_ index: Int) -> Bool {
            snapshots.indices.contains(index) && marks[snapshots[index].id] != .absent
        }

        var result: [Entry] = []
        for (index, snapshot) in snapshots.enumerated() {
            let previous = index > 0 ? snapshots[index - 1] : nil
            let above = isPresent(index) && isPresent(index - 1)
            let below = isPresent(index) && isPresent(index + 1)
            if previous.map({ !calendar.isDate($0.date, equalTo: snapshot.date, toGranularity: .month) }) ?? true {
                let title = snapshot.date.formatted(.dateTime.month(.wide).year())
                result.append(Entry(id: "month:\(title)", content: .month(title), track: Track(above: above, below: above)))
            }
            let startsDay = previous.map { !calendar.isDate($0.date, inSameDayAs: snapshot.date) } ?? true
            result.append(Entry(id: snapshot.id, content: .snapshot(snapshot, startsDay: startsDay), track: Track(above: above, below: below)))
        }
        return result
    }
}

// MARK: - Header

/// Shows what the timeline is annotated for, with controls to step through its versions.
private struct TimelineHeader: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if model.versionsFor != nil {
                ControlGroup {
                    Button { model.jumpToVersion(older: false) } label: {
                        Label("Newer Version", systemImage: "chevron.up")
                    }
                    .disabled(!model.hasNewerVersion)
                    .help("Go to the next version of the selected item (⌥⇧⌘→)")
                    Button { model.jumpToVersion(older: true) } label: {
                        Label("Older Version", systemImage: "chevron.down")
                    }
                    .disabled(!model.hasOlderVersion)
                    .help("Go to the previous version of the selected item (⌥⇧⌘←)")
                }
                .labelStyle(.iconOnly)
                .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 52)
    }

    private var selectedItem: FileItem? {
        guard let path = model.versionsFor else { return nil }
        return model.selectedItems.first { $0.relativePath == path }
    }

    @ViewBuilder
    private var icon: some View {
        if let item = selectedItem {
            Image(nsImage: IconCache.shared.icon(for: item))
                .resizable()
                .interpolation(.high)
                .accessibilityHidden(true)
        } else if model.versionsFor != nil {
            Image(nsImage: NSWorkspace.shared.icon(for: .data))
                .resizable()
                .interpolation(.high)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.secondary)
        }
    }

    private var title: String {
        if let name = model.versionsFor?.last { return name }
        let count = model.snapshots.count
        return "\(count) Backup\(count == 1 ? "" : "s")"
    }

    private var subtitle: String {
        guard model.versionsFor != nil else {
            return "Select an item to see its versions"
        }
        if model.isScanningVersions { return "Looking for versions…" }
        let versions = model.versionCount
        let backups = model.snapshots.count
        if versions == 0 { return "Not in any backup" }
        return "\(versions) version\(versions == 1 ? "" : "s") in \(backups) backup\(backups == 1 ? "" : "s")"
    }
}

// MARK: - Rows

private enum TimelineMetrics {
    static let trackWidth: CGFloat = 16
    static let rowHeight: CGFloat = 26
    static let rowInset: CGFloat = 6
}

/// The vertical line connecting consecutive backups, drawn per row in two halves.
private struct TrackLine: View {
    let track: TimelineView.Track

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().opacity(track.above ? 1 : 0)
            Rectangle().opacity(track.below ? 1 : 0)
        }
        .frame(width: 1.5)
        .foregroundStyle(.tertiary)
        .frame(width: TimelineMetrics.trackWidth)
    }
}

private struct MonthHeader: View {
    let title: String
    let isFirst: Bool
    let track: TimelineView.Track

    var body: some View {
        HStack(spacing: 8) {
            TrackLine(track: track)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, isFirst ? 2 : 10)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, TimelineMetrics.rowInset)
        .frame(height: isFirst ? 30 : 38)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct TimelineRow: View {
    let snapshot: Snapshot
    let mark: VersionMark?
    let track: TimelineView.Track
    let startsDay: Bool
    let isLatest: Bool
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    TrackLine(track: track)
                    marker
                }
                Text(snapshot.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                    .foregroundStyle(startsDay || isSelected ? .primary : .secondary)
                Spacer(minLength: 4)
                if isLatest {
                    Text("Latest")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Text(snapshot.date.formatted(date: .omitted, time: .shortened))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .lineLimit(1)
            .opacity(mark == .absent && !isSelected ? 0.4 : 1)
            .padding(.horizontal, TimelineMetrics.rowInset)
            .frame(height: TimelineMetrics.rowHeight)
            .foregroundStyle(isSelected && controlActiveState != .inactive ? AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor)) : AnyShapeStyle(.primary))
            .background(background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(snapshot.date.formatted(date: .complete, time: .shortened) + (isLatest ? ", latest backup" : ""))
        .accessibilityValue(accessibilityState)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var accessibilityState: String {
        switch mark {
        case .newVersion: "New version"
        case .unchanged: "Same as previous backup"
        case .absent: "Not in this backup"
        case .unknown: "Couldn’t be read"
        case nil: ""
        }
    }

    private var background: AnyShapeStyle {
        if isSelected {
            // Blue while the window is active, grey otherwise — like table selections.
            let color: NSColor = controlActiveState == .inactive ? .unemphasizedSelectedContentBackgroundColor : .selectedContentBackgroundColor
            return AnyShapeStyle(Color(nsColor: color))
        }
        return isHovered ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear)
    }

    @ViewBuilder
    private var marker: some View {
        switch mark {
        case .newVersion:
            // A new version: the one prominent mark on the track.
            Circle()
                .fill(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
                .frame(width: 9, height: 9)
        case .unchanged, .absent:
            // The track alone says "same as below" (line) or "not there" (gap).
            EmptyView()
        case .unknown:
            Circle()
                .strokeBorder(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                .frame(width: 8, height: 8)
        case nil:
            Circle()
                .fill(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: 5, height: 5)
        }
    }

    private var help: String {
        let date = snapshot.date.formatted(date: .complete, time: .shortened)
        switch mark {
        case .newVersion: return "\(date)\nA new version of the selected item was backed up."
        case .unchanged: return "\(date)\nSame version as in the previous backup."
        case .absent: return "\(date)\nThe selected item isn't in this backup."
        case .unknown: return "\(date)\nThis backup couldn’t be read, so it’s unknown whether the item changed."
        case nil: return date
        }
    }
}

// MARK: - Path bar

/// Finder-style path bar: clickable breadcrumbs on the left, item count on the right.
struct PathBar: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    crumb(name: model.machineName, icon: Self.computerIcon, path: [])
                    ForEach(Array(model.path.enumerated()), id: \.offset) { index, component in
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.tertiary)
                        crumb(
                            name: component,
                            icon: index == 0 ? Self.volumeIcon : Self.folderIcon,
                            path: Array(model.path.prefix(index + 1))
                        )
                    }
                }
                .padding(.leading, 10)
            }
            .defaultScrollAnchor(.trailing)
            Text(status)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .layoutPriority(1)
                .padding(.trailing, 10)
        }
        .font(.subheadline)
        .frame(height: 24)
        .background(.bar)
    }

    private static let computerIcon = NSImage(named: NSImage.computerName) ?? NSWorkspace.shared.icon(for: .folder)
    private static let volumeIcon = NSWorkspace.shared.icon(forFile: "/")
    private static let folderIcon = NSWorkspace.shared.icon(for: .folder)

    private func crumb(name: String, icon: NSImage, path: [String]) -> some View {
        Button { model.navigate(to: path) } label: {
            HStack(spacing: 4) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
                Text(name).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(([model.machineName] + path).joined(separator: " ▸ "))
    }

    private var status: String {
        if let busy = model.busyMessage { return busy }
        let count = model.displayedItems.count
        let selected = model.selection.count
        if model.isSearching { return "Searching… \(count) found" }
        var text = selected > 0 ? "\(selected) of \(count) selected" : "\(count) item\(count == 1 ? "" : "s")"
        if model.isSearchActive && count >= BrowserModel.searchLimit {
            text += " (limit reached)"
        }
        return text
    }
}
