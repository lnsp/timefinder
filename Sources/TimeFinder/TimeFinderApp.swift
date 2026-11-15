import AppKit
import SwiftUI

@main
struct TimeFinderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = BrowserModel()

    var body: some Scene {
        Window("TimeFinder", id: "main") {
            ContentView()
                .environment(model)
                .onAppear {
                    appDelegate.model = model
                    model.start()
                }
        }
        .defaultSize(width: 1180, height: 720)
        .commands { BrowserCommands(model: model) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: BrowserModel?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Writing a password to a helper that already exited must fail with EPIPE, not kill the app.
        signal(SIGPIPE, SIG_IGN)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.isRestoring {
            let alert = NSAlert()
            alert.messageText = "A restore is still in progress."
            alert.informativeText = "If you quit now, the items being restored won’t be complete."
            alert.addButton(withTitle: "Continue Restoring")
            alert.addButton(withTitle: "Quit Anyway")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        // Unmount snapshots and detach the image so nothing lingers (and the backup's own Mac can
        // back up again) — in the background, with a deadline in case the share is gone.
        model.shutdown { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

/// Menus laid out like Finder's, with Finder's shortcuts wherever the action exists here.
struct BrowserCommands: Commands {
    let model: BrowserModel

    private var hasSelection: Bool { !model.selection.isEmpty && !isShowingSheet }
    private var isReady: Bool { model.phase == .ready && !isShowingSheet }
    /// Menu shortcuts beat a sheet's text field, so navigation is disabled while a sheet is up.
    private var isShowingSheet: Bool {
        model.infoItem != nil || model.isGoToFolderPresented || model.passwordRequest != nil
    }

    var body: some Commands {
        SidebarCommands()
        ToolbarCommands()
        InspectorCommands()

        CommandGroup(replacing: .newItem) {
            Button("Open Backup…") { model.chooseBackupToOpen() }
                .keyboardShortcut("o", modifiers: [.command, .option])
                .disabled(isShowingSheet)
            Button(model.session.map { "Eject “\($0.machineName)”" } ?? "Eject") { model.closeSession() }
                .keyboardShortcut("e")
                .disabled(model.session == nil || isShowingSheet)
            Divider()
            Button("Open") { model.open(model.selection) }
                .keyboardShortcut("o")
                .disabled(!hasSelection)
            Button("Get Info") { model.showInfo() }
                .keyboardShortcut("i")
                .disabled(!isReady)
            Button(quickLookTitle) { model.toggleQuickLook() }
                .keyboardShortcut("y")
                .disabled(!hasSelection)
            Divider()
            Button("Show in Finder") { model.revealInFinder(model.selection) }
                .keyboardShortcut("r")
                .disabled(!hasSelection)
            Button("Restore To…") { model.chooseRestoreDestination(for: model.selection) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!hasSelection)
            Divider()
            Button("Find") { model.focusSearch() }
                .keyboardShortcut("f")
                .disabled(!isReady)
        }

        // Copy puts the *files* on the pasteboard, so ⌘V in Finder restores them. Text fields
        // (search, sheets) keep normal text editing.
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { Self.sendToText(#selector(NSText.cut(_:))) }
                .keyboardShortcut("x")
            Button("Copy") {
                if !Self.sendToText(#selector(NSText.copy(_:))) { model.copySelectionToPasteboard() }
            }
            .keyboardShortcut("c")
            Button("Copy as Pathname") { model.copySelectionPaths() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(!hasSelection)
            Button("Paste") { Self.sendToText(#selector(NSText.paste(_:))) }
                .keyboardShortcut("v")
            Button("Select All") {
                if !Self.sendToText(#selector(NSText.selectAll(_:))) { model.selectAll() }
            }
            .keyboardShortcut("a")
            Button("Deselect All") { model.selection = [] }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(!hasSelection)
        }

        CommandGroup(after: .sidebar) {
            Button(model.showPathBar ? "Hide Path Bar" : "Show Path Bar") { model.showPathBar.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Button(model.showHidden ? "Hide Hidden Files" : "Show Hidden Files") { model.showHidden.toggle() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Divider()
        }

        CommandMenu("Go") {
            Button("Back") { model.goBack() }
                .keyboardShortcut("[")
                .disabled(!model.canGoBack || isShowingSheet)
            Button("Forward") { model.goForward() }
                .keyboardShortcut("]")
                .disabled(!model.canGoForward || isShowingSheet)
            Button("Enclosing Folder") { model.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(model.path.isEmpty || isShowingSheet)
            Divider()
            Group {
                Button(model.machineName.isEmpty ? "Computer" : model.machineName) { model.navigate(to: []) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Home") { model.goHome() }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Desktop") { model.goHome("Desktop") }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Documents") { model.goHome("Documents") }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Downloads") { model.goHome("Downloads") }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                Button("Applications") { model.goToApplications() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
            }
            .disabled(!isReady)
            Divider()
            Button("Go to Folder…") { model.isGoToFolderPresented = true }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!isReady)
            Divider()
            Button("Older Backup") { model.selectOlderSnapshot() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!model.canGoOlder || isShowingSheet)
            Button("Newer Backup") { model.selectNewerSnapshot() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!model.canGoNewer || isShowingSheet)
            Button("Latest Backup") { model.selectSnapshot(model.snapshots.first?.id) }
                .disabled(model.snapshots.isEmpty || isShowingSheet)
            Divider()
            Button("Previous Version of Selection") { model.jumpToVersion(older: true) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option, .shift])
                .disabled(!model.hasOlderVersion || isShowingSheet)
            Button("Next Version of Selection") { model.jumpToVersion(older: false) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option, .shift])
                .disabled(!model.hasNewerVersion || isShowingSheet)
        }
    }

    private var quickLookTitle: String {
        let items = model.selectedItems
        switch items.count {
        case 0: return "Quick Look"
        case 1: return "Quick Look “\(items[0].name)”"
        default: return "Quick Look \(items.count) Items"
        }
    }

    /// Sends a text-editing action to the focused text — a text field, or selectable text such as
    /// Get Info's — and returns false if the focus is the file list (or a sheet without text focus,
    /// where file actions must not apply either).
    @discardableResult
    private static func sendToText(_ action: Selector) -> Bool {
        guard let window = NSApp.keyWindow else { return false }
        let responder = window.firstResponder
        let isText = responder is NSText
            || (responder.map { String(describing: type(of: $0)).contains("Text") } ?? false)
        if isText {
            NSApp.sendAction(action, to: nil, from: nil)
            return true
        }
        return window.sheetParent != nil   // in a sheet: swallow rather than act on the files behind it
    }
}
