import AppKit
import Quartz

/// Finder's keyboard and mouse conventions for the file list, handled at the window level so
/// SwiftUI's Table can't swallow them:
///
/// - Space: Quick Look (or part of a type-select string while typing quickly)
/// - Tab / ⇧Tab: select the next / previous item alphabetically
/// - Typing a name: type-select
/// - ⌘↓: open · Esc: close Quick Look
/// - Mouse buttons 4 / 5: back / forward
///
/// Keys only apply while the file list has focus, and never while typing in a text field.
@MainActor
final class FinderKeyboard {
    static let shared = FinderKeyboard()

    private weak var model: BrowserModel?
    private var monitor: Any?
    private weak var cachedTable: NSTableView?
    private var typeSelectBuffer = ""
    private var lastTypeSelect = Date.distantPast
    private static let typeSelectTimeout: TimeInterval = 1.0

    private enum Key {
        static let tab: UInt16 = 48
        static let space: UInt16 = 49
        static let escape: UInt16 = 53
        static let downArrow: UInt16 = 125
        static let upArrow: UInt16 = 126
    }

    func install(model: BrowserModel) {
        self.model = model
        guard monitor == nil else { return }
        // Like Finder, the file list gets focus when the window becomes key (unless something else has it).
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { notification in
            MainActor.assumeIsolated {
                guard let window = notification.object as? NSWindow, !(window is NSPanel),
                      window.firstResponder === window else { return }
                FinderKeyboard.shared.focusFileList()
            }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown]) { event in
            // Local monitors run on the main thread.
            let consumed = MainActor.assumeIsolated { FinderKeyboard.shared.handle(event) }
            return consumed ? nil : event
        }
    }

    /// Moves keyboard focus to the file list, like Finder does after navigating —
    /// unless the user is typing in a text field.
    func focusFileList(attempts: Int = 5) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self,
                  let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }),
                  window.attachedSheet == nil,
                  !(window.firstResponder is NSText) else { return }
            guard let table = self.fileTable(in: window) else {
                // The table may not be in the window yet right after a view change.
                if attempts > 1 { self.focusFileList(attempts: attempts - 1) }
                return
            }
            if window.firstResponder !== table { window.makeFirstResponder(table) }
        }
    }

    // MARK: - Events

    private func handle(_ event: NSEvent) -> Bool {
        guard let model, let window = event.window else { return false }

        // While Quick Look is open, ↑/↓ move the list's selection and the preview follows (Finder).
        if window is QLPreviewPanel {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
            guard flags.isEmpty, event.keyCode == Key.upArrow || event.keyCode == Key.downArrow,
                  let id = model.adjacentDisplayedID(forward: event.keyCode == Key.downArrow) else { return false }
            model.selection = [id]
            reveal(id)
            return true
        }

        // Not while a sheet (Get Info, Go to Folder, password) is up, nor inside one.
        guard window.attachedSheet == nil, window.sheetParent == nil, !(window is NSPanel) else { return false }

        if event.type == .otherMouseDown {
            switch event.buttonNumber {
            case 3: model.goBack(); return true
            case 4: model.goForward(); return true
            default: return false
            }
        }

        // The list counts as focused when it has focus, or when nothing does (Finder behaves the same).
        let responder = window.firstResponder
        guard model.phase == .ready,
              !(responder is NSText),
              let table = fileTable(in: window),
              responder === table || responder === window || responder == nil else { return false }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        let isTypingName = !typeSelectBuffer.isEmpty && Date().timeIntervalSince(lastTypeSelect) < Self.typeSelectTimeout

        let claimFocus = { if window.firstResponder !== table { window.makeFirstResponder(table) } }

        switch event.keyCode {
        case Key.space where flags.isEmpty && !isTypingName && !event.isARepeat:
            model.toggleQuickLook()
            return true
        case Key.tab where flags.isEmpty || flags == .shift:
            claimFocus()
            select(model.adjacentItemID(forward: flags.isEmpty), in: table)
            return true
        case Key.downArrow where flags == .command:
            model.open(model.selection)
            return true
        case Key.escape where flags.isEmpty && model.quickLookURL != nil:
            model.quickLookURL = nil
            return true
        default:
            guard typeSelect(event, flags: flags, in: table) else { return false }
            claimFocus()
            return true
        }
    }

    private func typeSelect(_ event: NSEvent, flags: NSEvent.ModifierFlags, in table: NSTableView) -> Bool {
        guard flags.isEmpty || flags == .shift,
              let characters = event.characters, !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 })
        else { return false }

        let now = Date()
        if now.timeIntervalSince(lastTypeSelect) > Self.typeSelectTimeout { typeSelectBuffer = "" }
        typeSelectBuffer += characters
        lastTypeSelect = now
        select(model?.typeSelectMatch(typeSelectBuffer), in: table)
        return true
    }

    private func select(_ id: FileItem.ID?, in table: NSTableView) {
        guard let model, let id else { return }
        model.selection = [id]
        if let row = model.displayedItems.firstIndex(where: { $0.id == id }) {
            // Let SwiftUI push the selection into the table first.
            DispatchQueue.main.async { table.scrollRowToVisible(row) }
        }
    }

    /// ⌘F: focuses the toolbar search field.
    func focusSearchField() {
        guard let window = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) && $0.toolbar != nil }),
              let item = window.toolbar?.items.lazy.compactMap({ $0 as? NSSearchToolbarItem }).first else { return }
        window.makeKeyAndOrderFront(nil)
        item.beginSearchInteraction()
    }

    /// Scrolls the file list to show an item (e.g. after Quick Look moved the selection).
    func reveal(_ id: FileItem.ID) {
        guard let model, let row = model.displayedItems.firstIndex(where: { $0.id == id }),
              let window = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }),
              let table = fileTable(in: window) else { return }
        DispatchQueue.main.async { table.scrollRowToVisible(row) }
    }

    // MARK: - Finding the file list

    /// The file list is the window's only multi-column table (the sidebar is a single-column list).
    private func fileTable(in window: NSWindow) -> NSTableView? {
        if let cachedTable, cachedTable.window === window { return cachedTable }
        guard let contentView = window.contentView else { return nil }
        cachedTable = Self.findTable(in: contentView)
        return cachedTable
    }

    private static func findTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView, table.numberOfColumns > 1 { return table }
        for subview in view.subviews {
            if let table = findTable(in: subview) { return table }
        }
        return nil
    }
}
