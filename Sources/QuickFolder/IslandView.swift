import SwiftUI
import UniformTypeIdentifiers

struct IslandView: View {
    let model: IslandModel

    var body: some View {
        let metrics = model.metrics
        let shape = metrics.shape(for: model.state)
        let notch = NotchShape(earRadius: shape.earRadius, bottomRadius: shape.bottomRadius)

        ZStack(alignment: .top) {
            ExpandedView(model: model)
                .frame(width: metrics.expandedBody.width, height: metrics.expandedBody.height)
                .modifier(Reveal(isVisible: model.state == .expanded))

            PeekView(model: model)
                .frame(width: metrics.peekBody.width, height: metrics.peekBody.height)
                .modifier(Reveal(isVisible: model.state == .peek))

            if model.state == .activity {
                ActivityWings(model: model)
                    .frame(width: metrics.activityBody.width, height: metrics.activityBody.height)
                    .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .top)))
            }
        }
        .frame(width: shape.size.width, height: shape.size.height, alignment: .top)
        .background(notch.fill(Color.black))
        .clipShape(notch)
        // A tight contact shadow plus a wide ambient one. Both fit inside the
        // window's padding so the blur never gets cut off at the window edge.
        .shadow(color: .black.opacity(model.state == .collapsed ? 0 : 0.28), radius: 4, y: 2)
        .shadow(
            color: .black.opacity(model.state == .collapsed || model.state == .activity ? 0 : 0.32),
            radius: model.state == .expanded ? 22 : 14,
            y: 10
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}

/// Content fades and sharpens in slightly after the shape starts growing, and
/// gets out of the way quickly when it shrinks.
private struct Reveal: ViewModifier {
    let isVisible: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .blur(radius: isVisible ? 0 : 8)
            .scaleEffect(isVisible ? 1 : 0.9, anchor: .top)
            .animation(
                isVisible ? .smooth(duration: 0.38).delay(0.05) : .smooth(duration: 0.16),
                value: isVisible
            )
    }
}

// MARK: - Expanded

private struct ExpandedView: View {
    let model: IslandModel

    var body: some View {
        let pull = model.pagePull
        let slide = AnyTransition.push(from: model.pageEdge).combined(with: .opacity)

        VStack(spacing: 0) {
            HeaderView(model: model)
                .frame(height: model.metrics.notchHeight)

            ZStack {
                PageContent(model: model)
                    .id(model.currentPage?.id)
                    .transition(slide)
            }
            .offset(y: -pull)
            .opacity(1 - Double(min(abs(pull) / 90, 0.45)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .overlay(alignment: .leading) {
                if model.pages.count > 1 {
                    PageDots(count: model.pages.count, index: model.pageIndex, pull: pull)
                        .padding(.leading, 5)
                }
            }
        }
    }
}

private struct PageContent: View {
    let model: IslandModel

    var body: some View {
        Group {
            if model.currentPage?.kind == .shortcuts {
                DeckView(model: model)
            } else {
                folderContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var folderContent: some View {
        Group {
            switch model.access {
            case .denied:
                AccessDeniedView(model: model)
            case .missing:
                PlaceholderView(symbol: "questionmark.folder", text: "“\(model.folderName)” can’t be found")
            case .ok:
                if model.items.isEmpty && model.pageDownloads.isEmpty {
                    PlaceholderView(
                        symbol: "tray",
                        text: model.currentPage?.isDownloads == false ? "“\(model.folderName)” is empty" : "No downloads yet"
                    )
                } else {
                    ShelfView(model: model)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A vertical page indicator, so the folders read as a stack you swipe through.
private struct PageDots: View {
    let count: Int
    let index: Int
    let pull: CGFloat

    var body: some View {
        VStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { dot in
                Capsule()
                    .fill(.white.opacity(dot == index ? 0.85 : 0.25))
                    .frame(width: 4, height: dot == index ? 14 : 4)
            }
        }
        // Leans toward the folder you're pulling to.
        .offset(y: -pull * 0.12)
        .animation(.spring(response: 0.38, dampingFraction: 0.7), value: index)
        .padding(.bottom, 8)
    }
}

private struct HeaderView: View {
    let model: IslandModel

    var body: some View {
        let page = model.currentPage
        HStack(spacing: 2) {
            ZStack(alignment: .leading) {
                if let toast = model.toast {
                    ToastView(toast: toast, model: model)
                        .transition(.push(from: .bottom).combined(with: .opacity))
                } else {
                    Text(model.folderName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .id(model.folderName)
                        .transition(.push(from: model.pageEdge).combined(with: .opacity))
                }
            }
            .clipped()
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: model.toast)

            Spacer(minLength: model.metrics.notchRect.width + 24)

            if page?.kind == .folder, let cleanup = page?.cleanup {
                CleanupPill(cleanup: cleanup, model: model)
                    .padding(.trailing, 4)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }

            if page?.kind == .shortcuts {
                HeaderButton(model: model, target: .addDeckKey, symbol: "plus", label: "Add Shortcut") {
                    model.actions?.editKey(nil)
                }
            } else {
                HeaderButton(model: model, target: .openFolder, symbol: "folder", label: "Open in Finder") {
                    model.actions?.openFolder()
                }
            }
            HeaderButton(model: model, target: .settings, symbol: "ellipsis", label: "Options") {
                model.actions?.showSettingsMenu()
            }
        }
        .padding(.leading, 22)
        .padding(.trailing, 14)
    }
}

/// "✓ Installed Arc" in place of the title for a few seconds. Clicking it opens
/// what it's about.
private struct ToastView: View {
    let toast: Toast
    let model: IslandModel

    var body: some View {
        let isHovered = model.hovered == .toast
        HStack(spacing: 6) {
            Image(systemName: toast.symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color(red: 0.2, green: 0.78, blue: 0.35))
                .symbolEffect(.bounce, value: toast)
            Text(toast.text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovered && toast.url != nil ? 1 : 0.9))
                .underline(isHovered && toast.url != nil, color: .white.opacity(0.5))
                .lineLimit(1)
        }
        .overlay {
            if model.state == .expanded && toast.url != nil {
                MouseInteraction(target: .toast, model: model) { model.actions?.openToast() }
            }
        }
    }
}

/// Offers to clear out old installers: one click to ask, a second to do it.
private struct CleanupPill: View {
    let cleanup: Cleanup
    let model: IslandModel

    var body: some View {
        let isHovered = model.hovered == .cleanup
        let isConfirming = model.isConfirmingCleanup
        let count = cleanup.files.count
        let size = ByteCountFormatter.string(fromByteCount: cleanup.bytes, countStyle: .file)
        let label = isConfirming ? "Trash \(count) installer\(count == 1 ? "" : "s")?" : "Clean Up \(size)"

        HStack(spacing: 4) {
            Image(systemName: isConfirming ? "trash.fill" : "sparkles")
                .font(.system(size: 10, weight: .semibold))
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .contentTransition(.opacity)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(
            Capsule().fill(isConfirming
                ? Color(red: 1, green: 0.27, blue: 0.23).opacity(isHovered ? 0.75 : 0.55)
                : .white.opacity(isHovered ? 0.2 : 0.12))
        )
        .fixedSize()
        .overlay {
            if model.state == .expanded {
                MouseInteraction(target: .cleanup, model: model) { model.actions?.cleanUp() }
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.75), value: isConfirming)
        .animation(.smooth(duration: 0.18), value: isHovered)
        .help("Installers (.dmg, .pkg) added more than a week ago")
    }
}

private struct HeaderButton: View {
    let model: IslandModel
    let target: HoverTarget
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        let isHovered = model.hovered == target
        let isPressed = model.pressed == target

        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(isHovered ? 1 : 0.62))
            .frame(width: 28, height: 22)
            .background(Capsule().fill(.white.opacity(isHovered ? 0.14 : 0)))
            .scaleEffect(isPressed ? 0.88 : 1)
            .contentShape(Capsule())
            .overlay {
                if model.state == .expanded {
                    MouseInteraction(target: target, model: model, onClick: action)
                }
            }
            .animation(.smooth(duration: 0.18), value: isHovered)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: isPressed)
            .accessibilityLabel(label)
    }
}

private struct ShelfView: View {
    let model: IslandModel

    var body: some View {
        let width = model.metrics.rowWidth
        let offset = model.scrollOffset
        let maxOffset = model.maxScrollOffset

        TimelineView(.everyMinute) { context in
            HStack(spacing: IslandMetrics.tileSpacing) {
                ForEach(model.pageDownloads) { activity in
                    DownloadingTile(activity: activity, isAnimating: model.state == .expanded)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                ForEach(model.items) { item in
                    TileView(item: item, model: model, now: context.date)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .fixedSize()
            .offset(x: -offset)
            .frame(width: width, alignment: .leading)
        }
        .frame(width: width, height: IslandMetrics.tileHeight, alignment: .leading)
        .clipped()
        .mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [offset > 1 ? .clear : .black, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 28)
                Rectangle()
                LinearGradient(colors: [.black, offset < maxOffset - 1 ? .clear : .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 28)
            }
            .animation(.smooth(duration: 0.2), value: offset > 1)
            .animation(.smooth(duration: 0.2), value: offset < maxOffset - 1)
        }
        .padding(.bottom, 4)
    }
}

private struct TileView: View {
    let item: DownloadItem
    let model: IslandModel
    let now: Date

    var body: some View {
        let target = HoverTarget.tile(item.id)
        let isActionHovered = model.hoveredAction == item.id
        let isHovered = (model.hovered == target || isActionHovered) && !model.isDraggingFile
        let isPressed = model.pressed == target
        let isBusy = model.busyItems.contains(item.id)
        let isHighlighted = model.highlightedID == item.id
        let action = SmartAction.available(for: item)
        let thumbnail = model.thumbnails.thumbnail(for: item)

        VStack(spacing: 0) {
            ThumbnailView(thumbnail: thumbnail)
                .frame(width: 70, height: 54)
                .opacity(isBusy ? 0.45 : 1)
                .scaleEffect(isPressed ? 0.9 : (isHovered ? 1.08 : 1))
                .padding(.bottom, 8)

            Text(item.wrappableName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(height: 28, alignment: .top)

            Text(subtitle(action: action, isBusy: isBusy, isActionHovered: isActionHovered))
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(.white.opacity(isActionHovered || isBusy ? 0.75 : 0.42))
                .lineLimit(1)
                .padding(.top, 1)
                .contentTransition(.opacity)
                .animation(.smooth(duration: 0.18), value: isActionHovered)
        }
        .padding(.top, 10)
        .padding(.horizontal, 4)
        .frame(width: IslandMetrics.tileWidth, height: IslandMetrics.tileHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isHighlighted ? Color.green.opacity(0.22) : .white.opacity(isHovered ? 0.1 : 0))
        )
        .overlay {
            if model.state == .expanded || model.isDraggingFile {
                MouseInteraction(
                    target: target,
                    model: model,
                    dragFile: item.url,
                    dragImage: thumbnail?.image,
                    onClick: { model.actions?.open(item) },
                    onRightClick: { model.actions?.showMenu(for: item) }
                )
            }
        }
        .overlay(alignment: .topTrailing) {
            if let action, isHovered || isBusy {
                SmartActionButton(action: action, item: item, model: model, isBusy: isBusy)
                    .padding(.top, 5)
                    .padding(.trailing, 4)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.62), value: isHovered)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isBusy)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isPressed)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityAddTraits(.isButton)
    }
}

extension TileView {
    fileprivate func subtitle(action: SmartAction?, isBusy: Bool, isActionHovered: Bool) -> String {
        if let note = model.tileNotes[item.id] { return note }
        if let action, isBusy { return action.busyLabel }
        if let action, isActionHovered { return action.hoverLabel }
        return RelativeDate.string(for: item.dateAdded, now: now)
    }
}

/// The one-click button on archives (extract) and disk images (install).
private struct SmartActionButton: View {
    let action: SmartAction
    let item: DownloadItem
    let model: IslandModel
    let isBusy: Bool

    var body: some View {
        let isHovered = model.hoveredAction == item.id
        let isPressed = model.pressed == .tileAction(item.id)

        ZStack {
            Circle()
                .fill(Color(white: isHovered ? 0.34 : 0.22))
            Circle()
                .strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
            if isBusy {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
            } else {
                Image(systemName: action.symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 24, height: 24)
        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
        .scaleEffect(isPressed ? 0.85 : (isHovered ? 1.12 : 1))
        .overlay {
            if model.state == .expanded && !isBusy {
                MouseInteraction(
                    target: .tileAction(item.id),
                    model: model,
                    onClick: { model.actions?.perform(action, on: item) },
                    onHover: { inside in
                        if inside {
                            model.hoveredAction = item.id
                        } else if model.hoveredAction == item.id {
                            model.hoveredAction = nil
                        }
                    }
                )
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isHovered)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isPressed)
        .accessibilityLabel(action.menuTitle)
    }
}

private struct ThumbnailView: View {
    let thumbnail: Thumbnail?

    var body: some View {
        ZStack {
            if let thumbnail {
                if thumbnail.isIcon {
                    Image(nsImage: thumbnail.image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .transition(.opacity)
                } else {
                    Image(nsImage: thumbnail.image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                        .padding(4)
                        .transition(.opacity)
                }
            }
        }
        .animation(.smooth(duration: 0.25), value: thumbnail?.isIcon)
    }
}

private struct PlaceholderView: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.white.opacity(0.3))
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.bottom, 8)
    }
}

private struct AccessDeniedView: View {
    let model: IslandModel

    var body: some View {
        let isHovered = model.hovered == .accessButton
        VStack(spacing: 6) {
            Text("QuickFolder can’t see “\(model.folderName)”")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text("Allow access in Privacy & Security › Files & Folders.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
            Text("Open System Settings")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(.white.opacity(isHovered ? 0.24 : 0.16)))
                .overlay {
                    if model.state == .expanded {
                        MouseInteraction(target: .accessButton, model: model) {
                            model.actions?.openPrivacySettings()
                        }
                    }
                }
                .padding(.top, 6)
                .animation(.smooth(duration: 0.18), value: isHovered)
        }
        .padding(.bottom, 8)
    }
}

// MARK: - Progress

/// A ring that fills as a download progresses, or spins while the total is unknown.
private struct ProgressRing: View {
    let fraction: Double?
    var lineWidth: CGFloat = 2.5
    /// Spinning only while visible keeps the app idle otherwise.
    var isAnimating = true

    private static let blue = Color(red: 0.04, green: 0.52, blue: 1.0)

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.18), lineWidth: lineWidth)
            if let fraction {
                Circle()
                    .trim(from: 0, to: max(0.03, fraction))
                    .stroke(Self.blue, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth(duration: 0.35), value: fraction)
            } else {
                TimelineView(.animation(paused: !isAnimating)) { context in
                    let turns = context.date.timeIntervalSinceReferenceDate / 1.1
                    Circle()
                        .trim(from: 0, to: 0.28)
                        .stroke(Self.blue, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(turns.truncatingRemainder(dividingBy: 1) * 360))
                }
            }
        }
    }
}

/// The notch's wings while something is in progress: a ring on the left,
/// the percentage (or what's happening) on the right.
private struct ActivityWings: View {
    let model: IslandModel

    var body: some View {
        let activities = model.activities
        let known = activities.compactMap(\.fraction)
        let fraction: Double? = known.count == activities.count && !known.isEmpty
            ? known.reduce(0, +) / Double(known.count)
            : nil

        HStack(spacing: 0) {
            ProgressRing(fraction: fraction, lineWidth: 2.5, isAnimating: true)
                .frame(width: 15, height: 15)
                .frame(width: IslandMetrics.activityWing)

            Spacer(minLength: 0)

            Group {
                if let fraction {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .contentTransition(.numericText(value: fraction))
                        .animation(.smooth(duration: 0.3), value: fraction)
                } else {
                    Image(systemName: symbol(for: activities.first?.kind))
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .frame(width: IslandMetrics.activityWing)
            .overlay(alignment: .topTrailing) {
                if activities.count > 1 {
                    Text("\(activities.count)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 3.5)
                        .background(Capsule().fill(.white))
                        .offset(x: -6, y: 4)
                }
            }
        }
        .padding(.horizontal, 6)
    }

    private func symbol(for kind: Activity.Kind?) -> String {
        switch kind {
        case .extract: "archivebox.fill"
        case .install: "arrow.down.app.fill"
        default: "arrow.down"
        }
    }
}

/// A file that's still downloading, at the front of its folder's shelf.
private struct DownloadingTile: View {
    let activity: Activity
    let isAnimating: Bool

    var body: some View {
        let ext = (activity.name as NSString).pathExtension
        let icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)

        VStack(spacing: 0) {
            ZStack {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 44, height: 44)
                    .opacity(0.55)
                ProgressRing(fraction: activity.fraction, lineWidth: 3, isAnimating: isAnimating)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.black.opacity(0.55)))
            }
            .frame(width: 70, height: 54)
            .padding(.bottom, 8)

            Text(DownloadItem.wrappable(activity.name, isFolder: false))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(height: 28, alignment: .top)

            Text(activity.fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "Downloading…")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Color(red: 0.35, green: 0.65, blue: 1.0))
                .padding(.top, 1)
        }
        .padding(.top, 10)
        .padding(.horizontal, 4)
        .frame(width: IslandMetrics.tileWidth, height: IslandMetrics.tileHeight, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Downloading \(activity.name)")
    }
}

// MARK: - Shortcuts deck

private struct DeckView: View {
    let model: IslandModel

    var body: some View {
        let width = model.metrics.rowWidth
        let offset = model.scrollOffset
        let maxOffset = model.maxScrollOffset

        HStack(spacing: IslandMetrics.tileSpacing) {
            ForEach(model.deckKeys) { key in
                DeckKeyTile(key: key, model: model)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            AddKeyTile(model: model)
        }
        .fixedSize()
        .offset(x: -offset)
        .frame(width: width, height: IslandMetrics.tileHeight, alignment: .leading)
        .clipped()
        .mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [offset > 1 ? .clear : .black, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 28)
                Rectangle()
                LinearGradient(colors: [.black, offset < maxOffset - 1 ? .clear : .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 28)
            }
        }
        .padding(.bottom, 4)
    }
}

private struct DeckKeyTile: View {
    let key: DeckKey
    let model: IslandModel

    var body: some View {
        let target = HoverTarget.deckKey(key.id)
        let isHovered = model.hovered == target
        let isPressed = model.pressed == target
        let result = model.deckResults[key.id]
        let appPath: String? = if case .app(let path) = key.action { path } else { nil }

        VStack(spacing: 0) {
            DeckKeyFace(symbol: key.symbol, color: key.color, appPath: appPath, size: 52)
                .overlay {
                    if let result {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(.black.opacity(0.45))
                            Image(systemName: result ? "checkmark" : "xmark")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.7)))
                    }
                }
                .shadow(color: key.color.base.opacity(isHovered ? 0.55 : 0), radius: 10, y: 2)
                .scaleEffect(isPressed ? 0.88 : (isHovered ? 1.07 : 1))
                .frame(width: 70, height: 54)
                .padding(.bottom, 8)

            Text(key.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(height: 28, alignment: .top)

            Text(key.action.kindLabel)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.42))
                .lineLimit(1)
                .padding(.top, 1)
        }
        .padding(.top, 10)
        .padding(.horizontal, 4)
        .frame(width: IslandMetrics.tileWidth, height: IslandMetrics.tileHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(isHovered ? 0.08 : 0))
        )
        .overlay {
            if model.state == .expanded {
                MouseInteraction(
                    target: target,
                    model: model,
                    onClick: { model.actions?.run(key) },
                    onRightClick: { model.actions?.showMenu(for: key) }
                )
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.62), value: isHovered)
        .animation(.spring(response: 0.18, dampingFraction: 0.55), value: isPressed)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: result)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(key.title)
        .accessibilityAddTraits(.isButton)
    }
}

private struct AddKeyTile: View {
    let model: IslandModel

    var body: some View {
        let isHovered = model.hovered == .addDeckKey
        let isPressed = model.pressed == .addDeckKey

        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(isHovered ? 0.5 : 0.25), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .overlay(
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white.opacity(isHovered ? 0.9 : 0.5))
                )
                .frame(width: 52, height: 52)
                .scaleEffect(isPressed ? 0.88 : (isHovered ? 1.05 : 1))
                .frame(width: 70, height: 54)
                .padding(.bottom, 8)

            Text("Add")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .frame(height: 28, alignment: .top)
        }
        .padding(.top, 10)
        .frame(width: IslandMetrics.tileWidth, height: IslandMetrics.tileHeight, alignment: .top)
        .overlay {
            if model.state == .expanded {
                MouseInteraction(target: .addDeckKey, model: model) { model.actions?.editKey(nil) }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.62), value: isHovered)
        .animation(.spring(response: 0.18, dampingFraction: 0.55), value: isPressed)
        .accessibilityLabel("Add Shortcut")
    }
}

// MARK: - Peek

private struct PeekView: View {
    let model: IslandModel

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: model.metrics.notchHeight)
            Group {
                switch model.peek {
                case .download(let item, _, let label):
                    DownloadPeek(item: item, label: label, model: model)
                case .message(let title, let subtitle, let symbol):
                    MessagePeek(title: title, subtitle: subtitle, symbol: symbol)
                case nil:
                    Color.clear
                }
            }
            .padding(.horizontal, 18)
            .frame(maxHeight: .infinity)
            .padding(.bottom, 4)
        }
    }
}

private struct DownloadPeek: View {
    let item: DownloadItem
    let label: String
    let model: IslandModel

    var body: some View {
        // Results like an installed app aren't in the thumbnail cache.
        let thumbnail = model.thumbnails.thumbnail(for: item)
            ?? Thumbnail(image: NSWorkspace.shared.icon(forFile: item.url.path), isIcon: true)
        HStack(spacing: 11) {
            ThumbnailView(thumbnail: thumbnail)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 20, weight: .medium))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color(red: 0.2, green: 0.78, blue: 0.35))
                .symbolEffect(.bounce, value: item.id)
        }
        .contentShape(Rectangle())
        .overlay {
            if model.state == .peek {
                MouseInteraction(
                    target: .peek,
                    model: model,
                    dragFile: item.url,
                    dragImage: thumbnail.image,
                    onClick: { model.actions?.open(item) },
                    onRightClick: { model.actions?.showMenu(for: item) }
                )
            }
        }
    }

    private var subtitle: String {
        guard let size = item.size else { return label }
        return "\(label) · " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

private struct MessagePeek: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Text

extension DownloadItem {
    /// The file name with line-break opportunities before the extension and
    /// after separators, so "Report.pdf" wraps as "Report / .pdf" instead of
    /// splitting a word in the middle.
    var wrappableName: String { Self.wrappable(name, isFolder: isFolder) }

    static func wrappable(_ name: String, isFolder: Bool) -> String {
        let zeroWidthSpace = "\u{200B}"
        let ext = isFolder ? "" : (name as NSString).pathExtension
        var base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        for separator in ["_", "-"] {
            base = base.replacingOccurrences(of: separator, with: separator + zeroWidthSpace)
        }
        return ext.isEmpty ? base : base + zeroWidthSpace + "." + ext
    }
}

// MARK: - Dates

enum RelativeDate {
    static func string(for date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        let calendar = Calendar.current
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if seconds < 6 * 86_400 { return date.formatted(.dateTime.weekday(.wide)) }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }
}
