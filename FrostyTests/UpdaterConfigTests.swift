import XCTest

/// The Sparkle settings in `Frosty/App/Info.plist`. The test target is not hosted by
/// the app, so this reads the source plist from the checkout (not the built bundle;
/// `scripts/release.sh` checks the merged plist of the exported app).
final class UpdaterConfigTests: XCTestCase {
    private var plist: [String: Any] = [:]

    override func setUpWithError() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FrostyTests
            .deletingLastPathComponent()   // repo root
        let url = root.appendingPathComponent("Frosty/App/Info.plist")
        let data = try Data(contentsOf: url)
        plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            "Info.plist is not a dictionary")
    }

    func testFeedIsAnHTTPSGitHubReleaseAsset() throws {
        let raw = try XCTUnwrap(plist["SUFeedURL"] as? String, "SUFeedURL is missing")
        let url = try XCTUnwrap(URL(string: raw))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "github.com")
        XCTAssertEqual(url.path, "/cxrobx/frosty/releases/latest/download/appcast.xml")
    }

    func testPublicKeyIsAnEd25519KeyAndNotEmpty() throws {
        let key = try XCTUnwrap(plist["SUPublicEDKey"] as? String, "SUPublicEDKey is missing")
        XCTAssertFalse(key.isEmpty)
        // Sparkle's public key is the base64 of the raw 32-byte Ed25519 key.
        let raw = try XCTUnwrap(Data(base64Encoded: key), "SUPublicEDKey is not base64")
        XCTAssertEqual(raw.count, 32)
    }

    func testAutomaticChecksAreOnAndInstallingStillAsks() {
        XCTAssertEqual(plist["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(plist["SUAutomaticallyUpdate"] as? Bool, false)
        XCTAssertEqual(plist["SUScheduledCheckInterval"] as? Int, 86_400)
    }

    func testSignatureIsCheckedBeforeTheArchiveIsExtracted() {
        XCTAssertEqual(plist["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
    }
}
