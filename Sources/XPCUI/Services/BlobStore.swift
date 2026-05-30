import CryptoKit
import Foundation

final class BlobStore: @unchecked Sendable {
    private let lock = NSLock()
    private var blobsURL: URL?
    private let sidecarThreshold = 4 * 1024

    func configure(blobsURL: URL) {
        lock.lock()
        self.blobsURL = blobsURL
        lock.unlock()
    }

    func externalize(_ value: JSONValue?) -> JSONValue? {
        guard let value else { return nil }
        switch value {
        case let .object(fields):
            if let sidecar = externalizeDataObject(fields) {
                return .object(sidecar)
            }
            return .object(fields.mapValues { externalize($0) ?? .null })
        case let .array(items):
            return .array(items.map { externalize($0) ?? .null })
        default:
            return value
        }
    }

    private func externalizeDataObject(_ fields: [String: JSONValue]) -> [String: JSONValue]? {
        guard
            fields["type"] == .string("data"),
            fields["encoding"] == .string("base64"),
            case let .string(encoded)? = fields["value"],
            let data = Data(base64Encoded: encoded),
            data.count > sidecarThreshold
        else {
            return nil
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let filename = "\(digest).blob"
        lock.lock()
        let destination = blobsURL?.appendingPathComponent(filename)
        if let destination, !FileManager.default.fileExists(atPath: destination.path) {
            try? data.write(to: destination, options: .atomic)
        }
        lock.unlock()
        var sidecar = fields
        sidecar["value"] = nil
        sidecar["blobReference"] = .string(filename)
        return sidecar
    }
}
