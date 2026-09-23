import SwiftUI
import UniformTypeIdentifiers

struct BarView: View {
    @ObservedObject var model: FrostyModel

    private var size: CGFloat { CGFloat(model.config.iconSize) }

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            ForEach(model.entries) { entry in
                switch entry {
                case .app(let id, let running, let placed):
                    AppTile(model: model, id: id, running: running, placed: placed, group: nil, size: size)
                case .group(let name, let apps, let anyRunning):
                    GroupTile(model: model, name: name, apps: apps, anyRunning: anyRunning, size: size)
                case .openApps(let apps):
                    GroupTile(model: model, name: BarEntry.openAppsKey, apps: apps, anyRunning: true, size: size)
                case .separator:
                    ResizeDivider(model: model, size: size)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .fixedSize()
    }
}

/// The divider doubles as the size handle, as in the real Dock: drag it up to
/// grow the icons, down to shrink them.
private struct ResizeDivider: View {
    @ObservedObject var model: FrostyModel
    let size: CGFloat

    /// Pointer height and icon size when the drag began. Measured in screen
    /// coordinates, because the bar itself grows and moves under the pointer.
    @State private var start: (mouseY: CGFloat, size: Double)?

    var body: some View {
        Rectangle()
            .fill(.primary.opacity(0.25))
            .frame(width: 1, height: size * 0.8)
            .padding(.horizontal, 6)          // a wider grab area than the 1pt line
            .padding(.top, size * 0.1)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { _ in
                    let y = NSEvent.mouseLocation.y
                    if start == nil { start = (y, model.config.iconSize) }
                    if let start { model.setIconSize(start.size + Double(y - start.mouseY), persist: false) }
                }
                .onEnded { _ in
                    start = nil
                    model.setIconSize(model.config.iconSize, persist: true)
                })
    }
}

/// Small dot under an icon, as in the real Dock.
private struct RunningDot: View {
    let visible: Bool
    var body: some View {
        Circle().fill(.primary.opacity(0.8)).frame(width: 4, height: 4).opacity(visible ? 1 : 0)
    }
}

struct AppTile: View {
    @ObservedObject var model: FrostyModel
    let id: String
    let running: Bool
    let placed: Bool
    /// The group this tile sits in, when it is shown inside a group popover.
    let group: String?
    let size: CGFloat
    var showsName = false

    @State private var hovering = false

    var body: some View {
        // A tap, not a Button: a Button keeps the mouse to itself, so `onDrag` never began.
        VStack(spacing: 2) {
                Image(nsImage: Apps.icon(id))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .overlay(alignment: .topTrailing) { BadgeView(text: model.badge(id), size: size) }
                    .scaleEffect(hovering ? 1.08 : 1, anchor: .bottom)
                    .animation(.easeOut(duration: 0.12), value: hovering)
                if showsName {
                    Text(Apps.name(id))
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .frame(width: size + 24)
                }
                RunningDot(visible: running)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.openGroup = nil
            Apps.open(id)
        }
        .accessibilityAddTraits(.isButton)
        .onHover { hovering = $0 }
        .help(Apps.name(id))
        .contextMenu { AppMenu(model: model, id: id, running: running, placed: placed, group: group) }
        .background(TileFrameReporter(model: model, id: id))
        .overlay { DropMarker(model: model, target: .app(id)) }
        .onDrag { TileDrop.begin(.app(id), model: model) }
        // Loose running apps can be dragged in to pin them, but aren't a place to drop.
        .onDrop(of: [TileDrop.type], delegate: TileDrop(model: model, target: .app(id), enabled: placed,
                                                         width: showsName ? size + 24 : size, acceptsInto: false))
    }
}

struct AppMenu: View {
    @ObservedObject var model: FrostyModel
    let id: String
    let running: Bool
    let placed: Bool
    let group: String?

    var body: some View {
        if running {
            Button("Hide") { Apps.hide(id) }
            Button("Quit") { Apps.quit(id) }
            Divider()
        }
        if placed {
            if let group {
                Button("Remove from “\(group)”") { model.edit { $0.removeFromGroup(id) } }
            }
            Button("Remove from Frosty") { model.edit { $0.unpin(id) } }
        } else {
            Button("Keep in Frosty") { model.edit { $0.pin(id) } }
        }
        Menu("Move to Group") {
            ForEach(model.config.groupNames.filter { $0 != group }, id: \.self) { name in
                Button(name) { model.edit { $0.move(id, toGroup: name) } }
            }
            if model.config.groupNames.contains(where: { $0 != group }) { Divider() }
            Button("New Group…") {
                if let name = Prompt.text(title: "New group", message: "Name for the group holding \(Apps.name(id)):",
                                          existing: model.config.groupNames) {
                    model.edit { $0.move(id, toGroup: name) }
                }
            }
        }
        Divider()
        Button("Show in Finder") { Apps.revealInFinder(id) }
        if model.config.showBadges {
            Button(model.config.hiddenBadges.contains(id) ? "Show Badge" : "Hide Badge") {
                model.edit { $0.toggleBadge(id) }
            }
        }
        Divider()
        KeepOpenToggle(model: model)
    }
}

/// Switches auto-hide off and on from any tile's menu.
struct KeepOpenToggle: View {
    @ObservedObject var model: FrostyModel
    var body: some View {
        Toggle("Keep Frosty Open", isOn: Binding(get: { !model.config.autoHide },
                                                 set: { open in model.edit { $0.autoHide = !open } }))
    }
}

struct GroupTile: View {
    @ObservedObject var model: FrostyModel
    let name: String
    let apps: [String]
    let anyRunning: Bool
    let size: CGFloat

    @State private var hovering = false

    private var isOpen: Binding<Bool> {
        Binding(get: { model.openGroup == name },
                set: { model.openGroup = $0 ? name : (model.openGroup == name ? nil : model.openGroup) })
    }

    var body: some View {
        VStack(spacing: 2) {
                GroupIcon(apps: apps, size: size)
                    .overlay(alignment: .topTrailing) { BadgeView(text: model.groupBadge(apps), size: size) }
                    .scaleEffect(hovering ? 1.08 : 1, anchor: .bottom)
                    .animation(.easeOut(duration: 0.12), value: hovering)
                RunningDot(visible: anyRunning)
        }
        .contentShape(Rectangle())
        .onTapGesture { isOpen.wrappedValue.toggle() }
        .accessibilityAddTraits(.isButton)
        .onHover { hovering = $0 }
        .help(isOpenApps ? BarEntry.openAppsTitle : name)
        // Where the group panel should point; read by BarController, not rendered.
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { model.groupTileMidX[name] = geo.frame(in: .global).midX }
                .onChange(of: geo.frame(in: .global).midX) { _, x in model.groupTileMidX[name] = x }
        })
        .contextMenu {
            if isOpenApps {
                Button("Show Open Apps Separately") { model.edit { $0.groupUnpinned = false } }
            } else {
                userGroupMenu
            }
            Divider()
            KeepOpenToggle(model: model)
        }
        .overlay { DropMarker(model: model, target: .group(name)) }
        .onDrag { isOpenApps ? NSItemProvider() : TileDrop.begin(.group(name), model: model) }
        .onDrop(of: [TileDrop.type], delegate: TileDrop(model: model, target: .group(name), enabled: !isOpenApps,
                                                         width: size, acceptsInto: true))
    }

    private var isOpenApps: Bool { name == BarEntry.openAppsKey }

    @ViewBuilder private var userGroupMenu: some View {
            Button("Rename…") {
                if let newName = Prompt.text(title: "Rename group", message: "New name for “\(name)”:",
                                             initial: name, existing: model.config.groupNames) {
                    model.edit { $0.renameGroup(name, to: newName) }
                }
            }
            Button("Ungroup") { model.edit { $0.ungroup(name) } }
    }
}

/// A folder-style tile: up to four member icons in a 2×2 grid.
struct GroupIcon: View {
    let apps: [String]
    let size: CGFloat

    var body: some View {
        let cell = size * 0.36
        let shown = Array(apps.prefix(4))
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(.primary.opacity(0.12))
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .strokeBorder(.primary.opacity(0.15))
            Grid(horizontalSpacing: size * 0.06, verticalSpacing: size * 0.06) {
                ForEach(0..<2, id: \.self) { row in
                    GridRow {
                        ForEach(0..<2, id: \.self) { col in
                            let i = row * 2 + col
                            if i < shown.count {
                                Image(nsImage: Apps.icon(shown[i])).resizable().frame(width: cell, height: cell)
                            } else {
                                Color.clear.frame(width: cell, height: cell)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: size, height: size)
    }
}

struct GroupGrid: View {
    @ObservedObject var model: FrostyModel
    let name: String

    private var size: CGFloat { CGFloat(model.config.iconSize) }
    private var isOpenApps: Bool { name == BarEntry.openAppsKey }
    private var apps: [String] {
        if isOpenApps {
            for case .openApps(let apps) in model.entries { return apps }
            return []
        }
        for case .group(let g) in model.config.items where g.name == name { return g.apps }
        return []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isOpenApps ? BarEntry.openAppsTitle : name).font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(size + 28), spacing: 8), count: min(4, max(1, apps.count))),
                      spacing: 10) {
                ForEach(apps, id: \.self) { id in
                    AppTile(model: model, id: id, running: model.isRunning(id), placed: !isOpenApps,
                            group: isOpenApps ? nil : name, size: size, showsName: true)
                }
            }
        }
        .padding(14)
    }
}

/// A Dock-style count in the icon's top-right corner.
private struct BadgeView: View {
    let text: String?
    let size: CGFloat

    var body: some View {
        if let text {
            Text(text)
                .font(.system(size: max(9, size * 0.24), weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, size * 0.08)
                .frame(minWidth: size * 0.36, minHeight: size * 0.36)
                .background(Capsule().fill(Color.red))
                .offset(x: size * 0.08)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Drag and drop

/// Dropping one tile onto another. The halves of a tile mean before and after
/// it; the middle half of a group tile means into the group.
struct TileDrop: DropDelegate {
    /// Plain text: a private type would need declaring in Info.plist, and an
    /// undeclared one never matches a drop target. The text is a one-off token,
    /// so a text drag from another app is never taken for a tile.
    static let type = UTType.plainText

    let model: FrostyModel
    let target: FrostyConfig.Ref
    let enabled: Bool
    let width: CGFloat
    let acceptsInto: Bool

    static func begin(_ ref: FrostyConfig.Ref, model: FrostyModel) -> NSItemProvider {
        let token = "frosty-tile-" + UUID().uuidString
        model.dragging = ref
        model.dragToken = token
        return NSItemProvider(object: token as NSString)
    }

    private func position(_ info: DropInfo) -> DropHint.Position {
        let x = info.location.x
        if acceptsInto, case .app = model.dragging, x > width * 0.25, x < width * 0.75 { return .into }
        return x < width / 2 ? .before : .after
    }

    func validateDrop(info: DropInfo) -> Bool {
        enabled && model.dragging != nil && model.dragging != target
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let hint = DropHint(target: target, position: position(info))
        if model.dropHint != hint { model.dropHint = hint }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if model.dropHint?.target == target { model.dropHint = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let dragged = model.dragging, let token = model.dragToken,
              let provider = info.itemProviders(for: [Self.type]).first else { return false }
        let position = position(info)
        let (model, target) = (model, target)
        model.dragging = nil
        model.dragToken = nil
        model.dropHint = nil
        _ = provider.loadObject(ofClass: NSString.self) { text, _ in
            DispatchQueue.main.async {
                // `dragging` outlives a drag cancelled outside the bar; the token doesn't match another app's text.
                guard (text as? String) == token else { return }
                model.edit { config in
                    if position == .into, case .app(let id) = dragged, case .group(let name) = target {
                        config.move(id, toGroup: name)
                    } else {
                        config.place(dragged, beside: target, after: position == .after)
                    }
                }
            }
        }
        return true
    }
}

/// Where the dragged tile would land: a bar at the tile's edge, or a ring
/// round a group it would join.
private struct DropMarker: View {
    @ObservedObject var model: FrostyModel
    let target: FrostyConfig.Ref

    var body: some View {
        if let hint = model.dropHint, hint.target == target {
            switch hint.position {
            case .into:
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            case .before, .after:
                HStack {
                    if hint.position == .after { Spacer() }
                    Capsule().fill(Color.accentColor).frame(width: 3)
                        .offset(x: hint.position == .after ? 3.5 : -3.5)
                    if hint.position == .before { Spacer() }
                }
                .allowsHitTesting(false)
            }
        }
    }
}

/// Registers an app tile with the model, so a right-click there can open the
/// app's own Dock menu instead of Frosty's.
private struct TileFrameReporter: NSViewRepresentable {
    let model: FrostyModel
    let id: String

    func makeNSView(context: Context) -> AppTileMarker {
        let marker = AppTileMarker()
        model.appTiles.add(marker)
        return marker
    }

    func updateNSView(_ marker: AppTileMarker, context: Context) { marker.appID = id }
}
