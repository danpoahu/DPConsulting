#if false
import Foundation
import CryptoKit
import Security

public struct DPASCCredentials: Codable {
    public let issuerId: String
    public let keyId: String
    public let privateKeyPEM: String
}

public enum DPASCCredentialsError: Error {
    case notFound
    case invalidPEM
    case signingFailed
    case encodingFailed
}

public class DPASCCredentialsManager {
    public static let shared = DPASCCredentialsManager()
    private init() {}

    private let service = "com.dpconsult.asc"
    private let account = "credentials"

    public func load() -> DPASCCredentials? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess,
              let data = item as? Data,
              let creds = try? JSONDecoder().decode(DPASCCredentials.self, from: data) else {
            return nil
        }
        return creds
    }

    public func save(_ creds: DPASCCredentials) throws {
        let data = try JSONEncoder().encode(creds)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if updateStatus != errSecSuccess {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus), userInfo: nil)
            }
        } else if status == errSecItemNotFound {
            var addItem = query
            addItem[kSecValueData as String] = data
            let addStatus = SecItemAdd(addItem as CFDictionary, nil)
            if addStatus != errSecSuccess {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus), userInfo: nil)
            }
        } else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: nil)
        }
    }

    public func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: nil)
        }
    }

    public func generateJWT(expiration: TimeInterval = 1200) throws -> String {
        guard let creds = load() else {
            throw DPASCCredentialsError.notFound
        }

        let privateKey: P256.Signing.PrivateKey
        do {
            privateKey = try P256.Signing.PrivateKey(pemRepresentation: creds.privateKeyPEM)
        } catch {
            throw DPASCCredentialsError.invalidPEM
        }

        let header: [String: String] = [
            "alg": "ES256",
            "kid": creds.keyId,
            "typ": "JWT"
        ]

        let now = Int(Date().timeIntervalSince1970)
        let payload: [String: Any] = [
            "iss": creds.issuerId,
            "exp": now + Int(expiration),
            "aud": "appstoreconnect-v1"
        ]

        let headerData = try jsonEncodeNoWhitespace(header)
        let payloadData = try jsonEncodeNoWhitespace(payload)

        let headerBase64 = base64URLEncode(headerData)
        let payloadBase64 = base64URLEncode(payloadData)

        let signingInput = "\(headerBase64).\(payloadBase64)"
        guard let signingInputData = signingInput.data(using: .utf8) else {
            throw DPASCCredentialsError.encodingFailed
        }

        let signature: Data
        do {
            let sig = try privateKey.signature(for: signingInputData)
            signature = sig.derRepresentationToRaw()
        } catch {
            throw DPASCCredentialsError.signingFailed
        }

        let signatureBase64 = base64URLEncode(signature)
        let jwt = "\(signingInput).\(signatureBase64)"
        return jwt
    }

    private func base64URLEncode(_ data: Data) -> String {
        var base64 = data.base64EncodedString()
        base64 = base64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return base64
    }

    private func jsonEncodeNoWhitespace(_ value: Any) throws -> Data {
        if JSONSerialization.isValidJSONObject(value) {
            return try JSONSerialization.data(withJSONObject: value, options: [])
        } else {
            throw DPASCCredentialsError.encodingFailed
        }
    }
}

// Extension to convert DER-encoded ECDSA signature to raw concatenation of r and s for JWT ES256
private extension P256.Signing.ECDSASignature {
    func derRepresentationToRaw() -> Data {
        // DER format: SEQUENCE { r INTEGER, s INTEGER }
        // We need to extract r and s and pad to 32 bytes each then concatenate.
        let der = self.derRepresentation
        var offset = 0

        func readLength(_ data: Data, offset: inout Int) -> Int? {
            guard offset < data.count else { return nil }
            var length = Int(data[offset])
            offset += 1
            if length & 0x80 != 0 {
                let byteCount = length & 0x7f
                guard byteCount <= 4, offset + byteCount <= data.count else { return nil }
                length = 0
                for _ in 0..<byteCount {
                    length = (length << 8) + Int(data[offset])
                    offset += 1
                }
            }
            return length
        }

        guard der[offset] == 0x30 else { return Data() } // SEQUENCE
        offset += 1
        guard let seqLength = readLength(der, offset: &offset) else { return Data() }
        let seqEnd = offset + seqLength
        guard seqEnd <= der.count else { return Data() }

        guard der[offset] == 0x02 else { return Data() } // INTEGER r
        offset += 1
        guard let rLength = readLength(der, offset: &offset) else { return Data() }
        guard offset + rLength <= der.count else { return Data() }
        let rData = der[offset ..< offset + rLength]
        offset += rLength

        guard der[offset] == 0x02 else { return Data() } // INTEGER s
        offset += 1
        guard let sLength = readLength(der, offset: &offset) else { return Data() }
        guard offset + sLength <= der.count else { return Data() }
        let sData = der[offset ..< offset + sLength]
        offset += sLength

        let rPadded = rData.stripLeadingZeros().leftPadded(to: 32)
        let sPadded = sData.stripLeadingZeros().leftPadded(to: 32)

        return rPadded + sPadded
    }
}

private extension Data.SubSequence {
    func stripLeadingZeros() -> Data {
        var start = self.startIndex
        while start < self.endIndex && self[start] == 0 {
            start = self.index(after: start)
        }
        return Data(self[start..<self.endIndex])
    }
}

private extension Data {
    func leftPadded(to length: Int) -> Data {
        if self.count >= length { return self }
        let padding = Data(repeating: 0, count: length - self.count)
        return padding + self
    }
}

#endif
