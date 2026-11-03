import XCTest
@testable import HermesMac

final class UpdateConfigurationTests: XCTestCase {
    private var info: [String: Any] {
        ["CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "42",
         "SUFeedURL": "https://github.com/example/app/releases/latest/download/appcast.xml",
         "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString()]
    }

    func testOnlyConfiguredReleaseBundleSupportsUpdates() {
        XCTAssertTrue(UpdateConfiguration(bundleIdentifier: "com.hermes.mac", info: info).supportsUpdates)
        for identifier in ["com.hermes.mac.dev", "com.hermes.mac.tests", nil] {
            XCTAssertFalse(UpdateConfiguration(bundleIdentifier: identifier, info: info).supportsUpdates)
        }
    }

    func testIncompleteOrInsecureConfigurationDisablesUpdates() {
        for (key, value) in [("SUFeedURL", "http://example.com/appcast.xml"),
                             ("SUFeedURL", "https:///"), ("SUPublicEDKey", "invalid"),
                             ("SUPublicEDKey", Data(repeating: 1, count: 31).base64EncodedString()),
                             ("CFBundleVersion", "")] {
            var invalid = info
            invalid[key] = value
            XCTAssertFalse(UpdateConfiguration(bundleIdentifier: "com.hermes.mac", info: invalid).supportsUpdates)
        }
        for key in ["SUFeedURL", "SUPublicEDKey", "CFBundleVersion"] {
            var missing = info
            missing.removeValue(forKey: key)
            XCTAssertFalse(UpdateConfiguration(bundleIdentifier: "com.hermes.mac", info: missing).supportsUpdates)
        }
    }

    func testVersionDisplayIncludesBuildAndHandlesUnbundledTests() {
        XCTAssertEqual(UpdateConfiguration(bundleIdentifier: nil, info: info).displayVersion, "1.2.3 (42)")
        XCTAssertEqual(UpdateConfiguration(bundleIdentifier: nil, info: [:]).displayVersion, "开发版")
    }
}
