import XCTest

final class BarLayoutTests: XCTestCase {
    let config = FrostyConfig(items: [
        .app("finder"),
        .group(.init(name: "Music", apps: ["reaper", "fl"])),
        .app("safari"),
    ])

    func testUnpinnedRunningAppsCollectIntoOpenApps() {
        let entries = BarLayout.entries(config: config, running: ["finder", "slack", "zen", "slack"])
        XCTAssertEqual(Array(entries.suffix(2)), [.separator, .openApps(apps: ["slack", "zen"])])
    }

    func testASingleUnpinnedAppStaysLoose() {
        let entries = BarLayout.entries(config: config, running: ["slack"])
        XCTAssertEqual(entries.last, .app(id: "slack", running: true, placed: false))
    }

    func testPlacedFirstThenLooseRunningAfterSeparator() {
        var config = config
        config.groupUnpinned = false
        let entries = BarLayout.entries(config: config, running: ["finder", "slack", "zen"])
        XCTAssertEqual(entries, [
            .app(id: "finder", running: true, placed: true),
            .group(name: "Music", apps: ["reaper", "fl"], anyRunning: false),
            .app(id: "safari", running: false, placed: true),
            .separator,
            .app(id: "slack", running: true, placed: false),
            .app(id: "zen", running: true, placed: false),
        ])
    }

    func testGroupedAppIsNeverShownLoose() {
        let entries = BarLayout.entries(config: config, running: ["reaper"])
        XCTAssertFalse(entries.contains(.app(id: "reaper", running: true, placed: false)))
        XCTAssertEqual(entries[1], .group(name: "Music", apps: ["reaper", "fl"], anyRunning: true))
        XCTAssertFalse(entries.contains(.separator))
    }

    func testNoSeparatorWhenNothingIsPlaced() {
        let entries = BarLayout.entries(config: FrostyConfig(items: []), running: ["a", "a", "b"])
        XCTAssertEqual(entries, [.openApps(apps: ["a", "b"])])
    }

    // Two displays side by side, and a wider third above the left one.
    let displays = [CGRect(x: 0, y: 0, width: 1512, height: 982),
                    CGRect(x: 1512, y: -200, width: 2560, height: 1440),
                    CGRect(x: -400, y: 982, width: 1912, height: 1080)]

    func testBottomEdgeFindsTheDisplayUnderThePointer() {
        XCTAssertEqual(BarLayout.bottomEdgeDisplay(at: CGPoint(x: 700, y: 0), displays: displays), 0)
        XCTAssertEqual(BarLayout.bottomEdgeDisplay(at: CGPoint(x: 2000, y: -200), displays: displays), 1)
    }

    func testAwayFromTheBottomEdgeIsNoDisplay() {
        XCTAssertNil(BarLayout.bottomEdgeDisplay(at: CGPoint(x: 700, y: 400), displays: displays))
        XCTAssertNil(BarLayout.bottomEdgeDisplay(at: CGPoint(x: 2000, y: 0), displays: displays))
    }

    func testAnEdgeWithADisplayBelowIsNotTheBottom() {
        XCTAssertNil(BarLayout.bottomEdgeDisplay(at: CGPoint(x: 700, y: 982), displays: displays))
        // Past the lower display's left side, the upper one's edge is a real bottom.
        XCTAssertEqual(BarLayout.bottomEdgeDisplay(at: CGPoint(x: -200, y: 982), displays: displays), 2)
    }
}

final class ConfigEditTests: XCTestCase {
    func testPinIgnoresAlreadyPlacedApps() {
        var c = FrostyConfig(items: [.group(.init(name: "G", apps: ["a"]))])
        c.pin("a")
        c.pin("b")
        XCTAssertEqual(c.items, [.group(.init(name: "G", apps: ["a"])), .app("b")])
    }

    func testUnpinLastAppDropsTheGroup() {
        var c = FrostyConfig(items: [.app("x"), .group(.init(name: "G", apps: ["a"]))])
        c.unpin("a")
        XCTAssertEqual(c.items, [.app("x")])
    }

    func testMoveToNewGroupKeepsThePosition() {
        var c = FrostyConfig(items: [.app("a"), .app("b"), .app("c")])
        c.move("b", toGroup: "New")
        XCTAssertEqual(c.items, [.app("a"), .group(.init(name: "New", apps: ["b"])), .app("c")])
        c.move("c", toGroup: "New")
        XCTAssertEqual(c.items, [.app("a"), .group(.init(name: "New", apps: ["b", "c"]))])
    }

    func testMoveUnplacedRunningAppIntoGroup() {
        var c = FrostyConfig(items: [.group(.init(name: "G", apps: ["a"]))])
        c.move("z", toGroup: "G")
        XCTAssertEqual(c.items, [.group(.init(name: "G", apps: ["a", "z"]))])
    }

    func testRemoveFromGroupPinsRightAfterIt() {
        var c = FrostyConfig(items: [.group(.init(name: "G", apps: ["a", "b"])), .app("c")])
        c.removeFromGroup("a")
        XCTAssertEqual(c.items, [.group(.init(name: "G", apps: ["b"])), .app("a"), .app("c")])
        c.removeFromGroup("b")
        XCTAssertEqual(c.items, [.app("b"), .app("a"), .app("c")])
    }

    func testUngroupInlinesApps() {
        var c = FrostyConfig(items: [.app("x"), .group(.init(name: "G", apps: ["a", "b"])), .app("y")])
        c.ungroup("G")
        XCTAssertEqual(c.items, [.app("x"), .app("a"), .app("b"), .app("y")])
    }

    func testRenameRejectsBlankAndDuplicateNames() {
        var c = FrostyConfig(items: [.group(.init(name: "A", apps: ["a"])), .group(.init(name: "B", apps: ["b"]))])
        c.renameGroup("A", to: "  ")
        c.renameGroup("A", to: "B")
        XCTAssertEqual(c.groupNames, ["A", "B"])
        c.renameGroup("A", to: " Tools ")
        XCTAssertEqual(c.groupNames, ["Tools", "B"])
    }

    func testHandWrittenJSONDecodesAndRoundTrips() throws {
        let json = #"{"items":[{"app":"com.apple.finder"},{"group":"Music","apps":["a","b"]}]}"#
        let c = try JSONDecoder().decode(FrostyConfig.self, from: Data(json.utf8))
        XCTAssertEqual(c.items, [.app("com.apple.finder"), .group(.init(name: "Music", apps: ["a", "b"]))])
        XCTAssertTrue(c.autoHide)
        XCTAssertTrue(c.groupUnpinned, "grouping is on unless the config turns it off")
        XCTAssertEqual(c.iconSize, 48)
        let again = try JSONDecoder().decode(FrostyConfig.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(again, c)
    }

    func testIconOverridesDecodeAndDefaultToEmpty() throws {
        let json = #"{"items":[],"icons":{"md.obsidian":"~/icon.png"}}"#
        let c = try JSONDecoder().decode(FrostyConfig.self, from: Data(json.utf8))
        XCTAssertEqual(c.icons, ["md.obsidian": "~/icon.png"])
        let plain = try JSONDecoder().decode(FrostyConfig.self, from: Data(#"{"items":[]}"#.utf8))
        XCTAssertEqual(plain.icons, [:])
    }

    func testIconSizeIsClampedToTheDockRange() throws {
        XCTAssertEqual(FrostyConfig.clampIconSize(4), 16)
        XCTAssertEqual(FrostyConfig.clampIconSize(300), 128)
        XCTAssertEqual(FrostyConfig.clampIconSize(63.6), 64)
        let c = try JSONDecoder().decode(FrostyConfig.self, from: Data(#"{"items":[],"iconSize":2}"#.utf8))
        XCTAssertEqual(c.iconSize, 16)
    }

    func testBadgeSettingsDefaultOnAndRoundTripSorted() throws {
        let plain = try JSONDecoder().decode(FrostyConfig.self, from: Data(#"{"items":[]}"#.utf8))
        XCTAssertTrue(plain.showBadges)
        XCTAssertEqual(plain.hiddenBadges, [])
        var c = plain
        c.toggleBadge("z")
        c.toggleBadge("a")
        let json = String(decoding: try JSONEncoder().encode(c), as: UTF8.self)
        XCTAssertTrue(json.contains(#""hiddenBadges":["a","z"]"#), json)
        XCTAssertEqual(try JSONDecoder().decode(FrostyConfig.self, from: Data(json.utf8)), c)
        c.toggleBadge("a")
        XCTAssertEqual(c.hiddenBadges, ["z"])
    }

    func testMalformedItemIsRejected() {
        let json = #"{"items":[{"nope":1}]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(FrostyConfig.self, from: Data(json.utf8)))
    }
}

final class DragPlacementTests: XCTestCase {
    let base = FrostyConfig(items: [.app("a"), .group(.init(name: "G", apps: ["g1", "g2"])), .app("b")])

    func testReorderTopLevelApps() {
        var c = base
        c.place(.app("b"), beside: .app("a"), after: false)
        XCTAssertEqual(c.items, [.app("b"), .app("a"), .group(.init(name: "G", apps: ["g1", "g2"]))])
        c.place(.app("b"), beside: .group("G"), after: true)
        XCTAssertEqual(c.items, [.app("a"), .group(.init(name: "G", apps: ["g1", "g2"])), .app("b")])
    }

    func testMoveGroup() {
        var c = base
        c.place(.group("G"), beside: .app("b"), after: true)
        XCTAssertEqual(c.items, [.app("a"), .app("b"), .group(.init(name: "G", apps: ["g1", "g2"]))])
    }

    func testDragOutOfGroupOntoTheBar() {
        var c = base
        c.place(.app("g1"), beside: .app("a"), after: false)
        XCTAssertEqual(c.items, [.app("g1"), .app("a"), .group(.init(name: "G", apps: ["g2"])), .app("b")])
        c.place(.app("g2"), beside: .app("b"), after: true)
        XCTAssertEqual(c.items, [.app("g1"), .app("a"), .app("b"), .app("g2")], "the emptied group goes")
    }

    func testReorderInsideAGroupAndJoinFromTheBar() {
        var c = base
        c.place(.app("g2"), beside: .app("g1"), after: false)
        XCTAssertEqual(c.items[1], .group(.init(name: "G", apps: ["g2", "g1"])))
        c.place(.app("a"), beside: .app("g2"), after: true)
        XCTAssertEqual(c.items, [.group(.init(name: "G", apps: ["g2", "a", "g1"])), .app("b")])
    }

    func testDroppingAnUnplacedAppPinsItThere() {
        var c = base
        c.place(.app("new"), beside: .app("b"), after: false)
        XCTAssertEqual(c.items, [.app("a"), .group(.init(name: "G", apps: ["g1", "g2"])), .app("new"), .app("b")])
    }

    func testNoOpDrops() {
        var c = base
        c.place(.app("a"), beside: .app("a"), after: true)
        c.place(.app("a"), beside: .app("loose"), after: true)
        c.place(.group("G"), beside: .app("g1"), after: true)
        c.place(.group("missing"), beside: .app("a"), after: true)
        XCTAssertEqual(c, base)
    }
}

final class BadgeTests: XCTestCase {
    func testCombined() {
        XCTAssertNil(Badge.combined([]))
        XCTAssertNil(Badge.combined(["", ""]))
        XCTAssertEqual(Badge.combined(["!"]), "!")
        XCTAssertEqual(Badge.combined(["3", "", "24"]), "27")
        XCTAssertEqual(Badge.combined(["1,200", "5"]), "1205")
        XCTAssertEqual(Badge.combined(["3", "!"]), "3")
        XCTAssertEqual(Badge.combined(["!", "•"]), "•")
    }
}

final class FakeDock: DockDefaults {
    var prefs: [String: Any] = [:]
    var restarts = 0
    func value(_ key: String) -> Any? { prefs[key] }
    func set(_ value: Any?, for key: String) { prefs[key] = value }
    func restartDock() { restarts += 1 }
}

final class DockHiderTests: XCTestCase {
    var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("dock-original.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testHideThenRestorePutsOriginalsBack() throws {
        let dock = FakeDock()
        dock.prefs = ["autohide": NSNumber(value: false)]      // delay key absent
        let hider = DockHider(defaults: dock, snapshotURL: url)

        try hider.hide()
        XCTAssertTrue(hider.isHidden)
        XCTAssertEqual(dock.prefs["autohide"] as? Bool, true)
        XCTAssertEqual(dock.prefs["autohide-delay"] as? Double, DockHider.hiddenDelay)

        hider.restore()
        XCTAssertFalse(hider.isHidden)
        XCTAssertEqual((dock.prefs["autohide"] as? NSNumber)?.boolValue, false)
        XCTAssertNil(dock.prefs["autohide-delay"], "an absent key must be deleted, not zeroed")
        XCTAssertEqual(dock.restarts, 2)
    }

    func testCrashThenRelaunchKeepsTheTrueOriginals() throws {
        let dock = FakeDock()
        dock.prefs = ["autohide": NSNumber(value: false), "autohide-delay": NSNumber(value: 0.2)]
        try DockHider(defaults: dock, snapshotURL: url).hide()

        // Crash: no restore. The next launch hides again over the hidden state.
        let relaunched = DockHider(defaults: dock, snapshotURL: url)
        try relaunched.hide()
        relaunched.restore()

        XCTAssertEqual((dock.prefs["autohide"] as? NSNumber)?.boolValue, false)
        XCTAssertEqual((dock.prefs["autohide-delay"] as? NSNumber)?.doubleValue, 0.2)
    }

    func testRestoreWithoutSnapshotChangesNothing() {
        let dock = FakeDock()
        dock.prefs = ["autohide": NSNumber(value: true)]
        DockHider(defaults: dock, snapshotURL: url).restore()
        XCTAssertEqual(dock.restarts, 0)
        XCTAssertEqual((dock.prefs["autohide"] as? NSNumber)?.boolValue, true)
    }
}
