import XCTest
@testable import LGOLEDRemote

final class SecureStoreTests: XCTestCase {
    func testMockedKeyStorePersistenceLogic() throws {
        let store = InMemoryKeyStore()
        XCTAssertNil(try store.clientKey(for: "tv-a"))

        try store.saveClientKey("secret", for: "tv-a")
        XCTAssertEqual(try store.clientKey(for: "tv-a"), "secret")

        try store.removeClientKey(for: "tv-a")
        XCTAssertNil(try store.clientKey(for: "tv-a"))
    }
}

private final class InMemoryKeyStore: ClientKeyStore {
    private var map: [String: String] = [:]

    func clientKey(for tvID: String) throws -> String? {
        map[tvID]
    }

    func saveClientKey(_ key: String, for tvID: String) throws {
        map[tvID] = key
    }

    func removeClientKey(for tvID: String) throws {
        map.removeValue(forKey: tvID)
    }
}
