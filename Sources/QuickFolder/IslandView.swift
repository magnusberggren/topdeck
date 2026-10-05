import SwiftUI

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
        }
        .frame(width: shape.size.width, height: shape.size.height, alignment: .top)
        .background(notch.fill(Color.black))
        .clipShape(notch)
        // A tight contact shadow plus a wide ambient one. Both fit inside the
        // window's padding so the blur never gets cut off at the window edge.
        .shadow(color: .black.opacity(model.state == .collapsed ? 0 : 0.28), radius: 4, y: 2)
        .shadow(color: .black.opacity(model.state == .collapsed ? 0 : 0.32), radius: model.state == .expanded ? 22 : 14, y: 10)
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
            switch model.access {
            case .denied:
                AccessDeniedView(model: model)
            case .missing:
                PlaceholderView(symbol: "questionmark.folder", text: "“\(model.folderName)” can’t be found")
            case .ok:
                if model.items.isEmpty {
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
        HStack(spacing: 2) {
            ZStack(alignment: .leading) {
                Text(model.folderName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .id(model.folderName)
                    .transition(.push(from: model.pageEdge).combined(with: .opacity))
            }
            .clipped()

            Spacer(minLength: model.metrics.notchRect.width + 24)

            HeaderButton(model: model, target: .openFolder, symbol: "folder", label: "Open in Finder") {
                model.actions?.openFolder()
            }
            HeaderButton(model: model, target: .settings, symbol: "ellipsis", label: "Options") {
                model.actions?.showSettingsMenu()
            }
        }
        .padding(.leading, 22)
        .padding(.trailing, 14)
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
        let canExtract = Archive.canExtract(item)
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

            Text(subtitle(isBusy: isBusy, isActionHovered: isActionHovered))
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
            if canExtract && (isHovered || isBusy) {
                ExtractButton(item: item, model: model, isBusy: isBusy)
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
    fileprivate func subtitle(isBusy: Bool, isActionHovered: Bool) -> String {
        if let note = model.tileNotes[item.id] { return note }
        if isBusy { return "Extracting…" }
        if isActionHovered { return "Extract & Trash" }
        return RelativeDate.string(for: item.dateAdded, now: now)
    }
}

/// Shown on archives when hovered: unpacks next to the archive, then moves
/// the archive to the Trash.
private struct ExtractButton: View {
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
                Image(systemName: "archivebox.fill")
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
                    onClick: { model.actions?.extract(item) },
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
        .accessibilityLabel("Extract and move archive to Trash")
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
        let thumbnail = model.thumbnails.thumbnail(for: item)
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
                    dragImage: thumbnail?.image,
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
    var wrappableName: String {
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
