import CryptoKit
import Foundation

struct CloudMountItem: Identifiable, Sendable {
    let id: String
    let name: String
    let provider: String
    let path: String

    func asVolumeItem() -> VolumeItem {
        let vals = try? URL(fileURLWithPath: path).resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ])
        let total = UInt64(vals?.volumeTotalCapacity ?? 0)
        let avail = UInt64(vals?.volumeAvailableCapacityForImportantUsage ?? 0)
        return VolumeItem(
            id: path,
            name: "\(name) (\(provider))",
            mountPath: path,
            totalBytes: total,
            availableBytes: avail,
            fileSystem: provider,
            isExternal: true,
            isNetwork: true,
            isWritable: true
        )
    }
}

enum S3ProviderType: String, CaseIterable, Codable, Sendable {
    case r2 = "Cloudflare R2"
    case s3 = "Amazon S3"
}

struct S3ConnectionConfig: Identifiable, Codable, Sendable {
    let id: String
    var name: String
    var provider: S3ProviderType
    var endpoint: String
    var bucket: String
    var region: String
    var accessKeyId: String
    var secretAccessKey: String
}

struct S3ObjectItem: Identifiable, Sendable {
    let id: String
    let name: String
    let key: String
    let sizeBytes: UInt64
    let isFolder: Bool
    let lastModified: String
}

enum CloudStorageManager {
    static func detectCloudMounts() -> [CloudMountItem] {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        var items: [CloudMountItem] = []

        // 1. iCloud Drive
        let icloudPath = "\(home)/Library/Mobile Documents/com~apple~CloudDocs"
        if fm.fileExists(atPath: icloudPath) {
            items.append(
                CloudMountItem(
                    id: icloudPath,
                    name: "iCloud Drive",
                    provider: "iCloud",
                    path: icloudPath
                )
            )
        }

        // 2. macOS FileProvider mounts (Google Drive, OneDrive, Dropbox, etc.)
        let cloudStorageDir = "\(home)/Library/CloudStorage"
        if let entries = try? fm.contentsOfDirectory(atPath: cloudStorageDir) {
            for entry in entries.sorted() where !entry.hasPrefix(".") {
                let fullPath = "\(cloudStorageDir)/\(entry)"
                let lower = entry.lowercased()
                let provider: String
                if lower.contains("googledrive") || lower.contains("google drive") {
                    provider = "Google Drive"
                } else if lower.contains("onedrive") {
                    provider = "OneDrive"
                } else if lower.contains("dropbox") {
                    provider = "Dropbox"
                } else {
                    provider = "Cloud Drive"
                }
                items.append(
                    CloudMountItem(
                        id: fullPath,
                        name: entry,
                        provider: provider,
                        path: fullPath
                    )
                )
            }
        }

        return items
    }
}

enum S3Client {
    static func listObjects(config: S3ConnectionConfig, prefix: String = "") async throws -> [S3ObjectItem] {
        var queryItems: [(String, String)] = [
            ("delimiter", "/"),
            ("list-type", "2")
        ]
        if !prefix.isEmpty {
            queryItems.append(("prefix", prefix))
        }
        queryItems.sort { $0.0 < $1.0 }

        let req = try signedRequest(
            config: config,
            method: "GET",
            objectKey: "",
            queryItems: queryItems,
            payload: Data()
        )
        let (data, resp) = try await URLSession.shared.data(for: req)
        try validateResponse(resp, data: data)
        return S3ListXMLParser.parse(data: data, currentPrefix: prefix)
    }

    static func uploadFile(config: S3ConnectionConfig, localURL: URL, remoteKey: String) async throws {
        let data = try Data(contentsOf: localURL)
        let req = try signedRequest(
            config: config,
            method: "PUT",
            objectKey: remoteKey,
            queryItems: [],
            payload: data
        )
        let (respData, resp) = try await URLSession.shared.data(for: req)
        try validateResponse(resp, data: respData)
    }

    static func downloadObject(config: S3ConnectionConfig, key: String, to localURL: URL) async throws {
        let req = try signedRequest(
            config: config,
            method: "GET",
            objectKey: key,
            queryItems: [],
            payload: Data()
        )
        let (data, resp) = try await URLSession.shared.data(for: req)
        try validateResponse(resp, data: data)
        try data.write(to: localURL)
    }

    static func deleteObject(config: S3ConnectionConfig, key: String) async throws {
        let req = try signedRequest(
            config: config,
            method: "DELETE",
            objectKey: key,
            queryItems: [],
            payload: Data()
        )
        let (data, resp) = try await URLSession.shared.data(for: req)
        try validateResponse(resp, data: data)
    }

    private static func validateResponse(_ resp: URLResponse, data: Data) throws {
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "S3Client", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "S3Client",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body.prefix(200))"]
            )
        }
    }

    private static func signedRequest(
        config: S3ConnectionConfig,
        method: String,
        objectKey: String,
        queryItems: [(String, String)],
        payload: Data
    ) throws -> URLRequest {
        var base = config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if !base.hasPrefix("http://") && !base.hasPrefix("https://") {
            base = "https://\(base)"
        }
        guard let baseURL = URL(string: base), let host = baseURL.host else {
            throw NSError(domain: "S3Client", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid endpoint URL"])
        }

        let cleanKey = objectKey.hasPrefix("/") ? String(objectKey.dropFirst()) : objectKey
        let canonicalURI: String
        if cleanKey.isEmpty {
            canonicalURI = "/\(awsEncode(config.bucket))"
        } else {
            let encodedKey = cleanKey.split(separator: "/", omittingEmptySubsequences: false)
                .map { awsEncode(String($0)) }
                .joined(separator: "/")
            canonicalURI = "/\(awsEncode(config.bucket))/\(encodedKey)"
        }

        let canonicalQuery = queryItems
            .sorted { $0.0 < $1.0 }
            .map { "\(awsEncode($0.0))=\(awsEncode($0.1))" }
            .joined(separator: "&")

        let urlString = canonicalQuery.isEmpty
            ? "\(base)\(canonicalURI)"
            : "\(base)\(canonicalURI)?\(canonicalQuery)"

        guard let finalURL = URL(string: urlString) else {
            throw NSError(domain: "S3Client", code: -3, userInfo: [NSLocalizedDescriptionKey: "Invalid request URL"])
        }

        let now = Date()
        let amzDate = amzDateFormatter.string(from: now)
        let dateStamp = dateStampFormatter.string(from: now)
        let payloadHash = sha256Hex(payload)
        let region = config.region.isEmpty ? (config.provider == .r2 ? "auto" : "us-east-1") : config.region

        let canonicalHeaders = "host:\(host)\nx-amz-content-sha256:\(payloadHash)\nx-amz-date:\(amzDate)\n"
        let signedHeaders = "host;x-amz-content-sha256;x-amz-date"
        let canonicalRequest = [
            method,
            canonicalURI,
            canonicalQuery,
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")

        let credentialScope = "\(dateStamp)/\(region)/s3/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            sha256Hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")

        let kDate = hmacSHA256(key: Data(("AWS4" + config.secretAccessKey).utf8), data: Data(dateStamp.utf8))
        let kRegion = hmacSHA256(key: kDate, data: Data(region.utf8))
        let kService = hmacSHA256(key: kRegion, data: Data("s3".utf8))
        let kSigning = hmacSHA256(key: kService, data: Data("aws4_request".utf8))
        let signature = hmacSHA256(key: kSigning, data: Data(stringToSign.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        let authHeader = "AWS4-HMAC-SHA256 Credential=\(config.accessKeyId)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var req = URLRequest(url: finalURL, timeoutInterval: 30)
        req.httpMethod = method
        req.httpBody = payload.isEmpty ? nil : payload
        req.setValue(host, forHTTPHeaderField: "Host")
        req.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        req.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        return req
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmacSHA256(key: Data, data: Data) -> Data {
        let symKey = SymmetricKey(data: key)
        return Data(HMAC<SHA256>.authenticationCode(for: data, using: symKey))
    }

    private static func awsEncode(_ str: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return str.addingPercentEncoding(withAllowedCharacters: allowed) ?? str
    }

    private static let amzDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        f.timeZone = TimeZone(abbreviation: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let dateStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = TimeZone(abbreviation: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

private final class S3ListXMLParser: NSObject, XMLParserDelegate {
    private var items: [S3ObjectItem] = []
    private let currentPrefix: String
    private var currentElement = ""
    private var currentText = ""
    private var inContents = false
    private var inCommonPrefixes = false

    private var objKey = ""
    private var objSize: UInt64 = 0
    private var objModified = ""

    init(currentPrefix: String) {
        self.currentPrefix = currentPrefix
    }

    static func parse(data: Data, currentPrefix: String) -> [S3ObjectItem] {
        let delegate = S3ListXMLParser(currentPrefix: currentPrefix)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.items.sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder && !$1.isFolder }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""
        if elementName == "Contents" {
            inContents = true
            objKey = ""
            objSize = 0
            objModified = ""
        } else if elementName == "CommonPrefixes" {
            inCommonPrefixes = true
            objKey = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if inContents {
            switch elementName {
            case "Key": objKey = trimmed
            case "Size": objSize = UInt64(trimmed) ?? 0
            case "LastModified": objModified = trimmed
            case "Contents":
                inContents = false
                if objKey != currentPrefix && !objKey.isEmpty {
                    let displayName = objKey.hasPrefix(currentPrefix)
                        ? String(objKey.dropFirst(currentPrefix.count))
                        : objKey
                    items.append(
                        S3ObjectItem(
                            id: "file-\(objKey)",
                            name: displayName,
                            key: objKey,
                            sizeBytes: objSize,
                            isFolder: false,
                            lastModified: objModified
                        )
                    )
                }
            default: break
            }
        } else if inCommonPrefixes {
            if elementName == "Prefix" {
                objKey = trimmed
            } else if elementName == "CommonPrefixes" {
                inCommonPrefixes = false
                if !objKey.isEmpty {
                    var display = objKey.hasPrefix(currentPrefix)
                        ? String(objKey.dropFirst(currentPrefix.count))
                        : objKey
                    if display.hasSuffix("/") { display.removeLast() }
                    items.append(
                        S3ObjectItem(
                            id: "dir-\(objKey)",
                            name: display,
                            key: objKey,
                            sizeBytes: 0,
                            isFolder: true,
                            lastModified: ""
                        )
                    )
                }
            }
        }
    }
}
