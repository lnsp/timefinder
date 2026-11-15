import AppKit

/// Finder conventions: Tab order, type-select, the pasteboard, Go menu targets, Go to Folder.
extension BrowserModel {
    // MARK: Go menu

    var homePath: [String]? { locations.first { $0.symbol == "house" }?.path }
    private var volumePaths: [[String]] { locations.filter { $0.symbol == "internaldrive" }.map(\.path) }

    /// Home, or a folder directly inside it (`Desktop`, `Documents`, …) if the backup has one.
    func goHome(_ subfolder: String? = nil) {
        guard let home = homePath else { return }
        guard let subfolder else { return navigate(to: home) }
        if let location = locations.first(where: { $0.path == home + [subfolder] }) {
            navigate(to: location.path)
        } else if let root = snapshotRoot, Self.isDirectory(Self.url(root, home + [subfolder])) {
            navigate(to: home + [subfolder])
        }
    }

    func goToApplications() {
        if let applications = locations.first(where: { $0.path.last == "Applications" && $0.path.count == 2 }) {
            navigate(to: applications.path)
        }
    }

    // MARK: Selection

    private var alphabeticalItems: [FileItem] {
        displayedItems.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Finder's Tab / ⇧Tab: the next or previous item *alphabetically*, whatever the sort column.
    func adjacentItemID(forward: Bool) -> FileItem.ID? {
        let items = alphabeticalItems
        guard !items.isEmpty else { return nil }
        let selected = items.indices.filter { selection.contains(items[$0].id) }
        guard let anchor = forward ? selected.last : selected.first else {
            return forward ? items.first?.id : items.last?.id
        }
        let next = forward ? min(anchor + 1, items.count - 1) : max(anchor - 1, 0)
        return items[next].id
    }

    /// The next / previous row in the list as currently sorted (arrow keys).
    func adjacentDisplayedID(forward: Bool) -> FileItem.ID? {
        let items = displayedItems
        guard !items.isEmpty else { return nil }
        let selected = items.indices.filter { selection.contains(items[$0].id) }
        guard let anchor = forward ? selected.last : selected.first else { return items.first?.id }
        return items[forward ? min(anchor + 1, items.count - 1) : max(anchor - 1, 0)].id
    }

    /// Type-select: the first item starting with what was typed, else the nearest one after it.
    func typeSelectMatch(_ typed: String) -> FileItem.ID? {
        let items = alphabeticalItems
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if let prefixMatch = items.first(where: { $0.name.range(of: typed, options: options.union(.anchored)) != nil }) {
            return prefixMatch.id
        }
        return (items.first { $0.name.localizedStandardCompare(typed) == .orderedDescending } ?? items.last)?.id
    }

    func selectAll() {
        selection = Set(displayedItems.map(\.id))
    }

    // MARK: Quick Look

    /// Like Finder: with several items selected, Quick Look pages through those; with one,
    /// the arrow keys page through the whole folder and the selection follows.
    var quickLookURLs: [URL] {
        guard canAccessFiles else { return [] }
        let items = selection.count > 1 ? selectedItems : displayedItems
        // Quick Look follows symlinks; skip links that point outside the backup (this Mac's files).
        return items.compactMap(previewURL(for:))
    }

    func quickLookDidMove() {
        guard selection.count <= 1, let url = quickLookURL,
              let item = displayedItems.first(where: { $0.url == url }),
              !selection.contains(item.id) else { return }
        selection = [item.id]
        FinderKeyboard.shared.reveal(item.id)
    }

    // MARK: Pasteboard

    /// Puts the files themselves on the pasteboard: pasting in Finder restores them.
    func copySelectionToPasteboard() {
        guard canAccessFiles else { return }
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
    }

    func copySelectionPaths() {
        guard canAccessFiles else { return }
        let paths = selectedURLs.map(\.path)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    // MARK: Get Info

    /// Get Info on the selection, or on the current folder when nothing is selected (like Finder).
    func showInfo() {
        guard canAccessFiles else { return }
        if let item = selectedItems.first {
            infoItem = item
        } else if let root = snapshotRoot {
            infoItem = FileItem(url: Self.url(root, path), relativePath: path)
        }
    }

    // MARK: Symlinks

    /// Fully resolves a symlink within the backup — following chains of links and links in
    /// intermediate folders — or returns nil if it leads anywhere outside the backup.
    func safeTarget(of item: FileItem) -> [String]? {
        guard let root = snapshotRoot else { return nil }
        var current = item
        for _ in 0..<8 {
            guard let target = Self.linkTarget(of: current, root: root),
                  let resolved = Self.resolve(target, in: root) else { return nil }
            let url = Self.url(root, resolved)
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true else { return resolved }
            current = FileItem(url: url, relativePath: resolved)
        }
        return nil   // too many hops (or a loop)
    }

    // MARK: Go to Folder

    /// Accepts paths as they were on the backed-up Mac (`/Users/me/Documents`, `~/Desktop`) as well as
    /// paths inside the backup (`Data/Users/me`) or relative to the current folder. Case-insensitive,
    /// like Finder. Returns false if nothing matches.
    @discardableResult
    func goToFolder(_ input: String) -> Bool {
        guard let root = snapshotRoot else { return false }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        var candidates: [[String]] = []
        if text.hasPrefix("~") {
            guard let home = homePath else { return false }
            candidates.append(home + Self.components(text.dropFirst()))
        } else if text.hasPrefix("/") {
            let absolute = Self.components(text)
            candidates.append(absolute)
            // On the backed-up Mac, `/Users/…` lived on its Data volume.
            candidates += volumePaths.map { $0 + absolute }
        } else {
            let relative = Self.components(text)
            candidates.append(path + relative)
            candidates.append(relative)
            candidates += volumePaths.map { $0 + relative }
        }

        for candidate in candidates {
            guard let normalized = Self.normalize(candidate),
                  let resolved = Self.resolve(normalized, in: root) else { continue }
            let url = Self.url(root, resolved)
            let values = try? url.resourceValues(forKeys: [.isPackageKey, .isSymbolicLinkKey])
            let isPackage = values?.isPackage ?? false
            let isLink = values?.isSymbolicLink ?? false   // select the link itself; never list through it
            if !isLink && Self.isDirectory(url) && !isPackage {
                navigate(to: resolved)
            } else {
                navigate(to: Array(resolved.dropLast()), select: resolved.joined(separator: "/"))
            }
            return true
        }
        return false
    }

    private static func components<S: StringProtocol>(_ text: S) -> [String] {
        String(text).split(separator: "/").map(String.init).filter { $0 != "." }
    }

    private static func normalize(_ components: [String]) -> [String]? {
        var result: [String] = []
        for component in components {
            if component == ".." {
                guard !result.isEmpty else { return nil }
                result.removeLast()
            } else {
                result.append(component)
            }
        }
        return result
    }

    /// Resolves each component against the folder's actual listing — exact name first, then
    /// case-insensitively — so the result uses the backup's real names. Symlinks are followed only
    /// while they stay inside the backup; a link pointing to this Mac's file system ends the lookup.
    private static func resolve(_ components: [String], in root: URL, hops: Int = 0) -> [String]? {
        let fm = FileManager.default
        var resolved: [String] = []
        for (index, component) in components.enumerated() {
            let parent = url(root, resolved)
            guard let names = try? fm.contentsOfDirectory(atPath: parent.path),
                  let name = names.first(where: { $0 == component })
                    ?? names.first(where: { $0.caseInsensitiveCompare(component) == .orderedSame })
            else { return nil }
            resolved.append(name)

            let itemURL = url(root, resolved)
            let isLink = (try? itemURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
            if isLink && index < components.count - 1 {
                // Continue through the link's target, but only inside the backup.
                guard hops < 8, let target = linkTarget(of: FileItem(url: itemURL, relativePath: resolved), root: root)
                else { return nil }
                return resolve(target + components[(index + 1)...], in: root, hops: hops + 1)
            }
        }
        return resolved
    }
}
