import Foundation
import CryptoKit

class AppStoreConnectAPI {
    private let keyID: String
    private let issuerID: String
    private let privateKeyPath: String
    private let baseURL = "https://api.appstoreconnect.apple.com"

    init(keyID: String, issuerID: String) {
        self.keyID = keyID
        self.issuerID = issuerID
        self.privateKeyPath = "AuthKey_\(keyID).p8"
    }

    func generateJWT() throws -> String {
        // Read private key
        let privateKeyURL = URL(fileURLWithPath: privateKeyPath)
        let privateKeyData = try Data(contentsOf: privateKeyURL)

        // Create private key from data
        guard let privateKeyString = String(data: privateKeyData, encoding: .utf8) else {
            throw NSError(domain: "AppStoreConnectAPI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to read private key as UTF-8 string"])
        }
        let privateKey = try P256.KeyAgreement.PrivateKey(pemRepresentation: privateKeyString)

        // Create JWT header
        let header: [String: Any] = [
//            "alg": "ES256",
            "kid": keyID,
//            "typ": "JWT"
        ]

        // Create JWT payload
        let now = Date()
        let expirationDate = now.addingTimeInterval(1200) // 20 minutes

        let payload: [String: Any] = [
            "iss": issuerID,
            "iat": Int64(now.timeIntervalSince1970),
            "exp": Int64(expirationDate.timeIntervalSince1970),
            "aud": "appstoreconnect-v1"
        ]

        // Encode header and payload
        let headerData = try JSONSerialization.data(withJSONObject: header)
        let payloadData = try JSONSerialization.data(withJSONObject: payload)

        let headerBase64 = headerData.base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")

        let payloadBase64 = payloadData.base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")

        // Create message to sign
        let message = "\(headerBase64).\(payloadBase64)"
        let messageData = message.data(using: .utf8)!

        // Sign message
        let privateKeyDataForSigning = privateKey.rawRepresentation
        let signingKey = try P256.Signing.PrivateKey(rawRepresentation: privateKeyDataForSigning)
        let signature = try signingKey.signature(for: SHA256.hash(data: messageData))
        let signatureData = signature.rawRepresentation

        let signatureBase64 = signatureData.base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")

        // Create final JWT
        return "\(message).\(signatureBase64)"
    }
}

func main() {
    do {
        // You need to provide your actual key ID and issuer ID
        let keyID = "YOUR_KEY_ID"
        let issuerID = "YOUR_ISSUER_ID"

        let api = AppStoreConnectAPI(keyID: keyID, issuerID: issuerID)
        let token = try api.generateJWT()

        print("✅ JWT Token generated successfully!")
        print("Token: \(token)")

        // Print token info
        let tokenParts = token.split(separator: ".")
        print("Header length: \(tokenParts[0].count)")
        print("Payload length: \(tokenParts[1].count)")
        print("Signature length: \(tokenParts[2].count)")
    } catch {
        print("❌ Error generating JWT: \(error)")
    }
}

main()

