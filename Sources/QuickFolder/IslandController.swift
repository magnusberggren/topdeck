import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Owns the island window and decides when it opens, peeks and closes.
final class IslandController: NSObject, IslandActions {
    let model: IslandModel

    private let panel = IslandPanel()
    /// One watcher per folder, keyed by path, so every page stays live.
    private var monitors: [String: DownloadsMonitor] = [:]
    private var eventMonitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    private var expandTimer: Timer?
    private var collapseTimer: Timer?
    private var peekTimer: Timer?

    private var isMenuOpen = false
    /// The pointer is on a download preview, so it stays up until it leaves.
    private var isHoldingPeek = false
    /// After the island closes because of a click, the pointer must leave the
    /// notch before hovering opens it again.
    private var waitsForPointerToLeave = false

    private var rawScrollOffset: CGFloat = 0
    private var ignoresMomentum = false

    // One trackpad gesture moves either the shelf or the page, never both.
    private enum ScrollAxis { case horizontal, vertical }
    private var scrollAxis: ScrollAxis?
    private var axisProbe = CGSize.zero
    private var rawPagePull: CGFloat = 0
    private var gestureSwitchedPage = false
    private var gestureHitEdge = false

    private var wheelPull: CGFloat = 0
    private var lastWheelTime: TimeInterval = 0
    private var wheelLockedUntil: TimeInterval = 0
    private var wheelRelease: DispatchWorkItem?

    private var collapsedAt = Date.distantPast
    private var openWithMenu: OpenWithMenu?

    /// While QuickFolder itself is adding files (extracting, installing),
    /// they shouldn't pop up as new downloads.
    private var runningTasks = 0
    private var quietUntil = Date.distantPast

    private let progressWatcher = DownloadProgressWatcher()
    /// Partial files seen in each folder, by folder path.
    private var partials: [String: [String]] = [:]
    private var reportedDownloads: [ReportedDownload] = []
    /// Extractions and installs QuickFolder is running.
    private var tasks: [Activity] = []

    private let deckEditor = DeckEditor()
    private let deckSync = DeckSync()
    private let calendar = CalendarStore()
    private var toastTimer: Timer?
    private var cleanupConfirmTimer: Timer?

    #if DEBUG
    private var pinnedState: IslandState?
    #endif

    private enum Timing {
        static let hoverDelay: TimeInterval = 0.09
        static let peekHoverDelay: TimeInterval = 0.03
        static let leaveDelay: TimeInterval = 0.12
        static let peekDuration: TimeInterval = 4.2
        /// How long a preview stays after the pointer moves off it.
        static let peekLinger: TimeInterval = 1.2
        /// Reopening after this long starts back on the first folder.
        static let pageMemory: TimeInterval = 30
    }

    private enum Paging {
        /// Finger travel needed to switch folders. Until then the shelf
        /// resists and springs back, so a sloppy swipe doesn't switch.
        static let threshold: CGFloat = 64
        /// Mouse wheel lines needed to switch folders.
        static let wheelThreshold: CGFloat = 3
    }

    override init() {
        model = IslandModel(metrics: IslandMetrics(screen: IslandMetrics.preferredScreen()) ?? .fallback)
        super.init()
        model.actions = self
    }

    func start() {
        let hosting = IslandHostingView(rootView: IslandView(model: model))
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        updateScreen()
        panel.orderFrontRegardless()

        model.deckKeys = DeckStore.load()
        deckSync.onRemoteChange = { [weak self] keys in
            guard let self, keys != self.model.deckKeys else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { self.model.deckKeys = keys }
            DeckStore.save(keys)
        }
        if Preferences.syncsShortcuts { startDeckSync() }

        model.calendarAccess = calendar.access
        calendar.onAccessChange = { [weak self] access in
            self?.model.calendarAccess = access
            // QuickFolder came forward for the permission prompt; hand focus back.
            if NSApp.isActive && NSApp.keyWindow == nil && NSApp.modalWindow == nil { NSApp.deactivate() }
        }
        calendar.onChange = { [weak self] meetings in
            guard let self, meetings != self.model.meetings else { return }
            let isVisible = self.model.state == .expanded && self.model.currentPage?.kind == .meetings
            withAnimation(isVisible ? .spring(response: 0.42, dampingFraction: 0.84) : nil) {
                self.model.meetings = meetings
            }
        }
        calendar.refresh()
        progressWatcher.onChange = { [weak self] downloads in
            self?.reportedDownloads = downloads
            self?.rebuildActivities()
        }
        reloadFolders()

        installEventMonitors()
        installObservers()
        installDragHandlers()

        #if DEBUG
        applyDebugState()
        #endif
    }

    func showWelcomeHint() {
        let place = model.metrics.hasNotch ? "the notch" : "the top of the screen"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.showPeek(.message(
                title: "QuickFolder is ready",
                subtitle: "Point at \(place) to see your downloads",
                symbol: "tray.and.arrow.down.fill"
            ), duration: 5)
        }
    }

    // MARK: - Folders

    /// Syncs pages and watchers with `Preferences.folders`.
    private func reloadFolders() {
        let urls = Preferences.folders
        let paths = Set(urls.map(\.path))
        let currentID = model.currentPage?.id

        for (path, monitor) in monitors where !paths.contains(path) {
            monitor.stop()
            monitors[path] = nil
            partials[path] = nil
        }

        var pages = urls.map { url in
            model.pages.first { $0.id == url.path }
                ?? FolderPage(url: url, name: FileManager.default.displayName(atPath: url.path))
        }
        if Preferences.showsShortcutsPage { pages.append(.shortcuts) }
        if Preferences.showsMeetingsPage { pages.append(.meetings) }
        // The user's arrangement first; anything new keeps its natural place after.
        let order = Preferences.pageOrder
        pages = pages.enumerated()
            .sorted { lhs, rhs in
                let left = order.firstIndex(of: lhs.element.id) ?? order.count + lhs.offset
                let right = order.firstIndex(of: rhs.element.id) ?? order.count + rhs.offset
                return left < right
            }
            .map(\.element)
        model.pages = pages
        model.pageIndex = model.pages.firstIndex { $0.id == currentID } ?? min(model.pageIndex, max(0, model.pages.count - 1))

        for url in urls where monitors[url.path] == nil {
            let id = url.path
            let monitor = DownloadsMonitor(folder: url)
            monitor.onChange = { [weak self] scan in self?.apply(scan, to: id) }
            monitor.onNewDownload = { [weak self] item in self?.announce(item, in: id) }
            monitors[id] = monitor
            monitor.start()
        }
        progressWatcher.watch(urls)
        rebuildActivities()
    }

    private func apply(_ scan: FolderScan, to pageID: String) {
        guard let index = model.pages.firstIndex(where: { $0.id == pageID }) else { return }
        let isVisible = model.state == .expanded && index == model.pageIndex
        withAnimation(isVisible ? .spring(response: 0.42, dampingFraction: 0.84) : nil) {
            model.pages[index].items = scan.items
            model.pages[index].access = scan.access
            model.pages[index].cleanup = scan.cleanup
            if isVisible && model.scrollOffset > model.maxScrollOffset {
                model.scrollOffset = model.maxScrollOffset
                rawScrollOffset = model.scrollOffset
            }
        }
        model.thumbnails.sync(with: model.pages.flatMap(\.items))
        if partials[pageID] != scan.partials {
            partials[pageID] = scan.partials
            rebuildActivities()
        }
    }

    // MARK: - Activity

    /// Merges what browsers report with the partial files on disk (for apps
    /// that don't report progress) and QuickFolder's own tasks.
    private func rebuildActivities() {
        var downloads: [String: Activity] = [:]
        for (folder, names) in partials {
            for name in names {
                let id = folder + "/" + name
                downloads[id] = Activity(id: id, name: name, fraction: nil, kind: .download, folderPath: folder)
            }
        }
        for report in reportedDownloads where monitors[report.folderPath] != nil {
            let id = report.folderPath + "/" + report.name
            downloads[id] = Activity(id: id, name: report.name, fraction: report.fraction, kind: .download, folderPath: report.folderPath)
        }

        let activities = downloads.values.sorted { $0.id < $1.id } + tasks
        guard activities != model.activities else { return }

        let isVisible = model.state == .expanded
        withAnimation(isVisible ? .spring(response: 0.42, dampingFraction: 0.84) : nil) {
            model.activities = activities
        }
        if model.state == .collapsed || model.state == .activity {
            setState(restState)
        }
    }

    /// Where the island settles when nothing is being looked at.
    private var restState: IslandState {
        model.activities.isEmpty ? .collapsed : .activity
    }

    private func announce(_ item: DownloadItem, in pageID: String) {
        guard Preferences.showsNewDownloadPreview, model.state != .expanded, !model.isDraggingFile,
              runningTasks == 0, Date() > quietUntil,
              let page = model.pages.first(where: { $0.id == pageID }) else { return }
        let label = page.isDownloads ? "Downloaded" : "Added to \(page.name)"
        showPeek(.download(item, pageID: pageID, label: label), duration: Timing.peekDuration)
    }

    func perform(_ action: SmartAction, on item: DownloadItem) {
        guard !model.busyItems.contains(item.id) else { return }
        model.busyItems.insert(item.id)
        runningTasks += 1
        let task = Activity(
            id: "task:" + item.id,
            name: item.name,
            fraction: nil,
            kind: action == .extract ? .extract : .install,
            folderPath: item.url.deletingLastPathComponent().path
        )
        tasks.append(task)
        rebuildActivities()

        let finish = { [weak self] in
            guard let self else { return }
            self.runningTasks -= 1
            self.quietUntil = Date().addingTimeInterval(2)
            self.model.busyItems.remove(item.id)
            self.tasks.removeAll { $0.id == task.id }
            self.rebuildActivities()
        }

        switch action {
        case .extract:
            Archive.extractAndTrash(item.url) { [weak self] result in
                finish()
                guard let self else { return }
                switch result {
                case .success(let url):
                    FileActions.playTrashSound()
                    Haptics.perform(.levelChange)
                    self.highlight(url)
                    self.announceResult(url, label: "Extracted")
                case .failure:
                    self.note("Couldn’t extract", on: item)
                }
            }

        case .install:
            DiskImageInstaller.install(item.url) { [weak self] result in
                finish()
                guard let self else { return }
                switch result {
                case .success(.installed(let app)):
                    FileActions.playTrashSound()
                    Haptics.perform(.levelChange)
                    let name = FileManager.default.displayName(atPath: app.path)
                    if self.model.state == .expanded {
                        self.showToast(Toast(symbol: "checkmark.circle.fill", text: "Installed \(name)", url: app))
                    } else {
                        self.showPeek(.download(DownloadItem(url: app), pageID: "", label: "Installed"), duration: Timing.peekDuration)
                    }
                case .success(.handedOff):
                    self.collapse(waitForPointerToLeave: true)
                case .failure(.appRunning(let name)):
                    self.note("Quit \(name) first", on: item)
                case .failure(.needsAppManagement):
                    self.note("Needs permission", on: item)
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles") {
                        NSWorkspace.shared.open(url)
                    }
                case .failure:
                    self.note("Couldn’t install", on: item)
                }
            }
        }
    }

    private func highlight(_ url: URL) {
        withAnimation(.smooth(duration: 0.3)) { model.highlightedID = url.path }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self, self.model.highlightedID == url.path else { return }
            withAnimation(.smooth(duration: 0.6)) { self.model.highlightedID = nil }
        }
    }

    /// Finished after the island closed: say so from the notch.
    private func announceResult(_ url: URL, label: String) {
        guard model.state != .expanded else { return }
        let folder = url.deletingLastPathComponent().path
        let pageID = model.pages.first { $0.kind == .folder && $0.url.path == folder }?.id ?? folder
        showPeek(.download(DownloadItem(url: url), pageID: pageID, label: label), duration: Timing.peekDuration)
    }

    private func note(_ text: String, on item: DownloadItem) {
        NSSound.beep()
        model.tileNotes[item.id] = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.model.tileNotes[item.id] = nil
        }
    }

    private func showToast(_ toast: Toast) {
        toastTimer?.invalidate()
        model.toast = toast
        toastTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            self?.model.toast = nil
        }
    }

    func openToast() {
        guard let url = model.toast?.url else { return }
        collapse(waitForPointerToLeave: true)
        NSWorkspace.shared.open(url)
    }

    // MARK: - Arranging rows

    func setArranging(_ arranging: Bool) {
        guard model.isArranging != arranging else { return }
        if arranging {
            Haptics.perform(.levelChange)
        } else {
            Preferences.pageOrder = model.pages.map(\.id)
        }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            model.isArranging = arranging
            model.draggingPageID = nil
            model.dragOffset = 0
            model.pagePull = 0
            model.scrollOffset = 0
        }
        rawScrollOffset = 0
    }

    /// Reordering: the dragged row follows the pointer and the others slide
    /// aside as it passes their middle. The list only changes on drop.
    func dragRow(_ id: String, phase: PanPhase, translation: CGFloat) {
        guard let start = model.pages.firstIndex(where: { $0.id == id }) else { return }
        let step = model.metrics.arrangeRowHeight(count: model.pages.count) + IslandMetrics.arrangeRowSpacing
        let target = min(max(start + Int((translation / step).rounded()), 0), model.pages.count - 1)

        var still = Transaction()
        still.disablesAnimations = true

        switch phase {
        case .began:
            Haptics.perform(.alignment)
            withTransaction(still) {
                model.dragTargetIndex = start
                model.dragOffset = 0
            }
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { model.draggingPageID = id }

        case .changed:
            withTransaction(still) { model.dragOffset = translation }
            if target != model.dragTargetIndex {
                Haptics.perform(.alignment)
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { model.dragTargetIndex = target }
            }

        case .ended:
            // Glide into the slot, then commit the order. At that moment every
            // row is already drawn where the new order puts it, so nothing jumps.
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                model.dragOffset = CGFloat(target - start) * step
            } completion: { [weak self] in
                guard let self else { return }
                let currentID = self.model.currentPage?.id
                withTransaction(still) {
                    let page = self.model.pages.remove(at: start)
                    self.model.pages.insert(page, at: target)
                    self.model.pageIndex = self.model.pages.firstIndex { $0.id == currentID } ?? 0
                    self.model.draggingPageID = nil
                    self.model.dragOffset = 0
                    self.model.dragTargetIndex = target
                }
                Preferences.pageOrder = self.model.pages.map(\.id)
            }
        }
    }

    // MARK: - Cleanup

    func cleanUp() {
        guard let page = model.currentPage, let cleanup = page.cleanup else { return }
        guard model.isConfirmingCleanup else {
            Haptics.perform(.alignment)
            model.isConfirmingCleanup = true
            cleanupConfirmTimer?.invalidate()
            cleanupConfirmTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
                self?.model.isConfirmingCleanup = false
            }
            return
        }

        cleanupConfirmTimer?.invalidate()
        model.isConfirmingCleanup = false
        let size = ByteCountFormatter.string(fromByteCount: cleanup.bytes, countStyle: .file)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            if let index = model.pages.firstIndex(where: { $0.id == page.id }) { model.pages[index].cleanup = nil }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            NSWorkspace.shared.recycle(cleanup.files) { _, _ in
                DispatchQueue.main.async { [weak self] in
                    FileActions.playTrashSound()
                    Haptics.perform(.levelChange)
                    self?.showToast(Toast(symbol: "sparkles", text: "Freed \(size)", url: nil))
                }
            }
        }
    }

    // MARK: - Shortcuts deck

    func run(_ key: DeckKey) {
        Haptics.perform(.generic)
        DeckRunner.run(key) { [weak self] result in
            guard let self else { return }
            let succeeded: Bool
            switch result {
            case .success:
                succeeded = true
            case .failure(.needsAccessibility):
                // macOS only shows its own prompt the first time, so always
                // say what's missing and link straight to the setting.
                Haptics.perform(.generic)
                self.showToast(Toast(
                    symbol: "lock.fill",
                    text: "Allow Accessibility to paste",
                    url: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
                    isWarning: true
                ))
                return
            case .failure:
                succeeded = false
                NSSound.beep()
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { self.model.deckResults[key.id] = succeeded }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                withAnimation(.smooth(duration: 0.3)) { self.model.deckResults[key.id] = nil }
            }
        }
    }

    func editKey(_ key: DeckKey?) {
        collapse(waitForPointerToLeave: true)
        deckEditor.show(key, onSave: { [weak self] saved in
            guard let self else { return }
            if let index = self.model.deckKeys.firstIndex(where: { $0.id == saved.id }) {
                self.model.deckKeys[index] = saved
            } else {
                self.model.deckKeys.append(saved)
            }
            self.saveDeck()
        }, onDelete: { [weak self] deleted in
            self?.deleteKey(deleted.id)
        })
    }

    private func saveDeck() {
        DeckStore.save(model.deckKeys)
        if Preferences.syncsShortcuts { deckSync.save(model.deckKeys) }
    }

    private func startDeckSync() {
        deckSync.start(local: model.deckKeys, hasLocalKeys: DeckStore.hasSavedKeys)
    }

    // MARK: - Meetings

    func join(_ meeting: Meeting, as account: String?) {
        Haptics.perform(.generic)
        collapse(waitForPointerToLeave: true)
        NSWorkspace.shared.open(meeting.joinURL(as: account))
    }

    func requestCalendarAccess() {
        if calendar.access == .notDetermined {
            NSApp.activate()
            calendar.requestAccess()
        } else {
            collapse(waitForPointerToLeave: true)
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func openCalendar() {
        collapse(waitForPointerToLeave: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
    }

    func showMenu(for meeting: Meeting) {
        let menu = NSMenu()
        let join = menuItem(
            meeting.account.map { "Join as \($0)" } ?? "Join",
            symbol: "video",
            action: #selector(menuJoin(_:))
        )
        join.representedObject = MeetingChoice(meeting: meeting, account: meeting.account)
        menu.addItem(join)

        if meeting.service == .meet {
            let others = meeting.accounts.filter { $0 != meeting.account }
            let joinAs = NSMenuItem(title: "Join As", action: nil, keyEquivalent: "")
            joinAs.image = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil)
            let submenu = NSMenu()
            for account in others {
                let item = menuItem(account, action: #selector(menuJoin(_:)))
                item.representedObject = MeetingChoice(meeting: meeting, account: account)
                submenu.addItem(item)
            }
            if !others.isEmpty { submenu.addItem(.separator()) }
            let fallback = menuItem("Browser’s Default Account", action: #selector(menuJoin(_:)))
            fallback.representedObject = MeetingChoice(meeting: meeting, account: nil)
            submenu.addItem(fallback)
            joinAs.submenu = submenu
            menu.addItem(joinAs)
        }

        menu.addItem(.separator())
        let copy = menuItem("Copy Link", symbol: "link", action: #selector(menuCopyMeetingLink(_:)))
        copy.representedObject = MeetingChoice(meeting: meeting, account: meeting.account)
        menu.addItem(copy)
        let show = menuItem("Show in Calendar", symbol: "calendar", action: #selector(menuShowMeeting(_:)))
        show.representedObject = MeetingChoice(meeting: meeting, account: meeting.account)
        menu.addItem(show)
        present(menu)
    }

    @objc private func menuJoin(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? MeetingChoice else { return }
        join(choice.meeting, as: choice.account)
    }

    @objc private func menuCopyMeetingLink(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? MeetingChoice else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(choice.meeting.joinURL(as: choice.account).absoluteString, forType: .string)
    }

    @objc private func menuShowMeeting(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? MeetingChoice else { return }
        collapse(waitForPointerToLeave: true)
        let id = choice.meeting.eventIdentifier?.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        if let id, let url = URL(string: "ical://ekevent/\(id)?method=show&options=more"),
           NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else {
            openCalendar()
        }
    }

    private func deleteKey(_ id: UUID) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            model.deckKeys.removeAll { $0.id == id }
        }
        saveDeck()
    }

    private func moveKey(_ id: UUID, by offset: Int) {
        guard let index = model.deckKeys.firstIndex(where: { $0.id == id }),
              model.deckKeys.indices.contains(index + offset) else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            model.deckKeys.swapAt(index, index + offset)
        }
        saveDeck()
    }

    func showMenu(for key: DeckKey) {
        let menu = NSMenu()
        let index = model.deckKeys.firstIndex { $0.id == key.id } ?? 0
        func add(_ title: String, _ symbol: String, enabled: Bool = true, _ action: Selector) {
            let item = menuItem(title, symbol: symbol, action: action)
            item.representedObject = key.id
            item.isEnabled = enabled
            menu.addItem(item)
        }
        add("Edit…", "pencil", #selector(menuEditKey(_:)))
        add("Duplicate", "plus.square.on.square", #selector(menuDuplicateKey(_:)))
        menu.addItem(.separator())
        add("Move Left", "arrow.left", enabled: index > 0, #selector(menuMoveKeyLeft(_:)))
        add("Move Right", "arrow.right", enabled: index < model.deckKeys.count - 1, #selector(menuMoveKeyRight(_:)))
        menu.addItem(.separator())
        add("Delete", "trash", #selector(menuDeleteKey(_:)))
        menu.autoenablesItems = false
        present(menu)
    }

    private func key(from sender: NSMenuItem) -> DeckKey? {
        guard let id = sender.representedObject as? UUID else { return nil }
        return model.deckKeys.first { $0.id == id }
    }

    @objc private func menuEditKey(_ sender: NSMenuItem) {
        guard let key = key(from: sender) else { return }
        editKey(key)
    }

    @objc private func menuDuplicateKey(_ sender: NSMenuItem) {
        guard let key = key(from: sender), let index = model.deckKeys.firstIndex(of: key) else { return }
        var copy = key
        copy.id = UUID()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            model.deckKeys.insert(copy, at: index + 1)
        }
        saveDeck()
    }

    @objc private func menuMoveKeyLeft(_ sender: NSMenuItem) {
        if let key = key(from: sender) { moveKey(key.id, by: -1) }
    }

    @objc private func menuMoveKeyRight(_ sender: NSMenuItem) {
        if let key = key(from: sender) { moveKey(key.id, by: 1) }
    }

    @objc private func menuDeleteKey(_ sender: NSMenuItem) {
        if let key = key(from: sender) { deleteKey(key.id) }
    }

    func selectPage(_ index: Int) {
        selectPage(index, forward: index > model.pageIndex)
    }

    /// `forward` says which way the pages slide, which matters when swiping
    /// wraps from the last row back to the first.
    private func selectPage(_ index: Int, forward: Bool) {
        guard model.pages.indices.contains(index), index != model.pageIndex else { return }
        // Set the direction first so the outgoing page picks it up before it leaves.
        model.pageEdge = forward ? .bottom : .top
        DispatchQueue.main.async { [self] in
            rawScrollOffset = 0
            withAnimation(.spring(response: 0.44, dampingFraction: 0.82)) {
                model.pageIndex = index
                model.pagePull = 0
                model.scrollOffset = 0
                model.hovered = nil
                model.hoveredAction = nil
                model.isConfirmingCleanup = false
            }
            if let page = model.currentPage, page.access != .ok { monitors[page.id]?.refresh() }
            refreshPageData()
        }
    }

    /// Pages that aren't folders have no watcher pushing changes in, so look
    /// again whenever one comes into view.
    private func refreshPageData() {
        switch model.currentPage?.kind {
        case .meetings: calendar.refresh()
        case .shortcuts: if Preferences.syncsShortcuts { deckSync.check() }
        default: break
        }
    }

    // MARK: - State

    private func setState(_ state: IslandState) {
        guard model.state != state else { return }
        cancelTimers()

        let animation: Animation
        switch state {
        case .expanded:
            animation = .spring(response: 0.44, dampingFraction: 0.74)
            model.scrollOffset = 0
            rawScrollOffset = 0
            model.pagePull = 0
            if model.state == .peek, case .download(_, let pageID, _) = model.peek,
               let index = model.pages.firstIndex(where: { $0.id == pageID }) {
                // Open on the folder the preview was about.
                model.pageIndex = index
            } else if Date().timeIntervalSince(collapsedAt) > Timing.pageMemory {
                model.pageIndex = 0
            }
            if let page = model.currentPage, page.access != .ok { monitors[page.id]?.refresh() }
            refreshPageData()
            Haptics.perform(.levelChange)
        case .peek:
            animation = .spring(response: 0.46, dampingFraction: 0.7)
        case .collapsed, .activity:
            animation = model.state == .expanded
                ? .spring(response: 0.36, dampingFraction: 0.9)
                : .spring(response: 0.45, dampingFraction: 0.72)
            if model.state == .expanded { collapsedAt = Date() }
            if model.isArranging { setArranging(false) }
            model.hovered = nil
            model.hoveredAction = nil
            model.pressed = nil
            model.isConfirmingCleanup = false
        }

        panel.ignoresMouseEvents = (state == .collapsed || state == .activity) && !model.isDraggingFile
        withAnimation(animation) { model.state = state }
    }

    private func expand() { setState(.expanded) }

    private func collapse(waitForPointerToLeave: Bool = false) {
        #if DEBUG
        if pinnedState != nil { return }
        #endif
        if waitForPointerToLeave { waitsForPointerToLeave = true }
        setState(restState)
    }

    private func showPeek(_ content: PeekContent, duration: TimeInterval) {
        guard model.state != .expanded else { return }
        model.peek = content
        setState(.peek)
        isHoldingPeek = false
        schedulePeekEnd(after: duration)
        updatePeekHold()
    }

    private func schedulePeekEnd(after duration: TimeInterval) {
        peekTimer?.invalidate()
        peekTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            guard let self, self.model.state == .peek else { return }
            self.collapse()
        }
    }

    /// A download preview is something to click or drag out, so it stays up
    /// while the pointer is on it and lingers briefly once it leaves.
    private func updatePeekHold() {
        guard model.state == .peek, case .download = model.peek else { return }
        let point = NSEvent.mouseLocation
        let hold = model.isDraggingFile
            || model.metrics.screenRect(for: .peek).contains(point)
            || model.metrics.hotZone.contains(point)
        guard hold != isHoldingPeek else { return }
        isHoldingPeek = hold
        if hold {
            peekTimer?.invalidate(); peekTimer = nil
        } else {
            schedulePeekEnd(after: Timing.peekLinger)
        }
    }

    private func cancelTimers() {
        expandTimer?.invalidate(); expandTimer = nil
        collapseTimer?.invalidate(); collapseTimer = nil
        peekTimer?.invalidate(); peekTimer = nil
    }

    // MARK: - Pointer

    private func installEventMonitors() {
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] event in
            self?.pointerMoved(dragging: event.type != .mouseMoved)
        }) {
            eventMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
            self?.pointerMoved(dragging: event.type != .mouseMoved)
            return event
        }) {
            eventMonitors.append(local)
        }
        if let scroll = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            guard let self, event.window === self.panel, self.model.state == .expanded else { return event }
            if self.model.isArranging { return nil }
            self.scroll(with: event)
            return nil
        }) {
            eventMonitors.append(scroll)
        }
    }

    private func pointerMoved(dragging: Bool) {
        #if DEBUG
        if pinnedState != nil { return }
        #endif
        let point = NSEvent.mouseLocation
        let metrics = model.metrics

        switch model.state {
        case .collapsed, .activity:
            let zone = model.state == .activity
                ? metrics.screenRect(for: .activity).union(metrics.hotZone)
                : metrics.hotZone
            let inZone = zone.contains(point)
            if waitsForPointerToLeave {
                if !inZone { waitsForPointerToLeave = false }
                return
            }
            if inZone && !dragging {
                scheduleExpand(after: Timing.hoverDelay)
            } else {
                expandTimer?.invalidate(); expandTimer = nil
            }

        case .peek:
            let rect: CGRect
            let delay: TimeInterval
            if case .download = model.peek {
                // Pointing at the file leaves it grabbable; the notch itself
                // still opens the shelf.
                updatePeekHold()
                rect = metrics.hotZone
                delay = Timing.hoverDelay
            } else {
                rect = metrics.screenRect(for: .peek).union(metrics.hotZone)
                delay = Timing.peekHoverDelay
            }
            if rect.contains(point) && !dragging && !model.isDraggingFile {
                scheduleExpand(after: delay)
            } else {
                expandTimer?.invalidate(); expandTimer = nil
            }

        case .expanded:
            if isMenuOpen || model.isDraggingFile || model.draggingPageID != nil { return }
            let rect = metrics.screenRect(for: .expanded).insetBy(dx: -10, dy: -10)
            if rect.contains(point) {
                collapseTimer?.invalidate(); collapseTimer = nil
            } else if collapseTimer == nil {
                collapseTimer = Timer.scheduledTimer(withTimeInterval: Timing.leaveDelay, repeats: false) { [weak self] _ in
                    self?.collapseTimer = nil
                    self?.collapse()
                }
            }
        }
    }

    private func scheduleExpand(after delay: TimeInterval) {
        guard expandTimer == nil else { return }
        expandTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.expandTimer = nil
            self?.expand()
        }
    }

    // MARK: - Scrolling

    /// Trackpad: sideways moves the shelf, up and down switches folders. The
    /// first few points of a gesture decide which, and it sticks for the rest
    /// of that gesture. Mouse: the wheel switches folders, Shift-wheel scrolls.
    private func scroll(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas else {
            wheel(event)
            return
        }

        if event.phase == .began || event.phase == .mayBegin {
            scrollAxis = nil
            axisProbe = .zero
            rawPagePull = 0
            gestureSwitchedPage = false
            gestureHitEdge = false
            rawScrollOffset = model.scrollOffset
            ignoresMomentum = false
        }

        if scrollAxis == nil {
            guard event.momentumPhase.isEmpty else { return }
            axisProbe.width += abs(event.scrollingDeltaX)
            axisProbe.height += abs(event.scrollingDeltaY)
            if event.phase == .ended || event.phase == .cancelled { return }
            guard axisProbe.width + axisProbe.height > 5 else { return }
            // Vertical has to clearly win, so a sideways swipe never switches folders.
            scrollAxis = axisProbe.height > axisProbe.width * 1.5 ? .vertical : .horizontal
        }

        switch scrollAxis {
        case .vertical: pullPage(with: event)
        default: scrollShelf(with: event, delta: -event.scrollingDeltaX)
        }
    }

    private func pullPage(with event: NSEvent) {
        // Page switches come from the finger, never from momentum.
        guard event.momentumPhase.isEmpty, !gestureSwitchedPage, model.pages.count > 1 else { return }

        rawPagePull += -event.scrollingDeltaY
        let forward = rawPagePull > 0

        if abs(rawPagePull) >= Paging.threshold {
            gestureSwitchedPage = true
            Haptics.perform(.levelChange)
            selectPage(wrappedPage(forward: forward), forward: forward)
            return
        }

        // Heavy resistance while pulling, so a small swipe springs back.
        let dimension: CGFloat = 110
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.pagePull = Self.band(abs(rawPagePull), dimension: dimension) * (rawPagePull > 0 ? 1 : -1)
        }

        if event.phase == .ended || event.phase == .cancelled {
            releasePagePull()
        }
    }

    /// The next row up or down, going around from the last row to the first.
    private func wrappedPage(forward: Bool) -> Int {
        let count = model.pages.count
        return (model.pageIndex + (forward ? 1 : -1) + count) % count
    }

    private func releasePagePull() {
        rawPagePull = 0
        withAnimation(.spring(response: 0.38, dampingFraction: 0.62)) { model.pagePull = 0 }
    }

    /// Mouse wheels have no gesture phases, so lines are collected over a short
    /// window and a switch needs a few of them in a row.
    private func wheel(_ event: NSEvent) {
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY

        if abs(dx) > abs(dy) {
            let maxOffset = model.maxScrollOffset
            guard maxOffset > 0 else { return }
            rawScrollOffset = min(max(rawScrollOffset - dx * 12, 0), maxOffset)
            withAnimation(.smooth(duration: 0.28)) { model.scrollOffset = rawScrollOffset }
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard model.pages.count > 1, now >= wheelLockedUntil else { return }
        if now - lastWheelTime > 0.35 { wheelPull = 0 }
        lastWheelTime = now
        wheelPull += -dy

        if abs(wheelPull) >= Paging.wheelThreshold {
            let forward = wheelPull > 0
            wheelPull = 0
            wheelLockedUntil = now + 0.45
            wheelRelease?.cancel()
            Haptics.perform(.levelChange)
            selectPage(wrappedPage(forward: forward), forward: forward)
            return
        }

        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
            model.pagePull = min(abs(wheelPull) * 7, 22) * (wheelPull > 0 ? 1 : -1)
        }
        wheelRelease?.cancel()
        let release = DispatchWorkItem { [weak self] in
            self?.wheelPull = 0
            self?.releasePagePull()
        }
        wheelRelease = release
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: release)
    }

    /// Horizontal scrolling with trackpad momentum and a rubber band at both ends.
    private func scrollShelf(with event: NSEvent, delta: CGFloat) {
        let maxOffset = model.maxScrollOffset
        guard maxOffset > 0 else { return }

        let isMomentum = !event.momentumPhase.isEmpty
        if isMomentum && ignoresMomentum { return }

        let overshoot = rawScrollOffset < 0 ? -rawScrollOffset : max(0, rawScrollOffset - maxOffset)
        if overshoot > 0 && !gestureHitEdge {
            gestureHitEdge = true
            Haptics.perform(.alignment)
        }
        if isMomentum && overshoot > 0 {
            // Momentum running into an edge: let it squash briefly, then bounce back.
            rawScrollOffset += delta * 0.25
            if overshoot > 30 {
                ignoresMomentum = true
                snapScrollBack()
                return
            }
        } else {
            rawScrollOffset += delta
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.scrollOffset = Self.rubberBand(rawScrollOffset, max: maxOffset, dimension: model.metrics.rowWidth)
        }

        let ended = event.phase == .ended || event.phase == .cancelled
            || event.momentumPhase == .ended || event.momentumPhase == .cancelled
        if ended && (rawScrollOffset < 0 || rawScrollOffset > maxOffset) {
            snapScrollBack()
        }
    }

    private func snapScrollBack() {
        rawScrollOffset = min(max(rawScrollOffset, 0), model.maxScrollOffset)
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            model.scrollOffset = rawScrollOffset
        }
    }

    /// UIScrollView's rubber band curve: follows the finger at first, then
    /// approaches `dimension` and never passes it.
    private static func band(_ x: CGFloat, dimension: CGFloat) -> CGFloat {
        (1 - 1 / (x * 0.55 / dimension + 1)) * dimension
    }

    private static func rubberBand(_ offset: CGFloat, max maxOffset: CGFloat, dimension: CGFloat) -> CGFloat {
        if offset < 0 { return -band(-offset, dimension: dimension) }
        if offset > maxOffset { return maxOffset + band(offset - maxOffset, dimension: dimension) }
        return offset
    }

    // MARK: - Dragging files out

    private func installDragHandlers() {
        let source = FileDragSource.shared
        source.onBegin = { [weak self] in
            Haptics.perform(.generic)
            self?.model.isDraggingFile = true
            self?.model.hovered = nil
        }
        source.onMove = { [weak self] point in
            guard let self, self.model.state != .collapsed else { return }
            let rect = self.model.metrics.screenRect(for: self.model.state).insetBy(dx: -6, dy: -6)
            // Get out of the way as soon as the file leaves the island.
            if !rect.contains(point) { self.setState(self.restState) }
        }
        source.onEnd = { [weak self] _ in
            guard let self else { return }
            self.model.isDraggingFile = false
            if self.model.state == .collapsed || self.model.state == .activity {
                self.panel.ignoresMouseEvents = true
                self.waitsForPointerToLeave = self.model.metrics.hotZone.contains(NSEvent.mouseLocation)
            } else {
                self.pointerMoved(dragging: false)
            }
        }
    }

    // MARK: - System events

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateScreen() })

        observers.append(center.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.isMenuOpen = true })

        observers.append(center.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.isMenuOpen = false
            self?.pointerMoved(dragging: false)
        })

        // Keep the window above everything after Spaces and full screen changes.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.panel.orderFrontRegardless() })
    }

    private func updateScreen() {
        guard let metrics = IslandMetrics(screen: IslandMetrics.preferredScreen()) else { return }
        if metrics != model.metrics { model.metrics = metrics }
        panel.setFrame(metrics.windowFrame, display: true)
    }

    // MARK: - IslandActions

    func open(_ item: DownloadItem) {
        collapse(waitForPointerToLeave: true)
        FileActions.open(item.url)
    }

    func openFolder() {
        collapse(waitForPointerToLeave: true)
        if let page = model.currentPage { FinderWindow.openNewestFirst(page.url) }
    }

    func openPrivacySettings() {
        collapse(waitForPointerToLeave: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }

    func showMenu(for item: DownloadItem) {
        if model.state == .peek { expand() }
        let menu = NSMenu()
        menu.addItem(menuItem("Open", symbol: "arrow.up.forward.app", action: #selector(menuOpen(_:)), file: item.url))

        // Finding every app that opens a file is slow, so the submenu fills
        // itself in only when it's about to appear.
        let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        openWith.image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: nil)
        let submenu = NSMenu()
        submenu.addItem(NSMenuItem(title: "Loading…", action: nil, keyEquivalent: ""))
        let delegate = OpenWithMenu(file: item.url, target: self, action: #selector(menuOpenWith(_:)))
        openWithMenu = delegate
        submenu.delegate = delegate
        openWith.submenu = submenu
        menu.addItem(openWith)

        if let action = SmartAction.available(for: item) {
            let entry = menuItem(action.menuTitle, symbol: action == .extract ? "archivebox" : "arrow.down.app", action: #selector(menuSmartAction(_:)))
            entry.representedObject = item.id
            menu.addItem(entry)
        }
        menu.addItem(menuItem("Show in Finder", symbol: "folder", action: #selector(menuReveal(_:)), file: item.url))
        menu.addItem(menuItem("Quick Look", symbol: "eye", action: #selector(menuQuickLook(_:)), file: item.url))
        menu.addItem(.separator())
        menu.addItem(menuItem("Copy", symbol: "doc.on.doc", action: #selector(menuCopy(_:)), file: item.url))
        menu.addItem(.separator())
        menu.addItem(menuItem("Move to Trash", symbol: "trash", action: #selector(menuTrash(_:)), file: item.url))

        present(menu)
    }

    func showSettingsMenu() {
        let menu = NSMenu()

        menu.addItem(.sectionHeader(title: "Folders"))
        for (index, page) in model.pages.enumerated() where page.kind == .folder {
            let item = menuItem(page.name, action: #selector(menuSelectPage(_:)))
            item.representedObject = index
            item.state = index == model.pageIndex ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(menuItem("Add Folder…", symbol: "plus", action: #selector(menuAddFolder)))
        if model.currentPage?.kind == .folder, model.pages.filter({ $0.kind == .folder }).count > 1 {
            menu.addItem(menuItem("Remove “\(model.folderName)”", symbol: "minus", action: #selector(menuRemoveFolder)))
        }
        let deck = menuItem("Shortcuts Page", action: #selector(menuToggleShortcutsPage))
        deck.state = Preferences.showsShortcutsPage ? .on : .off
        menu.addItem(deck)
        let meetings = menuItem("Meetings Page", action: #selector(menuToggleMeetingsPage))
        meetings.state = Preferences.showsMeetingsPage ? .on : .off
        menu.addItem(meetings)
        if model.pages.count > 1 {
            menu.addItem(menuItem("Arrange Rows…", symbol: "line.3.horizontal", action: #selector(menuArrangeRows)))
        }
        menu.addItem(.separator())

        switch model.currentPage?.kind {
        case .meetings where calendar.access == .granted:
            menu.addItem(.sectionHeader(title: "Meetings"))
            menu.addItem(calendarsMenuItem())
            menu.addItem(.separator())
        case .shortcuts:
            menu.addItem(.sectionHeader(title: "Shortcuts"))
            let sync = menuItem("Sync with iCloud", symbol: "icloud", action: #selector(menuToggleDeckSync))
            sync.state = Preferences.syncsShortcuts ? .on : .off
            sync.isEnabled = DeckSync.isAvailable
            sync.toolTip = DeckSync.isAvailable
                ? "Keeps these shortcuts the same on every Mac signed in to your Apple ID."
                : "Turn on iCloud Drive in System Settings to sync shortcuts."
            menu.addItem(sync)
            menu.addItem(menuItem("Export Shortcuts…", symbol: "square.and.arrow.up", action: #selector(menuExportDeck)))
            menu.addItem(menuItem("Import Shortcuts…", symbol: "square.and.arrow.down", action: #selector(menuImportDeck)))
            menu.addItem(.separator())
        default:
            break
        }

        menu.addItem(displayMenuItem())

        let preview = menuItem("Preview New Files", action: #selector(menuTogglePreview))
        preview.state = Preferences.showsNewDownloadPreview ? .on : .off
        menu.addItem(preview)

        let haptics = menuItem("Haptic Feedback", action: #selector(menuToggleHaptics))
        haptics.state = Preferences.hapticsEnabled ? .on : .off
        menu.addItem(haptics)

        let login = menuItem("Open at Login", action: #selector(menuToggleLogin))
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = menuItem("Quit QuickFolder", action: #selector(menuQuit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)

        menu.autoenablesItems = false
        present(menu)
    }

    /// Every calendar by account, ticked if its meetings show.
    private func calendarsMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Calendars", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)
        let submenu = NSMenu()
        for (account, calendars) in calendar.choices() {
            submenu.addItem(.sectionHeader(title: account))
            for choice in calendars {
                let entry = menuItem(choice.title, action: #selector(menuToggleCalendar(_:)))
                entry.representedObject = choice.id
                entry.state = choice.isIncluded ? .on : .off
                entry.image = Self.swatch(choice.color)
                submenu.addItem(entry)
            }
        }
        item.submenu = submenu
        return item
    }

    private static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
    }

    /// Which display the island lives on. Displays without a notch get a
    /// drawn one at the top center, always visible.
    private func displayMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Show On", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "display", accessibilityDescription: nil)
        let submenu = NSMenu()
        let chosen = Preferences.displayID
        let available = NSScreen.screens.compactMap(\.displayUUID)

        let automatic = menuItem("Automatic", action: #selector(menuChooseDisplay(_:)))
        automatic.state = chosen == nil || !available.contains(chosen!) ? .on : .off
        automatic.toolTip = "The display with a notch, or the main display"
        submenu.addItem(automatic)
        submenu.addItem(.separator())
        for screen in NSScreen.screens {
            guard let id = screen.displayUUID else { continue }
            let name = screen.safeAreaInsets.top > 0 ? "\(screen.localizedName) (notch)" : screen.localizedName
            let entry = menuItem(name, action: #selector(menuChooseDisplay(_:)))
            entry.representedObject = id
            entry.state = id == chosen ? .on : .off
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    /// Menus from an inactive app get mouse-moved events at a trickle, so
    /// highlighting lags behind the pointer. QuickFolder activates just for
    /// the menu and hands focus back afterwards, unless an action opened a
    /// window of ours (Quick Look, the folder picker).
    private func present(_ menu: NSMenu) {
        let wasActive = NSApp.isActive
        NSApp.activate()
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        DispatchQueue.main.async {
            if !wasActive && NSApp.isActive && NSApp.keyWindow == nil && NSApp.modalWindow == nil {
                NSApp.deactivate()
            }
        }
    }

    private func menuItem(_ title: String, symbol: String? = nil, action: Selector, file: URL? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = file
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    @objc private func menuOpen(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        collapse(waitForPointerToLeave: true)
        FileActions.open(url)
    }

    @objc private func menuOpenWith(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [URL], pair.count == 2 else { return }
        collapse(waitForPointerToLeave: true)
        FileActions.open(pair[0], with: pair[1])
    }

    @objc private func menuSmartAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let item = model.items.first(where: { $0.id == id }),
              let action = SmartAction.available(for: item) else { return }
        perform(action, on: item)
    }

    @objc private func menuReveal(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        collapse(waitForPointerToLeave: true)
        FileActions.reveal(url)
    }

    @objc private func menuQuickLook(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        collapse(waitForPointerToLeave: true)
        QuickLook.shared.show(url)
    }

    @objc private func menuCopy(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        FileActions.copy(url)
    }

    @objc private func menuTrash(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        FileActions.moveToTrash(url)
    }

    @objc private func menuSelectPage(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        selectPage(index)
    }

    @objc private func menuAddFolder() {
        collapse(waitForPointerToLeave: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        panel.prompt = "Add Folder"
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url {
            var folders = Preferences.folders
            if !folders.contains(where: { $0.path == url.path }) {
                folders.append(url)
                Preferences.folders = folders
                reloadFolders()
            }
            if let index = model.pages.firstIndex(where: { $0.id == url.path }) {
                model.pageIndex = index
                collapsedAt = Date()
            }
        }
        NSApp.deactivate()
    }

    @objc private func menuRemoveFolder() {
        guard let page = model.currentPage, page.kind == .folder,
              model.pages.filter({ $0.kind == .folder }).count > 1 else { return }
        Preferences.folders = Preferences.folders.filter { $0.path != page.id }
        withAnimation(.spring(response: 0.44, dampingFraction: 0.82)) {
            model.pageEdge = .top
            reloadFolders()
        }
    }

    @objc private func menuArrangeRows() {
        setArranging(true)
    }

    @objc private func menuToggleShortcutsPage() {
        Preferences.showsShortcutsPage.toggle()
        withAnimation(.spring(response: 0.44, dampingFraction: 0.82)) { reloadFolders() }
    }

    @objc private func menuToggleMeetingsPage() {
        Preferences.showsMeetingsPage.toggle()
        withAnimation(.spring(response: 0.44, dampingFraction: 0.82)) { reloadFolders() }
        if Preferences.showsMeetingsPage { calendar.refresh() }
    }

    @objc private func menuToggleCalendar(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var overrides = Preferences.calendarOverrides
        overrides[id] = sender.state != .on
        Preferences.calendarOverrides = overrides
        calendar.refresh()
    }

    @objc private func menuChooseDisplay(_ sender: NSMenuItem) {
        Preferences.displayID = sender.representedObject as? String
        collapse()
        updateScreen()
    }

    @objc private func menuToggleDeckSync() {
        Preferences.syncsShortcuts.toggle()
        if Preferences.syncsShortcuts {
            startDeckSync()
            showToast(Toast(symbol: "icloud.fill", text: "Shortcuts sync with iCloud", url: nil))
        } else {
            deckSync.stop()
            Preferences.lastShortcutsSync = nil
        }
    }

    @objc private func menuExportDeck() {
        collapse(waitForPointerToLeave: true)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "QuickFolder Shortcuts.json"
        panel.allowedContentTypes = [.json]
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url,
           let data = DeckFile(updated: Date(), keys: model.deckKeys).encoded() {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                NSSound.beep()
            }
        }
        NSApp.deactivate()
    }

    /// Adds the keys from a shared file, skipping ones you already have.
    @objc private func menuImportDeck() {
        collapse(waitForPointerToLeave: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        NSApp.activate()
        defer { NSApp.deactivate() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url), let file = DeckFile.decode(data) else {
            NSSound.beep()
            return
        }
        let added = file.keys
            .filter { !model.deckKeys.contains(sameAs: $0) }
            .map { key -> DeckKey in
                var copy = key
                copy.id = UUID()
                return copy
            }
        model.deckKeys.append(contentsOf: added)
        saveDeck()
        if let index = model.pages.firstIndex(where: { $0.kind == .shortcuts }) {
            model.pageIndex = index
            collapsedAt = Date()
        }
    }

    @objc private func menuToggleHaptics() {
        Preferences.hapticsEnabled.toggle()
        Haptics.perform(.levelChange)
    }

    @objc private func menuTogglePreview() {
        Preferences.showsNewDownloadPreview.toggle()
    }

    @objc private func menuToggleLogin() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }

    // MARK: - Debug

    #if DEBUG
    /// `QF_DEBUG_STATE=expanded|peek` pins the island open for screenshots.
    /// With `expanded`: `QF_DEBUG_PAGE=n` opens page n, `QF_DEBUG_ACTIONS`
    /// runs every smart action, `QF_DEBUG_RUNKEY=n` presses deck key n,
    /// `QF_DEBUG_EDITOR` opens the key editor, `QF_DEBUG_ARRANGE` opens Arrange
    /// mode, `QF_DEBUG_CONFIRM` shows the cleanup confirmation,
    /// `QF_DEBUG_MENU` opens the options menu.
    private func applyDebugState() {
        guard let value = ProcessInfo.processInfo.environment["QF_DEBUG_STATE"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
            switch value {
            case "peek":
                if let page = model.currentPage, let item = page.items.first {
                    showPeek(.download(item, pageID: page.id, label: "Downloaded"), duration: 3600)
                }
                pinnedState = .peek
            default:
                expand()
                pinnedState = .expanded
                if let page = ProcessInfo.processInfo.environment["QF_DEBUG_PAGE"].flatMap(Int.init) {
                    selectPage(page)
                }
                let env = ProcessInfo.processInfo.environment
                if let index = env["QF_DEBUG_RUNKEY"].flatMap(Int.init), self.model.deckKeys.indices.contains(index) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        // QF_DEBUG_FRONT=<bundle id> only presses the key if that app is in front.
                        if let required = env["QF_DEBUG_FRONT"],
                           NSWorkspace.shared.frontmostApplication?.bundleIdentifier != required {
                            NSLog("QuickFolder debug: skipped key, %@ isn't in front", required)
                            return
                        }
                        self.run(self.model.deckKeys[index])
                    }
                }
                // QF_DEBUG_MEETINGS fills the Meetings page with samples, without asking for Calendar access.
                if env["QF_DEBUG_MEETINGS"] != nil, let index = self.model.pages.firstIndex(where: { $0.kind == .meetings }) {
                    self.calendar.onChange = nil
                    self.calendar.onAccessChange = nil
                    self.model.calendarAccess = .granted
                    self.model.meetings = Meeting.samples
                    self.selectPage(index)
                }
                if env["QF_DEBUG_ARRANGE"] != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.setArranging(true) }
                }
                if env["QF_DEBUG_EDITOR"] != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.editKey(self.model.deckKeys.first) }
                }
                if env["QF_DEBUG_CONFIRM"] != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.model.isConfirmingCleanup = true }
                }
                if ProcessInfo.processInfo.environment["QF_DEBUG_ACTIONS"] != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        for item in self.model.items {
                            if let action = SmartAction.available(for: item) { self.perform(action, on: item) }
                        }
                    }
                }
                if ProcessInfo.processInfo.environment["QF_DEBUG_MENU"] != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.showSettingsMenu() }
                }
            }
        }
    }
    #endif
}

/// Fills in an "Open With" submenu the first time it opens.
private final class OpenWithMenu: NSObject, NSMenuDelegate {
    private let file: URL
    private weak var target: AnyObject?
    private let action: Selector
    private var isFilled = false

    init(file: URL, target: AnyObject, action: Selector) {
        self.file = file
        self.target = target
        self.action = action
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard !isFilled else { return }
        isFilled = true
        menu.removeAllItems()

        let apps = FileActions.applications(toOpen: file)
        if apps.isEmpty {
            menu.addItem(NSMenuItem(title: "No Apps", action: nil, keyEquivalent: ""))
        }
        for (index, app) in apps.prefix(12).enumerated() {
            let name = FileManager.default.displayName(atPath: app.path)
            let entry = NSMenuItem(title: index == 0 ? "\(name) (default)" : name, action: action, keyEquivalent: "")
            entry.target = target
            entry.representedObject = [file, app]
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            entry.image = icon
            menu.addItem(entry)
            if index == 0 && apps.count > 1 { menu.addItem(.separator()) }
        }
    }
}

/// What a meeting menu item acts on.
private final class MeetingChoice: NSObject {
    let meeting: Meeting
    let account: String?

    init(meeting: Meeting, account: String?) {
        self.meeting = meeting
        self.account = account
    }
}
