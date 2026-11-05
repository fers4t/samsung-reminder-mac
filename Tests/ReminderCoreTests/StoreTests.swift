import XCTest
@testable import Samsung_Reminder

final class StoreTests: XCTestCase {
    func testSnapshotRoundTripAndVersionGate() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snap-\(UUID().uuidString).json")
        let store = SnapshotStore(url: url)
        defer { try? store.clear() }
        XCTAssertEqual(try store.load(), .empty)
        let snapshot = ReminderSnapshot(syncedAt: Date(timeIntervalSince1970: 1000), reminders: [Reminder(record: ["record_id": .string("x"), "title": .string("Hi")])], categories: [ReminderCategory(id: "c", name: "Work", color: 3)], truncated: true)
        try store.save(snapshot)
        XCTAssertEqual(try store.load(), snapshot)
        try Data("{\"version\":99,\"syncedAt\":\"2020-01-01T00:00:00Z\",\"reminders\":[],\"categories\":[],\"truncated\":false}".utf8).write(to: url)
        XCTAssertEqual(try store.load(), .empty)
    }

    func testCredentialValidationAllowlist() throws {
        let good = CloudCredential(accessToken: " abc.DEF-123_= ", userId: "u1", deviceId: "d-2", accountEmail: " ")
        let valid = try good.validated()
        XCTAssertEqual(valid.accessToken, "abc.DEF-123_=")
        XCTAssertNil(valid.accountEmail)
        XCTAssertEqual(valid.maskedHint, "Account ••••u1")
        XCTAssertThrowsError(try CloudCredential(accessToken: "", userId: "u", deviceId: "d").validated())
        XCTAssertThrowsError(try CloudCredential(accessToken: "ok", userId: "u<script>", deviceId: "d").validated())
        XCTAssertThrowsError(try CloudCredential(accessToken: String(repeating: "a", count: 5000), userId: "u", deviceId: "d").validated())
    }

    func testKeychainRoundTrip() throws {
        let store = KeychainStore(service: "SamsungReminder.tests.\(UUID().uuidString)")
        defer { try? store.delete() }
        XCTAssertNil(try store.load())
        let credential = CloudCredential(accessToken: "t", userId: "u", deviceId: "d")
        try store.save(credential)
        XCTAssertEqual(try store.load(), credential)
        try store.save(CloudCredential(accessToken: "t2", userId: "u", deviceId: "d"))
        XCTAssertEqual(try store.load()?.accessToken, "t2")
        try store.delete()
        XCTAssertNil(try store.load())
    }
}
