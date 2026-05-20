import Foundation

public final class TOSClient: @unchecked Sendable {
    private let config: AppConfig
    private let session: URLSession

    public init(config: AppConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func uploadAudio(fileURL: URL, logger: @Sendable @escaping (String) -> Void) async throws -> UploadedObject {
        let objectKey = generateObjectKey(fileName: fileURL.lastPathComponent)
        let sizeBytes = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        let sizeMB = Double(sizeBytes) / 1024.0 / 1024.0
        let start = Date()

        let data = try Data(contentsOf: fileURL)
        logger(String(format: "上传音频到 TOS: key=%@, 大小=%.2fMB", objectKey, sizeMB))
        try await putObject(data: data, objectKey: objectKey)

        let elapsed = Date().timeIntervalSince(start)
        logger(String(format: "上传完成: key=%@, 耗时=%.1fs", objectKey, elapsed))

        let getURL = try presignedURL(method: "GET", objectKey: objectKey, expires: config.tosSignExpiresSec)
        return UploadedObject(key: objectKey, signedGetURL: getURL)
    }

    public func deleteObject(key: String, logger: @Sendable @escaping (String) -> Void) async {
        do {
            try await deleteObjectInternal(key: key)
            logger("已删除 TOS 临时音频: \(key)")
        } catch {
            logger("删除 TOS 临时音频失败(已忽略): \(error.localizedDescription)")
        }
    }

    private func generateObjectKey(fileName: String) -> String {
        let prefix = config.tosObjectPrefix.hasSuffix("/") ? config.tosObjectPrefix : config.tosObjectPrefix + "/"
        return prefix + UUID().uuidString.lowercased() + "-" + fileName
    }

    private func putObject(data: Data, objectKey: String) async throws {
        let endpointHost = normalizedEndpointHost
        let host = "\(config.tosBucket).\(endpointHost)"
        let encodedKey = encodePath(objectKey)
        guard let url = URL(string: "https://\(host)/\(encodedKey)") else {
            throw Audio2TxtError.invalidURL("TOS PUT URL 构建失败")
        }

        let payloadHash = Crypto.sha256Hex(data)
        let now = Date()
        let xTosDate = now.tosTimestampUTC()
        let dateStamp = now.tosDateStampUTC()

        let signedHeaders = "host;x-tos-content-sha256;x-tos-date"
        let canonicalHeaders = "host:\(host)\n" +
            "x-tos-content-sha256:\(payloadHash)\n" +
            "x-tos-date:\(xTosDate)\n"

        let canonicalRequest = [
            "PUT",
            "/\(encodedKey)",
            "",
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")

        let algorithm = "TOS4-HMAC-SHA256"
        let credentialScope = "\(dateStamp)/\(config.tosRegion)/tos/request"
        let stringToSign = [
            algorithm,
            xTosDate,
            credentialScope,
            Crypto.sha256Hex(canonicalRequest)
        ].joined(separator: "\n")

        let signature = signingSignature(secretKey: config.tosSecretKey, dateStamp: dateStamp, stringToSign: stringToSign)
        let authorization = "\(algorithm) Credential=\(config.tosAccessKey)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(xTosDate, forHTTPHeaderField: "X-Tos-Date")
        request.setValue(payloadHash, forHTTPHeaderField: "X-Tos-Content-Sha256")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        if let token = config.tosSecurityToken, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Tos-Security-Token")
        }

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Audio2TxtError.requestFailed("TOS PUT 无响应")
        }
        guard 200..<300 ~= http.statusCode else {
            throw Audio2TxtError.requestFailed("TOS PUT 失败: HTTP \(http.statusCode)")
        }
    }

    private func deleteObjectInternal(key: String) async throws {
        let endpointHost = normalizedEndpointHost
        let host = "\(config.tosBucket).\(endpointHost)"
        let encodedKey = encodePath(key)
        guard let url = URL(string: "https://\(host)/\(encodedKey)") else {
            throw Audio2TxtError.invalidURL("TOS DELETE URL 构建失败")
        }

        let payloadHash = Crypto.sha256Hex("")
        let now = Date()
        let xTosDate = now.tosTimestampUTC()
        let dateStamp = now.tosDateStampUTC()

        let signedHeaders = "host;x-tos-content-sha256;x-tos-date"
        let canonicalHeaders = "host:\(host)\n" +
            "x-tos-content-sha256:\(payloadHash)\n" +
            "x-tos-date:\(xTosDate)\n"

        let canonicalRequest = [
            "DELETE",
            "/\(encodedKey)",
            "",
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")

        let algorithm = "TOS4-HMAC-SHA256"
        let credentialScope = "\(dateStamp)/\(config.tosRegion)/tos/request"
        let stringToSign = [
            algorithm,
            xTosDate,
            credentialScope,
            Crypto.sha256Hex(canonicalRequest)
        ].joined(separator: "\n")

        let signature = signingSignature(secretKey: config.tosSecretKey, dateStamp: dateStamp, stringToSign: stringToSign)
        let authorization = "\(algorithm) Credential=\(config.tosAccessKey)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(xTosDate, forHTTPHeaderField: "X-Tos-Date")
        request.setValue(payloadHash, forHTTPHeaderField: "X-Tos-Content-Sha256")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        if let token = config.tosSecurityToken, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Tos-Security-Token")
        }

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Audio2TxtError.requestFailed("TOS DELETE 无响应")
        }
        guard 200..<300 ~= http.statusCode else {
            throw Audio2TxtError.requestFailed("TOS DELETE 失败: HTTP \(http.statusCode)")
        }
    }

    private func presignedURL(method: String, objectKey: String, expires: Int) throws -> URL {
        let endpointHost = normalizedEndpointHost
        let host = "\(config.tosBucket).\(endpointHost)"
        let encodedKey = encodePath(objectKey)

        let now = Date()
        let xTosDate = now.tosTimestampUTC()
        let dateStamp = now.tosDateStampUTC()
        let credentialScope = "\(dateStamp)/\(config.tosRegion)/tos/request"
        let algorithm = "TOS4-HMAC-SHA256"

        var queryItems: [(String, String)] = [
            ("X-Tos-Algorithm", algorithm),
            ("X-Tos-Credential", "\(config.tosAccessKey)/\(credentialScope)"),
            ("X-Tos-Date", xTosDate),
            ("X-Tos-Expires", String(expires)),
            ("X-Tos-SignedHeaders", "host")
        ]
        if let token = config.tosSecurityToken, !token.isEmpty {
            queryItems.append(("X-Tos-Security-Token", token))
        }

        let canonicalQuery = canonicalQueryString(queryItems)
        let canonicalRequest = [
            method,
            "/\(encodedKey)",
            canonicalQuery,
            "host:\(host)\n",
            "host",
            "UNSIGNED-PAYLOAD"
        ].joined(separator: "\n")

        let stringToSign = [
            algorithm,
            xTosDate,
            credentialScope,
            Crypto.sha256Hex(canonicalRequest)
        ].joined(separator: "\n")

        let signature = signingSignature(secretKey: config.tosSecretKey, dateStamp: dateStamp, stringToSign: stringToSign)
        queryItems.append(("X-Tos-Signature", signature))

        let finalQuery = canonicalQueryString(queryItems)
        guard let url = URL(string: "https://\(host)/\(encodedKey)?\(finalQuery)") else {
            throw Audio2TxtError.invalidURL("TOS 预签名 URL 构建失败")
        }
        return url
    }

    private var normalizedEndpointHost: String {
        var endpoint = config.tosEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        endpoint = endpoint.replacingOccurrences(of: "https://", with: "")
        endpoint = endpoint.replacingOccurrences(of: "http://", with: "")
        return endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func signingSignature(secretKey: String, dateStamp: String, stringToSign: String) -> String {
        let kDate = Crypto.hmacSHA256(key: Data(secretKey.utf8), message: dateStamp)
        let kRegion = Crypto.hmacSHA256(key: kDate, message: config.tosRegion)
        let kService = Crypto.hmacSHA256(key: kRegion, message: "tos")
        let kSigning = Crypto.hmacSHA256(key: kService, message: "request")
        return Crypto.hmacSHA256(key: kSigning, message: stringToSign).hexString
    }

    private func encodePath(_ raw: String) -> String {
        raw.split(separator: "/", omittingEmptySubsequences: false)
            .map { percentEncode(String($0)) }
            .joined(separator: "/")
    }

    private func canonicalQueryString(_ items: [(String, String)]) -> String {
        items
            .map { (percentEncode($0.0), percentEncode($0.1)) }
            .sorted { lhs, rhs in
                if lhs.0 == rhs.0 { return lhs.1 < rhs.1 }
                return lhs.0 < rhs.0
            }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
    }

    private func percentEncode(_ text: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}
