import AppKit
import Observation
import SwiftUI

enum Phase: Equatable {
    case idle
    case working(String)
    case ready
    case failed(String)
}

@MainActor @Observable
final class BrowserModel {
    // MARK: Sources

    var sources: [BackupSource] = []
    private(set) var activeSourceID: BackupSource.ID?
    private(set) var phase: Phase = .idle
    var passwordRequest: BackupSource?
    private(set) var needsFullDiskAccess = false
    var alert: String?
    private(set) var busyMessage: String?
    private(set) var isRestoring = false
    /// Set when a backup was ejected automatically after the app sat idle in the background.
    private(set) var idleEjected: BackupSource?

    // MARK: Session

    private(set) var session: BackupSession?
    private(set) var snapshots: [Snapshot] = []
    private(set) var currentSnapshotID: Snapshot.ID?
    private(set) var snapshotRoot: URL?
    private(set) var locations: [Location] = []

    var machineName: String { session?.machineName ?? provisionalMachineName ?? "" }

    // MARK: Cache
    //
    // Snapshot metadata is cached per immutable snapshot identity (see SnapshotCache). While the
    // image is still attaching, the last-known timeline and visited folders are shown
    // *provisionally* — clearly labelled, with every file action disabled — and replaced by live
    // data as soon as the backup is connected.

    @ObservationIgnored private var cache: SnapshotCache?
    private(set) var isProvisional = false
    private(set) var provisionalAsOf: Date?
    private(set) var connectingMessage: String?
    private(set) var listingNote: String?
    @ObservationIgnored private var provisionalMachineName: String?
    @ObservationIgnored private var shouldStoreIndex = false
    /// Sidebar locations came from the cache and haven't been rediscovered on the live backup yet.
    @ObservationIgnored private var locationsAreCached = false
    /// The user picked a backup while browsing the cache (otherwise we land on the live latest).
    @ObservationIgnored private var pickedSnapshotWhileProvisional = false
    /// Placeholder root for cached items; never read (file access is disabled while provisional).
    nonisolated static let placeholderRoot = URL(fileURLWithPath: "/.timefinder-not-connected")
    /// File contents (Quick Look, open, restore, copy, Get Info) need the live backup.
    var canAccessFiles: Bool { session != nil && !isProvisional && snapshotRoot != nil }
    var currentSnapshot: Snapshot? { snapshots.first { $0.id == currentSnapshotID } }
    private var currentIndex: Int? { snapshots.firstIndex { $0.id == currentSnapshotID } }
    var canGoOlder: Bool { currentIndex.map { $0 + 1 < snapshots.count } ?? false }
    var canGoNewer: Bool { (currentIndex ?? 0) > 0 }

    // MARK: Browsing

    private(set) var path: [String] = []
    private(set) var displayedItems: [FileItem] = []
    private var items: [FileItem] = []
    private(set) var isListing = false
    private(set) var listingError: String?
    var selection = Set<FileItem.ID>()
    var sortOrder = [KeyPathComparator(\FileItem.name, comparator: .localizedStandard)] {
        didSet { updateDisplayed() }
    }
    var showHidden = false {
        didSet { reload(); if isSearchActive { scheduleSearch() } }
    }
    var quickLookURL: URL?

    // Finder-style panels and view options
    var infoItem: FileItem?
    var isGoToFolderPresented = false
    var showPathBar = UserDefaults.standard.object(forKey: "showPathBar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showPathBar, forKey: "showPathBar") }
    }

    func focusSearch() { FinderKeyboard.shared.focusSearchField() }
    @ObservationIgnored private var backStack: [[String]] = []
    @ObservationIgnored private var forwardStack: [[String]] = []
    private(set) var canGoBack = false
    private(set) var canGoForward = false

    var selectedItems: [FileItem] { displayedItems.filter { selection.contains($0.id) } }
    var selectedURLs: [URL] { selectedItems.map(\.url) }

    // MARK: Search

    var searchText = "" {
        didSet { if searchText != oldValue { scheduleSearch() } }
    }
    private(set) var searchResults: [FileItem]?
    private(set) var isSearching = false
    var isSearchActive: Bool { searchResults != nil }

    // MARK: Versions of the selected item

    private(set) var versionsFor: [String]?
    private(set) var versionMarks: [Snapshot.ID: VersionMark] = [:]
    private(set) var isScanningVersions = false
    var versionCount: Int { versionMarks.values.filter { $0 == .newVersion }.count }

    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var listTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var versionTask: Task<Void, Never>?
    @ObservationIgnored private var didApplyLaunchSelection = false
    /// Sessions still unmounting in the background; a new open waits for them, so it never
    /// adopts an attachment that's about to be detached.
    @ObservationIgnored private var closingTasks: Set<Task<Void, Never>> = []
    /// Programmatic selection changes (search, folder reloads) shouldn't wipe the version timeline.
    @ObservationIgnored private var preserveVersionsOnDeselect = false

    // MARK: Idle eject
    //
    // While a backup is attached its bundle is locked, so the Mac it belongs to can't back up.
    // When TimeFinder sits in the background for a while, eject so those backups can run.

    static let idleEjectInterval: TimeInterval = 15 * 60
    @ObservationIgnored private var backgroundSince: Date?
    @ObservationIgnored private var idleTimer: Timer?

    // MARK: - Sources

    func start() {
        sources = SourceStore.remembered()
        refreshSources(autoOpen: true)
        startIdleMonitoring()
    }

    private func startIdleMonitoring() {
        guard idleTimer == nil else { return }
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.backgroundSince = Date() }
        }
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.backgroundSince = nil }
        }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { self.ejectIfIdle() }
        }
    }

    private func ejectIfIdle() {
        guard let since = backgroundSince, Date().timeIntervalSince(since) > Self.idleEjectInterval,
              session != nil, !isRestoring,
              let source = sources.first(where: { $0.id == activeSourceID }) else { return }
        closeSession()
        idleEjected = source
    }

    func refreshSources(autoOpen: Bool = false) {
        Task {
            let found = await Task.detached { SourceStore.discover() }.value
            var merged = sources
            for source in found {
                if let index = merged.firstIndex(where: { $0.path == source.path }) {
                    merged[index].modelID = source.modelID ?? merged[index].modelID
                    merged[index].serverURL = source.serverURL ?? merged[index].serverURL
                    merged[index].imageUUID = source.imageUUID ?? merged[index].imageUUID
                } else {
                    merged.append(source)
                }
            }
            sources = merged
            SourceStore.save(merged)

            guard autoOpen, session == nil, phase == .idle else { return }
            let last = UserDefaults.standard.string(forKey: "lastSource")
            if let source = merged.first(where: { $0.path == last }) ?? (merged.count == 1 ? merged.first : nil) {
                open(source)
            }
        }
    }

    func chooseBackupToOpen() {
        let panel = NSOpenPanel()
        panel.title = "Open Time Machine Backup"
        panel.message = "Choose a .sparsebundle or .backupbundle."
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard ["sparsebundle", "backupbundle", "sparseimage", "dmg"].contains(url.pathExtension.lowercased()) else {
            alert = "“\(url.lastPathComponent)” isn't a Time Machine disk image."
            return
        }
        let source = SourceStore.makeSource(at: url)
        if let index = sources.firstIndex(where: { $0.path == source.path }) {
            sources[index] = source
        } else {
            sources.append(source)
        }
        SourceStore.save(sources)
        open(source)
    }

    func removeSource(_ source: BackupSource) {
        if activeSourceID == source.id { guard closeSession() else { return } }
        sources.removeAll { $0.id == source.id }
        SourceStore.save(sources)
    }

    func open(_ source: BackupSource, password: String? = nil) {
        if activeSourceID == source.id, session != nil || phase != .idle, password == nil, !isFailed { return }
        guard closeSession() else { return }
        activeSourceID = source.id
        UserDefaults.standard.set(source.path, forKey: "lastSource")
        needsFullDiskAccess = false
        phase = .working("Opening \(source.name)…")
        cache = SnapshotCache(imageUUID: source.imageUUID)
        if let index = cache?.index(), !index.snapshots.isEmpty, index.bundlePath == source.path {
            enterProvisional(index)
        }

        let previousOpen = openTask   // cancelled, but may still be finishing (and then closing)
        let pendingCloses = closingTasks
        openTask = Task {
            await previousOpen?.value
            for close in pendingCloses { await close.value }
            closingTasks.subtract(pendingCloses)
            // The source's id is its path, which changes if the share comes back elsewhere.
            var currentID = source.id
            guard activeSourceID == currentID, !Task.isCancelled else { return }
            do {
                var resolved = source
                if !resolved.isReachable {
                    guard let server = resolved.serverURL, let host = URL(string: server)?.host else {
                        throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "\(resolved.path) isn't available. Mount the volume it lives on and try again."])
                    }
                    setProgress("Connecting to \(host)…")
                    let mountPoints = try await Task.detached { try SourceStore.connect(server) }.value
                    if !resolved.isReachable, let moved = SourceStore.relocate(resolved, to: mountPoints) {
                        // The share came back under a different name (e.g. /Volumes/backup-1).
                        replaceSource(resolved.id, with: moved)
                        resolved = moved
                        currentID = moved.id
                    }
                    guard resolved.isReachable else {
                        throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Connected to \(host), but \(resolved.path) wasn't found."])
                    }
                }
                let source = resolved
                if cache == nil, SnapshotCache.isEnabled {
                    // First visit, or the share wasn't mounted earlier: learn the image UUID now.
                    let uuid = await Task.detached { SnapshotCache.imageUUID(of: source.url) }.value
                    rememberImageUUID(uuid, for: source.id)
                    cache = SnapshotCache(imageUUID: uuid)
                }
                let opened = try await Task.detached {
                    try BackupSession.open(source, password: password) { message in
                        Task { @MainActor in self.reportProgress(message, for: source.id) }
                    }
                }.value
                guard activeSourceID == currentID, !Task.isCancelled else {
                    await Task.detached { opened.close() }.value
                    return
                }
                install(opened)
            } catch BackupError.needsFullDiskAccess {
                guard activeSourceID == currentID, !Task.isCancelled else { return }
                abandonProvisional()
                needsFullDiskAccess = true
                phase = .failed(BackupError.needsFullDiskAccess.localizedDescription)
            } catch BackupError.needsPassword {
                guard activeSourceID == currentID, !Task.isCancelled else { return }
                abandonProvisional()
                phase = .failed(BackupError.needsPassword.localizedDescription)
                passwordRequest = sources.first { $0.id == activeSourceID } ?? source
            } catch CocoaError.userCancelled {
                guard activeSourceID == currentID, !Task.isCancelled else { return }
                abandonProvisional()
                phase = .idle   // the user cancelled the server login
                activeSourceID = nil
            } catch {
                guard activeSourceID == currentID, !Task.isCancelled else { return }
                abandonProvisional()
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func rememberImageUUID(_ uuid: String?, for id: BackupSource.ID) {
        guard let uuid, let index = sources.firstIndex(where: { $0.id == id }), sources[index].imageUUID != uuid else { return }
        sources[index].imageUUID = uuid
        SourceStore.save(sources)
    }

    private func replaceSource(_ id: BackupSource.ID, with moved: BackupSource) {
        if sources.contains(where: { $0.id == moved.id }) {
            sources.removeAll { $0.id == id }   // already known under the new path
        } else if let index = sources.firstIndex(where: { $0.id == id }) {
            sources[index] = moved
        }
        if activeSourceID == id { activeSourceID = moved.id }
        UserDefaults.standard.set(moved.path, forKey: "lastSource")
        SourceStore.save(sources)
    }

    private func reportProgress(_ message: String, for id: BackupSource.ID) {
        guard activeSourceID == id else { return }
        setProgress(message)
    }

    private func setProgress(_ message: String) {
        if isProvisional {
            connectingMessage = message
        } else if case .working = phase {
            phase = .working(message)
        }
    }

    /// Deletes all cached backup data. The open backup keeps working from live data and starts a
    /// fresh cache (if caching is on).
    func clearCache() {
        cache?.retire()   // in-flight tasks holding it must not write old records back
        cache = nil
        SnapshotCache.clearAll()
        if session != nil, let source = sources.first(where: { $0.id == activeSourceID }) {
            cache = SnapshotCache(imageUUID: source.imageUUID)
            shouldStoreIndex = true
        }
    }

    /// `open TimeFinder.app --args -TFSelect Data/Users/me/file.txt` preselects an item, once.
    private func takeLaunchSelection(into target: inout [String]) -> FileItem.ID? {
        guard !didApplyLaunchSelection, let requested = UserDefaults.standard.string(forKey: "TFSelect") else { return nil }
        didApplyLaunchSelection = true
        target = Array(requested.split(separator: "/").map(String.init).dropLast())
        return requested
    }

    private func enterProvisional(_ index: SnapshotCache.Index) {
        isProvisional = true
        provisionalAsOf = index.verifiedAt
        provisionalMachineName = index.machineName
        connectingMessage = "Connecting…"
        snapshots = index.snapshots.map {
            Snapshot(id: $0.id, date: $0.date, storage: .apfs(device: "", name: $0.id), cacheKey: $0.cacheKey)
        }
        locations = index.locations.map { Location(name: $0.name, symbol: $0.symbol, path: $0.path) }
        locationsAreCached = true
        pickedSnapshotWhileProvisional = false
        currentSnapshotID = snapshots.first?.id
        var target = locations.first(where: { $0.symbol == "house" })?.path ?? []
        let preselect = takeLaunchSelection(into: &target)
        path = target
        phase = .ready
        reload()
        if let preselect {
            selection = [preselect]
            selectionDidChange()
        }
    }

    /// Leaves provisional mode without a session (opening failed): drop the cached view so the
    /// failure is what's shown.
    private func abandonProvisional() {
        guard isProvisional else { return }
        resetBrowsingState()
    }

    private var isFailed: Bool { if case .failed = phase { true } else { false } }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func retry() {
        guard let source = sources.first(where: { $0.id == activeSourceID }) else { return }
        phase = .idle
        open(source)
    }

    private func install(_ session: BackupSession) {
        let wasProvisional = isProvisional
        let provisionalSnapshotID = pickedSnapshotWhileProvisional ? currentSnapshotID : nil
        self.session = session
        idleEjected = nil
        // Still provisional until live data has replaced what's on screen (`didShowLiveListing`):
        // the banner stays and file actions stay off.
        if wasProvisional { connectingMessage = "Loading live data…" }
        infoItem = nil
        quickLookURL = nil
        // The live list is the truth: backups thinned out since last time disappear, new ones appear.
        snapshots = session.snapshots
        cache?.prune(keeping: Set(snapshots.compactMap(\.cacheKey)))
        shouldStoreIndex = true
        phase = .ready
        if wasProvisional, let id = provisionalSnapshotID, snapshots.contains(where: { $0.id == id }) {
            // Keep the user where they are; re-root everything on the live snapshot.
            selectSnapshot(id, force: true, rediscoverLocations: true)
        } else if let newest = snapshots.first {
            selectSnapshot(newest.id, initial: !wasProvisional, force: true, rediscoverLocations: true)
        }
        if let versionsFor { scanVersions(of: versionsFor) }   // include new backups, verify against live data
    }

    /// Closes the open backup (unmounting everything in the background). Refuses while a restore
    /// is copying files out of it; returns false in that case.
    @discardableResult
    func closeSession() -> Bool {
        if isRestoring {
            alert = "Wait until the restore has finished before closing this backup."
            return false
        }
        for task in [openTask, snapshotTask, listTask, searchTask, versionTask] { task?.cancel() }
        if let session {
            clearPasteboardIfPointing(into: session)
            closingTasks.insert(Task.detached { session.close() })
        }
        cache?.flush()
        cache = nil
        idleEjected = nil
        session = nil
        activeSourceID = nil
        phase = .idle
        resetBrowsingState()
        return true
    }

    /// Clears everything shown for a backup (timeline, folder, selection, provisional state).
    private func resetBrowsingState() {
        for task in [snapshotTask, listTask, searchTask, versionTask] { task?.cancel() }
        infoItem = nil
        quickLookURL = nil
        locationsAreCached = false
        isProvisional = false
        provisionalAsOf = nil
        provisionalMachineName = nil
        connectingMessage = nil
        listingNote = nil
        isListing = false
        snapshots = []
        currentSnapshotID = nil
        snapshotRoot = nil
        locations = []
        path = []
        items = []
        searchResults = nil
        isSearching = false
        selection = []
        backStack = []
        forwardStack = []
        updateHistoryFlags()
        clearVersions()
        updateDisplayed()
    }

    /// Cleanup for app termination: closes the open session and waits for any still closing,
    /// in the background, giving up after `deadline` so a dead network share can't block quitting.
    func shutdown(deadline: TimeInterval = 20, completion: @escaping @MainActor () -> Void) {
        let session = self.session
        if let session { clearPasteboardIfPointing(into: session) }
        cache?.flush()
        let pending = closingTasks
        let work = Task.detached {
            session?.close()
            for close in pending { await close.value }
        }
        var finished = false
        let finish = { @MainActor in
            guard !finished else { return }
            finished = true
            completion()
        }
        Task {
            await work.value
            finish()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + deadline) { MainActor.assumeIsolated { finish() } }
    }

    /// Files copied with ⌘C point into our snapshot mounts; once those are unmounted a paste in
    /// Finder would fail with "item can't be found", so clear such a pasteboard.
    private func clearPasteboardIfPointing(into session: BackupSession) {
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        if urls.contains(where: { session.contains($0.path) }) {
            NSPasteboard.general.clearContents()
        }
    }

    // MARK: - Snapshots

    func selectSnapshot(_ id: Snapshot.ID?, initial: Bool = false, force: Bool = false, rediscoverLocations: Bool = false) {
        guard let id, snapshots.contains(where: { $0.id == id }) else { return }
        guard id != currentSnapshotID || initial || force else { return }
        guard let session, let snapshot = snapshots.first(where: { $0.id == id }) else {
            // Provisional: switch the cached view only.
            if isProvisional {
                currentSnapshotID = id
                pickedSnapshotWhileProvisional = true
                reload()
            }
            return
        }
        let previousID = currentSnapshotID
        currentSnapshotID = id
        snapshotTask?.cancel()

        let wanted = path
        let needsLocations = locations.isEmpty || rediscoverLocations || locationsAreCached
        let machineName = session.machineName
        snapshotTask = Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<(URL, [String], [Location]?), Error> in
                Result {
                    let root = try session.root(for: snapshot)
                    // Stay in the same folder; if it didn't exist yet, fall back to the nearest ancestor.
                    var existing = wanted
                    while !existing.isEmpty && !Self.isDirectory(Self.url(root, existing)) {
                        existing.removeLast()
                    }
                    let locations = needsLocations ? Location.discover(in: root, machineName: machineName) : nil
                    return (root, existing, locations)
                }
            }.value
            guard !Task.isCancelled, currentSnapshotID == id else { return }

            switch result {
            case .success(let (root, existing, locations)):
                snapshotRoot = root
                var target = existing
                if path != wanted {
                    // The user navigated while the snapshot was mounting: honour that instead.
                    target = path
                    while !target.isEmpty && !Self.isDirectory(Self.url(root, target)) { target.removeLast() }
                }
                if let locations {
                    self.locations = locations
                    locationsAreCached = false
                    if initial, let home = locations.first(where: { $0.symbol == "house" }) {
                        target = home.path
                    }
                }
                storeIndexIfNeeded()
                let preselect = initial ? takeLaunchSelection(into: &target) : nil
                if target != path { path = target }
                if let preselect {
                    selection = [preselect]
                    selectionDidChange()
                }
                reload()
                if !searchText.isEmpty { scheduleSearch() }
            case .failure(BackupError.closed):
                break
            case .failure(let error):
                // Keep the timeline in sync with what's actually shown.
                currentSnapshotID = previousID
                isListing = false
                if isProvisional {
                    // Never leave cached data on screen as if it were live.
                    isProvisional = false
                    items = []
                    updateDisplayed()
                }
                reload()
                alert = "Couldn’t open the backup from \(snapshot.date.formatted()):\n\(error.localizedDescription)"
            }
        }
    }

    /// Remembers this backup's timeline and locations, to show provisionally next time.
    private func storeIndexIfNeeded() {
        guard shouldStoreIndex, !locationsAreCached, let session, let cache,
              let bundlePath = sources.first(where: { $0.id == activeSourceID })?.path else { return }
        let entries = snapshots.compactMap { snapshot in
            snapshot.cacheKey.map { SnapshotCache.Index.Entry(id: snapshot.id, date: snapshot.date, cacheKey: $0) }
        }
        guard entries.count == snapshots.count else { return }   // only APFS backups are cached
        shouldStoreIndex = false
        cache.storeIndex(SnapshotCache.Index(
            bundlePath: bundlePath,
            machineName: session.machineName,
            verifiedAt: Date(),
            snapshots: entries,
            locations: locations.map { SnapshotCache.CodableLocation(name: $0.name, symbol: $0.symbol, path: $0.path) }
        ))
    }

    func selectOlderSnapshot() {
        guard let index = currentIndex, index + 1 < snapshots.count else { return }
        selectSnapshot(snapshots[index + 1].id)
    }

    func selectNewerSnapshot() {
        guard let index = currentIndex, index > 0 else { return }
        selectSnapshot(snapshots[index - 1].id)
    }

    /// The index of the snapshot where the version visible at `index` first appeared.
    private func versionStart(at index: Int) -> Int? {
        var i = index
        while i < snapshots.count {
            switch versionMarks[snapshots[i].id] {
            case .newVersion: return i
            case .unchanged, .unknown: i += 1
            default: return nil
            }
        }
        return nil
    }

    var hasOlderVersion: Bool { versionTarget(older: true) != nil }
    var hasNewerVersion: Bool { versionTarget(older: false) != nil }

    /// Older: the newest snapshot holding the previous version. Newer: the first snapshot of the next version.
    private func versionTarget(older: Bool) -> Int? {
        guard let index = currentIndex, versionsFor != nil else { return nil }
        if older {
            let start = versionStart(at: index) ?? index
            return snapshots.indices.suffix(from: start + 1).first { i in
                let mark = versionMarks[snapshots[i].id]
                return mark == .newVersion || mark == .unchanged
            }
        }
        return snapshots.indices.prefix(upTo: index).reversed().first { versionMarks[snapshots[$0].id] == .newVersion }
    }

    /// Jumps to the nearest snapshot where the selected item differs from what's shown now.
    func jumpToVersion(older: Bool) {
        if let target = versionTarget(older: older) { selectSnapshot(snapshots[target].id) }
    }

    // MARK: - Navigation

    func navigate(to newPath: [String], select: FileItem.ID? = nil) {
        if isSearchActive { searchText = "" }
        guard newPath != path else {
            if let select { selection = [select] }
            return
        }
        backStack.append(path)
        forwardStack.removeAll()
        setPath(newPath, select: select)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(path)
        setPath(previous, select: path.count > previous.count ? path.prefix(previous.count + 1).joined(separator: "/") : nil)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(path)
        setPath(next)
    }

    func goUp() {
        guard !path.isEmpty else { return }
        let child = path.joined(separator: "/")
        backStack.append(path)
        forwardStack.removeAll()
        setPath(Array(path.dropLast()), select: child)
    }

    private func setPath(_ newPath: [String], select: FileItem.ID? = nil) {
        if isSearchActive { searchText = "" }
        path = newPath
        selection = select.map { [$0] } ?? []
        updateHistoryFlags()
        reload()
    }

    private func updateHistoryFlags() {
        canGoBack = !backStack.isEmpty
        canGoForward = !forwardStack.isEmpty
    }

    func open(_ ids: Set<FileItem.ID>) {
        let targets = displayedItems.filter { ids.contains($0.id) }
        if targets.count == 1, let item = targets.first, item.isFolderLike {
            navigate(to: item.relativePath)
            return
        }
        guard canAccessFiles else { return }
        for item in targets where !item.isFolderLike {
            if item.isSymlink {
                openLink(item)
            } else {
                NSWorkspace.shared.open(item.url)
            }
        }
    }

    /// Follows a symlink only if it points to something inside the same backup. A link like
    /// `~/dotfiles -> /Users/me/dotfiles` would otherwise open *this* Mac's current file.
    private func openLink(_ item: FileItem) {
        guard let root = snapshotRoot, let target = safeTarget(of: item) else {
            let destination = (try? FileManager.default.destinationOfSymbolicLink(atPath: item.url.path)) ?? "?"
            alert = "“\(item.name)” is a link to \(destination), which isn’t part of this backup."
            return
        }
        if Self.isDirectory(Self.url(root, target)) {
            navigate(to: target)
        } else {
            navigate(to: Array(target.dropLast()), select: target.joined(separator: "/"))
        }
    }

    /// The backup-relative path a symlink points to, or nil if it leaves the backup.
    nonisolated static func linkTarget(of item: FileItem, root: URL) -> [String]? {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: item.url.path),
              !destination.hasPrefix("/") else { return nil }   // absolute = this Mac's file system
        var components = Array(item.relativePath.dropLast())
        for part in destination.split(separator: "/").map(String.init) where part != "." {
            if part == ".." {
                guard !components.isEmpty else { return nil }
                components.removeLast()
            } else {
                components.append(part)
            }
        }
        return components
    }

    func showPackageContents(_ item: FileItem) {
        navigate(to: item.relativePath)
    }

    func toggleQuickLook() {
        guard canAccessFiles else { quickLookURL = nil; return }
        quickLookURL = quickLookURL == nil ? selectedItems.first.flatMap(previewURL(for:)) : nil
    }

    /// Quick Look follows symlinks, so only links that stay inside the backup may be previewed.
    func previewURL(for item: FileItem) -> URL? {
        guard item.isSymlink else { return item.url }
        return safeTarget(of: item) != nil ? item.url : nil
    }

    func revealInFinder(_ ids: Set<FileItem.ID>) {
        guard canAccessFiles else { return }
        let urls = displayedItems.filter { ids.contains($0.id) }.map(\.url)
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    // MARK: - Listing

    func reload() {
        listTask?.cancel()
        listingNote = nil
        if isProvisional, snapshotRoot == nil, let snapshot = currentSnapshot {
            showCachedListing(of: snapshot)   // still connecting/mounting: cached, under the banner
            return
        }
        guard snapshotRoot != nil, let session, let snapshot = currentSnapshot else {
            items = []
            updateDisplayed()
            return
        }
        let path = self.path
        let cache = self.cache
        isListing = true
        listTask = Task {
            // Re-resolve the root every time: it remounts the snapshot if its mount disappeared.
            let result = await Task.detached(priority: .userInitiated) { () -> Result<(URL, [FileItem]), Error> in
                Result {
                    let root = try session.root(for: snapshot)
                    // Always the full listing (hidden files filtered below), so one cache entry serves both.
                    let list = try FileItem.list(directory: Self.url(root, path), relativePath: path, showHidden: true)
                    if let cache, let key = snapshot.cacheKey {
                        Self.crossCheck(list, against: cache, key: key, path: path)
                    }
                    return (root, list)
                }
            }.value
            guard !Task.isCancelled, currentSnapshotID == snapshot.id else { return }
            isListing = false
            switch result {
            case .success(let (root, list)):
                if root != snapshotRoot { snapshotRoot = root }
                items = list.filter { showHidden || !$0.isHidden }
                listingError = nil
                if isProvisional { didShowLiveListing() }
            case .failure(let error):
                items = []
                listingError = error.localizedDescription
                if isProvisional { didShowLiveListing() }
            }
            if !isSearchActive {
                let kept = selection.intersection(items.map(\.id))
                if kept != selection {
                    preserveVersionsOnDeselect = true   // e.g. the item doesn't exist in this snapshot
                    selection = kept
                }
            }
            updateDisplayed()
        }
    }

    /// Live data has replaced the cached view: drop the banner and enable file actions.
    private func didShowLiveListing() {
        isProvisional = false
        provisionalAsOf = nil
        provisionalMachineName = nil
        connectingMessage = nil
    }

    private func showCachedListing(of snapshot: Snapshot) {
        isListing = false
        listingError = nil
        if let key = snapshot.cacheKey, let cached = cache?.listing(key, path: path) {
            items = cached
                .map { FileItem(cached: $0, parent: path, root: Self.placeholderRoot) }
                .filter { showHidden || !$0.isHidden }
        } else {
            items = []
            listingNote = "This folder will appear once \(machineName)’s backup is connected."
        }
        let kept = selection.intersection(items.map(\.id))
        if kept != selection {
            preserveVersionsOnDeselect = true
            selection = kept
        }
        updateDisplayed()
    }

    /// Compares a live listing with the cached one and stores it. Snapshots are immutable, so any
    /// difference means the cache is wrong: everything cached for that snapshot is discarded.
    nonisolated private static func crossCheck(_ live: [FileItem], against cache: SnapshotCache, key: String, path: [String]) {
        let liveItems = live.map(SnapshotCache.Item.init).sorted { $0.name < $1.name }
        let cached = cache.listing(key, path: path)?.sorted(by: { $0.name < $1.name })
        if let cached, cached != liveItems {
            Self.log("Cached listing of \(path.joined(separator: "/")) in \(key) didn’t match the backup; discarding that snapshot’s cache.")
            cache.invalidate(key)
        }
        if cached != liveItems { cache.storeListing(liveItems, key, path: path) }
    }

    nonisolated static func log(_ message: String) {
        if Shell.debugLogging { FileHandle.standardError.write(Data("[cache] \(message)\n".utf8)) }
    }

    private func updateDisplayed() {
        displayedItems = (searchResults ?? items).sorted(using: sortOrder)
    }

    // MARK: - Search

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let root = snapshotRoot else {
            if searchResults != nil {
                searchResults = nil
                isSearching = false
                updateDisplayed()
            }
            return
        }
        let base = path
        let showHidden = self.showHidden
        let snapshotID = currentSnapshotID
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, currentSnapshotID == snapshotID else { return }
            defer { if currentSnapshotID != snapshotID { isSearching = false } }
            searchResults = []
            if !selection.isEmpty {
                preserveVersionsOnDeselect = true
                selection = []
            }
            isSearching = true
            updateDisplayed()
            for await batch in Self.search(root: root, base: base, query: query, showHidden: showHidden) {
                guard !Task.isCancelled, currentSnapshotID == snapshotID else { return }
                searchResults?.append(contentsOf: batch)
                updateDisplayed()
            }
            if !Task.isCancelled { isSearching = false }
        }
    }

    nonisolated static let searchLimit = 5000

    /// Recursively searches below `base` for names containing `query`, yielding results in batches.
    nonisolated private static func search(root: URL, base: [String], query: String, showHidden: Bool) -> AsyncStream<[FileItem]> {
        AsyncStream { continuation in
            let worker = Task.detached(priority: .userInitiated) {
                // Breadth-first, so near matches (like Finder's) show up before deep ones.
                let fm = FileManager.default
                let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
                var queue: [[String]] = [base]
                var next = 0
                var batch: [FileItem] = []
                var lastFlush = Date()
                var total = 0
                func flush() {
                    if !batch.isEmpty { continuation.yield(batch) }
                    batch = []
                    lastFlush = Date()
                }
                search: while next < queue.count {
                    let directory = queue[next]
                    next += 1
                    if next >= 4096 {   // don't keep millions of visited folders around
                        queue.removeFirst(next)
                        next = 0
                    }
                    guard let children = try? fm.contentsOfDirectory(at: url(root, directory), includingPropertiesForKeys: FileItem.resourceKeys, options: options) else { continue }
                    for child in children.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                        if Task.isCancelled { break search }
                        let relative = directory + [child.lastPathComponent]
                        let item = FileItem(url: child, relativePath: relative)
                        if item.name.localizedStandardContains(query) {
                            batch.append(item)
                            total += 1
                            if total >= searchLimit { break search }
                        }
                        if item.isFolderLike && !item.isSymlink { queue.append(relative) }
                    }
                    if batch.count >= 100 || (!batch.isEmpty && Date().timeIntervalSince(lastFlush) > 0.25) { flush() }
                }
                flush()
                continuation.finish()
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }

    // MARK: - Versions

    func selectionDidChange() {
        if quickLookURL != nil { quickLookURL = selectedItems.first.flatMap(previewURL(for:)) }
        let preserve = preserveVersionsOnDeselect
        preserveVersionsOnDeselect = false
        guard selection.count == 1, let id = selection.first else {
            if selection.isEmpty && !preserve { clearVersions() }
            return
        }
        // IDs are relative paths, so this works even before the listing has loaded.
        let relativePath = id.split(separator: "/").map(String.init)
        guard relativePath != versionsFor else { return }
        scanVersions(of: relativePath)
    }

    private func clearVersions() {
        versionTask?.cancel()
        versionsFor = nil
        versionMarks = [:]
        isScanningVersions = false
    }

    /// What identifies a version. The inode matters most: Time Machine keeps an unchanged item's
    /// inode from snapshot to snapshot, gives a changed file a new one, and also gives a *folder* a
    /// new one when anything inside it changed — even when the folder's own size and date don't.
    private struct Signature: Equatable {
        let inode: UInt64
        let size: Int64
        let modified: Date?
    }

    private enum Probe: Equatable {
        case present(Signature)
        case missing
        case unreadable   // the snapshot couldn't be mounted or read (or isn't cached yet)

        init(_ cached: SnapshotCache.Probe) {
            switch cached {
            case .present(let inode, let size, let modified): self = .present(Signature(inode: inode, size: size, modified: modified))
            case .missing: self = .missing
            }
        }

        /// The cacheable form; nil for `.unreadable`, which must never be cached.
        var stored: SnapshotCache.Probe? {
            switch self {
            case .present(let s): .present(inode: s.inode, size: s.size, modified: s.modified)
            case .missing: .missing
            case .unreadable: nil
            }
        }
    }

    /// Stats the item in every snapshot (mounting them as needed) and marks where it changed.
    private func scanVersions(of relativePath: [String]) {
        versionTask?.cancel()
        let session = self.session
        let cache = self.cache
        guard session != nil || isProvisional else { return }
        versionsFor = relativePath
        versionMarks = [:]
        isScanningVersions = true
        let oldestFirst = Array(snapshots.reversed())
        versionTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            var previous: Signature?
            var marks: [Snapshot.ID: VersionMark] = [:]
            for snapshot in oldestFirst {
                guard !Task.isCancelled else { return }
                let probe = await Task.detached(priority: .utility) { () -> Probe in
                    Self.probe(relativePath, in: snapshot, session: session, cache: cache)
                }.value
                guard !Task.isCancelled else { return }
                switch probe {
                case .present(let signature):
                    marks[snapshot.id] = signature == previous ? .unchanged : .newVersion
                    previous = signature
                case .missing:
                    marks[snapshot.id] = .absent
                    previous = nil
                case .unreadable:
                    marks[snapshot.id] = .unknown   // keep `previous`: we just don't know about this one
                }
                versionMarks = marks
            }
            isScanningVersions = false
        }
    }

    /// One snapshot's fingerprint of `path`: from the cache when known (no mount needed), else
    /// live — and when the snapshot is mounted anyway, the cached value is verified against it.
    nonisolated private static func probe(_ path: [String], in snapshot: Snapshot, session: BackupSession?, cache: SnapshotCache?) -> Probe {
        let key = snapshot.cacheKey
        let cached = key.flatMap { cache?.probe($0, path: path) }.map(Probe.init)
        if let cached, !(session?.isMounted(snapshot) ?? false) { return cached }
        guard let session else { return cached ?? .unreadable }   // provisional and not cached yet
        let live = liveProbe(path, in: snapshot, session: session)
        if let key, let cache, let stored = live.stored {
            if let cached, cached != live {
                log("Cached fingerprint of \(path.joined(separator: "/")) in \(key) didn’t match the backup; discarding that snapshot’s cache.")
                cache.invalidate(key)
            }
            cache.storeProbe(stored, key, path: path)
        }
        return live
    }

    nonisolated private static func liveProbe(_ path: [String], in snapshot: Snapshot, session: BackupSession) -> Probe {
        guard let root = try? session.root(for: snapshot) else { return .unreadable }
        // lstat: a symlink is compared as a link, not its target. Only "doesn't exist" counts as
        // absent — any other error (I/O over the network, permissions) is unknown and never cached.
        let itemPath = url(root, path).path
        var info = stat()
        guard lstat(itemPath, &info) == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable
        }
        // Values via FileManager (also lstat-based): its Date conversion differs from a hand-made
        // one in the last bit, and fingerprints must compare exactly across runs.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: itemPath) else { return .unreadable }
        return .present(Signature(
            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modified: attributes[.modificationDate] as? Date
        ))
    }

    // MARK: - Restore

    func chooseRestoreDestination(for ids: Set<FileItem.ID>) {
        guard canAccessFiles else { return }
        let targets = displayedItems.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Restore"
        panel.message = targets.count == 1 ? "Choose where to restore “\(targets[0].name)”." : "Choose where to restore \(targets.count) items."
        panel.prompt = "Restore Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        restore(targets, to: destination)
    }

    func restore(_ targets: [FileItem], to destination: URL) {
        guard !isRestoring else { return }
        isRestoring = true
        busyMessage = targets.count == 1 ? "Restoring “\(targets[0].name)”…" : "Restoring \(targets.count) items…"
        Task {
            let (copied, errors) = await Task.detached(priority: .userInitiated) { () -> ([URL], [String]) in
                let fm = FileManager.default
                var copied: [URL] = []
                var errors: [String] = []
                for item in targets {
                    // Copy into a hidden staging folder and move into place at the end, so a failed
                    // or interrupted copy never looks like a finished restore.
                    let staging = destination.appendingPathComponent(".timefinder-partial-\(UUID().uuidString)", isDirectory: true)
                    let partial = staging.appendingPathComponent(item.name)
                    do {
                        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
                        try fm.copyItem(at: item.url, to: partial)
                        Self.removeACLs(in: partial)
                        // Pick the final name only now; if something took it meanwhile, pick again.
                        var final = Self.uniqueURL(destination.appendingPathComponent(item.name))
                        do {
                            try fm.moveItem(at: partial, to: final)
                        } catch CocoaError.fileWriteFileExists {
                            final = Self.uniqueURL(destination.appendingPathComponent(item.name))
                            try fm.moveItem(at: partial, to: final)
                        }
                        copied.append(final)
                    } catch {
                        errors.append("\(item.name): \(error.localizedDescription)")
                    }
                    // Our own staging folder (UUID-named) — empty unless the copy failed.
                    try? fm.removeItem(at: staging)
                }
                return (copied, errors)
            }.value
            isRestoring = false
            busyMessage = nil
            if !copied.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(copied) }
            if !errors.isEmpty { alert = "Some items couldn’t be restored:\n" + errors.joined(separator: "\n") }
        }
    }

    // MARK: - Helpers

    nonisolated static func url(_ root: URL, _ components: [String]) -> URL {
        components.reduce(root) { $0.appendingPathComponent($1) }
    }

    nonisolated static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// `Report.pdf` → `Report 2.pdf` if taken, like Finder.
    /// Removes ACLs (home folders carry "everyone deny delete") from a restored copy.
    /// Never follows symlinks: `chmod -R -N` would, and could strip ACLs from this Mac's own files
    /// that a restored link points to. `find -P` doesn't follow links and `! -type l` skips them.
    nonisolated static func removeACLs(in url: URL) {
        _ = try? Shell.run("/usr/bin/find", ["-P", url.path, "!", "-type", "l", "-exec", "/bin/chmod", "-N", "{}", "+"], timeout: 3600)
    }

    nonisolated static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        // attributesOfItem doesn't follow symlinks, so a broken link with the same name counts as taken.
        func taken(_ url: URL) -> Bool { (try? fm.attributesOfItem(atPath: url.path)) != nil }
        guard taken(url) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let dir = url.deletingLastPathComponent()
        for n in 2... {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !taken(candidate) { return candidate }
        }
        return url
    }
}
