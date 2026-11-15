import SwiftUI

struct ContentView: View {
    @Environment(BrowserModel.self) private var model
    @State private var showTimeline = true

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            DetailView()
                .inspector(isPresented: $showTimeline) {
                    TimelineView()
                        .inspectorColumnWidth(min: 230, ideal: 270, max: 380)
                }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                ControlGroup {
                    Button { model.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                        .disabled(!model.canGoBack)
                        .help("Go back (⌘[)")
                    Button { model.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                        .disabled(!model.canGoForward)
                        .help("Go forward (⌘])")
                }
                .controlGroupStyle(.navigation)
            }
            ToolbarItemGroup(placement: .principal) {
                if model.phase == .ready { SnapshotPicker() }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.toggleQuickLook() } label: { Label("Quick Look", systemImage: "eye") }
                    .disabled(model.selection.isEmpty)
                    .help("Preview the selected items with Quick Look (Space)")
                Button { model.chooseRestoreDestination(for: model.selection) } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward.circle")
                }
                .disabled(model.selection.isEmpty)
                .help("Restore the selected items to a folder of your choice (⇧⌘R)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showTimeline.toggle() } label: { Label("Timeline", systemImage: "sidebar.trailing") }
                    .help(showTimeline ? "Hide the backup timeline" : "Show the backup timeline")
            }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search")
        .sheet(item: $model.passwordRequest) { source in
            PasswordSheet(source: source)
        }
        .sheet(item: $model.infoItem) { item in
            InfoSheet(item: item)
        }
        .sheet(isPresented: $model.isGoToFolderPresented) {
            GoToFolderSheet()
        }
        .onAppear { FinderKeyboard.shared.install(model: model) }
        .alert(
            "TimeFinder",
            isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
            presenting: model.alert
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
    }

    private var title: String {
        guard model.session != nil else { return "TimeFinder" }
        return model.path.last ?? model.machineName
    }

    /// The backup's date lives in the toolbar's picker; the subtitle says whose files these are.
    private var subtitle: String {
        model.path.isEmpty ? "" : model.machineName
    }
}

struct DetailView: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        switch model.phase {
        case .idle where model.idleEjected != nil:
            let source = model.idleEjected!
            ContentUnavailableView {
                Label("“\(source.name)” Was Ejected", systemImage: "eject")
            } description: {
                Text("TimeFinder ejects backups after \(Int(BrowserModel.idleEjectInterval / 60)) minutes in the background, because while a backup is open, \(source.name) can’t back up to it.")
            } actions: {
                Button("Reopen") { model.open(source) }
            }
        case .idle:
            ContentUnavailableView {
                Label("No Backup Open", systemImage: "externaldrive.badge.timemachine")
            } description: {
                Text("Choose a backup in the sidebar, or open a Time Machine backup from any mounted volume.")
            } actions: {
                Button("Open Backup…") { model.chooseBackupToOpen() }
            }
        case .working(let message):
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message) where model.needsFullDiskAccess:
            ContentUnavailableView {
                Label("Full Disk Access Required", systemImage: "lock.shield")
            } description: {
                Text(message)
            } actions: {
                Button("Open Privacy Settings…") { model.openFullDiskAccessSettings() }
                    .buttonStyle(.borderedProminent)
                Button("Try Again") { model.retry() }
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn’t Open Backup", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { model.retry() }
            }
        case .ready:
            VStack(spacing: 0) {
                FileTableView()
                if model.showPathBar {
                    Divider()
                    PathBar()
                }
            }
        }
    }
}

/// Steps through backups like Calendar steps through days: older, a date menu, newer.
struct SnapshotPicker: View {
    @Environment(BrowserModel.self) private var model

    var body: some View {
        Button { model.selectOlderSnapshot() } label: { Label("Older Backup", systemImage: "chevron.backward") }
            .disabled(!model.canGoOlder)
            .help("Go to the previous backup (⌥⌘←)")
        Menu {
            Picker("Backup", selection: Binding(get: { model.currentSnapshotID }, set: { model.selectSnapshot($0) })) {
                ForEach(model.snapshots) { snapshot in
                    Text(snapshot.date.formatted(date: .complete, time: .shortened))
                        .tag(Optional(snapshot.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(model.currentSnapshot?.date.formatted(date: .abbreviated, time: .shortened) ?? "Backups")
                .monospacedDigit()
        }
        .help("Choose a backup to browse")
        Button { model.selectNewerSnapshot() } label: { Label("Newer Backup", systemImage: "chevron.forward") }
            .disabled(!model.canGoNewer)
            .help("Go to the next backup (⌥⌘→)")
    }
}

/// Modeled on the system's "enter a password to unlock the disk" panel.
struct PasswordSheet: View {
    @Environment(BrowserModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let source: BackupSource
    @State private var password = ""

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 56, height: 56)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(.gray.gradient, in: Circle())
                        .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                        .offset(x: 3, y: 3)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text("Enter the password to open the backup “\(source.name)”.")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("This is the password that was chosen when Time Machine was set up to encrypt backups of this Mac.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                    .padding(.top, 4)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Open", action: submit)
                        .keyboardShortcut(.defaultAction)
                        .disabled(password.isEmpty)
                }
                .padding(.top, 8)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func submit() {
        guard !password.isEmpty else { return }
        dismiss()
        model.open(source, password: password)
    }
}
