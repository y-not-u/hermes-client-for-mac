import XCTest
@testable import HermesMac

final class SingleInstanceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testSameBundleCannotAcquireSecondLock() throws {
        let first = try SingleInstanceLock(identifier: "com.hermes.mac", directory: directory)
        let second = try SingleInstanceLock(identifier: "com.hermes.mac", directory: directory)
        XCTAssertTrue(try first.acquire())
        XCTAssertFalse(try second.acquire())
        withExtendedLifetime(first) {}
    }

    func testDevelopmentAndReleaseCanRunTogether() throws {
        let release = try SingleInstanceLock(identifier: "com.hermes.mac", directory: directory)
        let development = try SingleInstanceLock(identifier: "com.hermes.mac.dev", directory: directory)
        XCTAssertTrue(try release.acquire())
        XCTAssertTrue(try development.acquire())
        withExtendedLifetime((release, development)) {}
    }

    func testExitReleasesLockWithoutRemovingFile() throws {
        var first: SingleInstanceLock? = try SingleInstanceLock(identifier: "com.hermes.mac", directory: directory)
        XCTAssertTrue(try XCTUnwrap(first).acquire())
        let waiting = try SingleInstanceLock(identifier: "com.hermes.mac", directory: directory)
        XCTAssertFalse(try waiting.acquire())
        first = nil
        XCTAssertTrue(try waiting.acquire())
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("com.hermes.mac.instance.lock").path))
    }

    func testMissingLockDirectoryFailsInsteadOfAllowingDuplicate() {
        XCTAssertThrowsError(try SingleInstanceLock(identifier: "com.hermes.mac", directory: directory.appendingPathComponent("missing")))
    }
}
