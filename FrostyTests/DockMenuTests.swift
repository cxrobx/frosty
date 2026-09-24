import XCTest

/// Fixtures copied from real Accessibility dumps of Onyx's and Finder's Dock menus.
final class DockMenuTests: XCTestCase {
    private func row(_ y: CGFloat) -> CGRect { CGRect(x: 867, y: y, width: 482, height: 22) }
    private let hidden = CGRect(x: 0, y: 1117, width: 0, height: 0)
    private func raw(_ title: String, _ y: CGFloat, enabled: Bool = true, mark: String = "",
                     mods: Int = 0, children: [RawDockMenuItem] = []) -> RawDockMenuItem {
        RawDockMenuItem(title: title, enabled: enabled, markChar: mark, frame: row(y), cmdModifiers: mods, children: children)
    }
    private func separator(_ y: CGFloat) -> RawDockMenuItem { raw("", y, enabled: false) }

    private var onyx: [RawDockMenuItem] {
        [raw("Open Onyx", 668), separator(690),
         raw("Recent Artifacts", 700, enabled: false), raw("Evals that hold up", 722), separator(744),
         raw("Options", 998, children: [
             RawDockMenuItem(title: "Keep in Dock", enabled: true, markChar: "✓", frame: hidden, cmdModifiers: 0),
             RawDockMenuItem(title: "Open at Login", enabled: true, markChar: "", frame: hidden, cmdModifiers: 0),
             RawDockMenuItem(title: "Show in Finder", enabled: true, markChar: "", frame: hidden, cmdModifiers: 0),
         ]),
         separator(1020),
         raw("Show All Windows", 1031), raw("Hide", 1053), raw("Hide Others", 1053, mods: 10),
         raw("Quit", 1075), raw("Force Quit", 1075, mods: 10)]
    }

    func testHeadersSeparatorsAndAlternates() {
        let items = DockMenu.items(from: onyx)
        XCTAssertEqual(items.map(\.kind), [.action, .separator, .header, .action, .separator,
                                           .action, .separator, .action, .action, .action, .action, .action])
        XCTAssertEqual(items[2].title, "Recent Artifacts")
        XCTAssertEqual(items.first { $0.title == "Hide Others" }?.alternate, [.option])
        XCTAssertEqual(items.first { $0.title == "Force Quit" }?.alternate, [.option])
        XCTAssertNil(items.first { $0.title == "Hide" }?.alternate)
    }

    func testOptionsDropsKeepInDockAndKeepsTheRest() {
        let options = DockMenu.items(from: onyx).first { $0.title == "Options" }
        XCTAssertEqual(options?.children.map(\.title), ["Open at Login", "Show in Finder"])
        // Closed-submenu items share an empty frame; none may read as an alternate.
        XCTAssertTrue(options?.children.allSatisfy { $0.alternate == nil } ?? false)
    }

    func testCheckmarkCarriesOver() {
        let raw = [RawDockMenuItem(title: "Open at Login", enabled: true, markChar: "✓", frame: row(0), cmdModifiers: 0)]
        XCTAssertTrue(DockMenu.items(from: raw)[0].checked)
    }

    func testCommandHeldAlternate() {
        // Bit 8 clear means Command is part of the combination.
        let items = DockMenu.items(from: [raw("A", 10), raw("B", 10, mods: 2)])
        XCTAssertEqual(items[1].alternate, [.option, .command])
    }

    func testNoSeparatorLeftAtTheEndsOrDoubled() {
        let items = DockMenu.items(from: [separator(0), raw("A", 10), separator(20), separator(30), raw("B", 40), separator(50)])
        XCTAssertEqual(items.map(\.kind), [.action, .separator, .action])
    }

    func testIndexPathFindsItemsByTitle() {
        XCTAssertEqual(DockMenu.indexPath(of: ["Hide"], in: onyx), [8])
        XCTAssertEqual(DockMenu.indexPath(of: ["Options", "Show in Finder"], in: onyx), [5, 2])
        XCTAssertNil(DockMenu.indexPath(of: ["A file that is gone"], in: onyx))
    }

    func testLocalActions() {
        XCTAssertEqual(DockMenu.local(["Quit"]), .quit)
        XCTAssertEqual(DockMenu.local(["Options", "Show in Finder"]), .showInFinder)
        XCTAssertNil(DockMenu.local(["Evals that hold up"]))
        XCTAssertNil(DockMenu.local(["Show All Windows"]))
    }

    func testStoreRoundTripsAndSurvivesABadFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("dock-menus.json")
        let store = DockMenuStore(url: url)
        XCTAssertEqual(store.load(), [:])
        let menus = ["com.onyx": DockMenu.items(from: onyx)]
        store.save(menus)
        XCTAssertEqual(store.load(), menus)
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(store.load(), [:])
    }
}
