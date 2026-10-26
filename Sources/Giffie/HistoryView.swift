import AppKit
import GiffieCore
import SwiftUI

struct HistoryActions {
    var record: () -> Void
    var openSettings: () -> Void
    var quit: () -> Void
}

/// Content of the menu bar popover: a Record button and the recent GIFs,
/// each of which can be dragged into any app.
@MainActor
struct HistoryView: View {
    @ObservedObject var model: HistoryModel
    @ObservedObject var settings: AppSettings
    let actions: HistoryActions

    var body: some View {
        VStack(spacing: 0) {
            header
            if let notice = model.notice {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                    Text(notice)
                    Spacer()
                    Button {
                        model.notice = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.15))
            }
            Divider()
            if model.items.isEmpty {
                emptyState
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(width: 380, height: 500)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("Giffie").font(.headline)
                Text(settings.recordingSummary)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(action: actions.record) {
                HStack(spacing: 6) {
                    Image(systemName: "record.circle")
                    Text("Record")
                    if let hotKey = settings.hotKey {
                        Text(hotKey.displayString)
                            .font(.caption)
                            .opacity(0.8)
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .help("Select an area of the screen to record")
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No GIFs yet").font(.title3.weight(.semibold))
            Text("Click Record, drag over the part of the screen you want, then press Space to start.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .frame(maxWidth: 280)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        VStack(spacing: 0) {
            Text("Drag a GIF into any app · double-click to open")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(model.items) { item in
                        GIFRow(item: item, isHighlighted: item.url == model.highlightedURL, model: model)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                model.openFolder()
            } label: {
                Label(model.folder?.lastPathComponent ?? "Choose folder…", systemImage: "folder")
                    .lineLimit(1)
            }
            .buttonStyle(.borderless)
            .help(model.folder?.path ?? "")
            Spacer()
            Button(action: actions.openSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
            Button(action: actions.quit) {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Quit Giffie")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

@MainActor
private struct GIFRow: View {
    let item: GIFItem
    let isHighlighted: Bool
    let model: HistoryModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 10) {
                GIFThumbnail(url: item.url, placeholder: item.thumbnail, animating: hovering || isHighlighted)
                    .frame(width: 96, height: 60)
                    .background(Color.black.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(details)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(relativeDate)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .overlay(
                DragSource(
                    url: item.url,
                    image: item.thumbnail,
                    onDoubleClick: { model.open(item) },
                    menu: { [model, item] in
                        let menu = NSMenu()
                        menu.addItem(ActionMenuItem("Open") { model.open(item) })
                        menu.addItem(ActionMenuItem("Show in Finder") { model.reveal(item) })
                        menu.addItem(ActionMenuItem("Copy") { model.copy(item.url) })
                        menu.addItem(.separator())
                        menu.addItem(ActionMenuItem("Move to Trash") { model.trash(item) })
                        return menu
                    }
                )
            )
            VStack(spacing: 6) {
                iconButton("doc.on.doc", help: "Copy GIF") { model.copy(item.url) }
                iconButton("folder", help: "Show in Finder") { model.reveal(item) }
                iconButton("trash", help: "Move to Trash") { model.trash(item) }
            }
            .opacity(hovering ? 1 : 0.35)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHighlighted ? Color.accentColor.opacity(0.16) : (hovering ? Color.primary.opacity(0.06) : Color.clear))
        )
        .onHover { hovering = $0 }
    }

    private var details: String {
        var parts = ["\(item.pixelWidth)×\(item.pixelHeight)", GiffieFormat.byteCount(item.fileSize)]
        if item.frameCount > 1 { parts.insert(GiffieFormat.duration(item.duration), at: 1) }
        return parts.joined(separator: " · ")
    }

    private var relativeDate: String {
        let now = Date()
        if abs(item.date.timeIntervalSince(now)) < 60 { return "Just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: min(item.date, now), relativeTo: now)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

/// Shows the first frame, and plays the GIF while `animating` is true.
@MainActor
private struct GIFThumbnail: NSViewRepresentable {
    let url: URL
    let placeholder: NSImage?
    let animating: Bool

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.isEditable = false
        view.unregisterDraggedTypes()
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        if animating {
            if view.animates == false || view.image === placeholder {
                view.image = NSImage(byReferencing: url)
                view.animates = true
            }
        } else if view.animates || view.image == nil {
            view.animates = false
            view.image = placeholder
        }
    }
}

/// Transparent AppKit view that turns its area into a file drag source.
@MainActor
private struct DragSource: NSViewRepresentable {
    let url: URL
    let image: NSImage?
    let onDoubleClick: () -> Void
    let menu: () -> NSMenu

    func makeNSView(context: Context) -> DragSourceView {
        DragSourceView()
    }

    func updateNSView(_ view: DragSourceView, context: Context) {
        view.url = url
        view.dragImage = image
        view.onDoubleClick = onDoubleClick
        view.menuProvider = menu
    }
}

final class DragSourceView: NSView, NSDraggingSource {
    var url: URL?
    var dragImage: NSImage?
    var onDoubleClick: (() -> Void)?
    var menuProvider: (() -> NSMenu)?
    private var mouseDownEvent: NSEvent?
    private var dragStarted = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        dragStarted = false
        if event.clickCount == 2 {
            onDoubleClick?()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted, let url = url, let down = mouseDownEvent else { return }
        let start = down.locationInWindow, now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) > 4 else { return }
        dragStarted = true

        let image = dragImage ?? NSWorkspace.shared.icon(forFile: url.path)
        var size = image.size
        let maxSide: CGFloat = 128
        if size.width > 0, size.height > 0 {
            let scale = min(maxSide / size.width, maxSide / size.height, 1)
            size = NSSize(width: size.width * scale, height: size.height * scale)
        } else {
            size = NSSize(width: 64, height: 64)
        }
        let location = convert(down.locationInWindow, from: nil)
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(NSRect(x: location.x - size.width / 2, y: location.y - size.height / 2,
                                     width: size.width, height: size.height),
                              contents: image)
        let session = beginDraggingSession(with: [item], event: down, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
        dragStarted = false
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Always copy, so dragging to Finder never moves the file out of the GIF folder.
        context == .outsideApplication ? .copy : []
    }
}
