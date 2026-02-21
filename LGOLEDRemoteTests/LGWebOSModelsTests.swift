import XCTest
@testable import LGOLEDRemote

final class LGWebOSModelsTests: XCTestCase {
    func testRequestEncodingAndDecoding() throws {
        let request = LGWebOSRequest(
            type: "request",
            id: "req-1",
            uri: "ssap://audio/getVolume",
            payload: ["mute": .bool(false), "volume": .int(10)]
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(LGWebOSRequest.self, from: data)

        XCTAssertEqual(decoded.type, "request")
        XCTAssertEqual(decoded.id, "req-1")
        XCTAssertEqual(decoded.uri, "ssap://audio/getVolume")
        XCTAssertEqual(decoded.payload?["volume"]?.intValue, 10)
    }

    func testResponseDecoding() throws {
        let json = """
        {"type":"response","id":"req-2","payload":{"volume":12,"mute":false}}
        """
        let response = try JSONDecoder().decode(LGWebOSResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.type, "response")
        XCTAssertEqual(response.id, "req-2")
        XCTAssertEqual(response.payload?["volume"]?.intValue, 12)
        XCTAssertEqual(response.payload?["mute"]?.boolValue, false)
    }
}
