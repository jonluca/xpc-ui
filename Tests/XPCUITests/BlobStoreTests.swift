import Foundation
import XCTest
@testable import XPC_UI

final class BlobStoreTests: XCTestCase {
    func testLargeDataPayloadBecomesSidecar() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let blobs = root.appendingPathComponent("blobs")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bytes = Data(repeating: 0xab, count: 5_000)
        let store = BlobStore()
        store.configure(blobsURL: blobs)
        let externalized = store.externalize(.object([
            "type": .string("data"),
            "encoding": .string("base64"),
            "length": .number(Double(bytes.count)),
            "value": .string(bytes.base64EncodedString()),
        ]))

        guard
            case let .object(fields)? = externalized,
            case let .string(filename)? = fields["blobReference"]
        else {
            return XCTFail("Expected a blob reference")
        }
        XCTAssertNil(fields["value"])
        XCTAssertEqual(try Data(contentsOf: blobs.appendingPathComponent(filename)), bytes)
    }

    func testLazyJSONPayloadCanBeLoadedFromTracerSidecar() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let blobs = root.appendingPathComponent("blobs")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let filename = "payload-42-1.json"
        let payload: JSONValue = .object(["message": .string("full fidelity")])
        try JSONEncoder().encode(payload).write(to: blobs.appendingPathComponent(filename))
        let store = BlobStore()
        store.configure(blobsURL: blobs)

        let loaded = store.loadLazyPayload(.object([
            "type": .string("lazy-json"),
            "encoding": .string("json"),
            "length": .number(32),
            "blobReference": .string(filename),
        ]))

        XCTAssertEqual(loaded, payload)
    }
}
