import SwiftUI

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
        Button {
            model.openGroup = nil
            Apps.open(id)
        } label: {
            VStack(spacing: 2) {
                Image(nsImage: Apps.icon(id))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
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
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(Apps.name(id))
        .contextMenu { AppMenu(model: model, id: id, running: running, placed: placed, group: group) }
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
        Button {
            isOpen.wrappedValue.toggle()
        } label: {
            VStack(spacing: 2) {
                GroupIcon(apps: apps, size: size)
                    .scaleEffect(hovering ? 1.08 : 1, anchor: .bottom)
                    .animation(.easeOut(duration: 0.12), value: hovering)
                RunningDot(visible: anyRunning)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(name)
        // Where the group panel should point; read by BarController, not rendered.
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { model.groupTileMidX[name] = geo.frame(in: .global).midX }
                .onChange(of: geo.frame(in: .global).midX) { _, x in model.groupTileMidX[name] = x }
        })
        .contextMenu {
            Button("Rename…") {
                if let newName = Prompt.text(title: "Rename group", message: "New name for “\(name)”:",
                                             initial: name, existing: model.config.groupNames) {
                    model.edit { $0.renameGroup(name, to: newName) }
                }
            }
            Button("Ungroup") { model.edit { $0.ungroup(name) } }
        }
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
    private var apps: [String] {
        for case .group(let g) in model.config.items where g.name == name { return g.apps }
        return []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(name).font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(size + 28), spacing: 8), count: min(4, max(1, apps.count))),
                      spacing: 10) {
                ForEach(apps, id: \.self) { id in
                    AppTile(model: model, id: id, running: model.isRunning(id), placed: true,
                            group: name, size: size, showsName: true)
                }
            }
        }
        .padding(14)
    }
}
