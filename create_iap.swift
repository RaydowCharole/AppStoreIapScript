#!/usr/bin/env swift
import Foundation
import CryptoKit

struct ScriptError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

struct APIHTTPError: Error {
    let statusCode: Int
    let body: String
    let json: [String: Any]

    init(statusCode: Int, data: Data) {
        self.statusCode = statusCode
        self.body = String(data: data, encoding: .utf8) ?? ""
        self.json = (try? jsonObject(data)) ?? [:]
    }
}

func errorMessage(_ error: Error) -> String {
    if let scriptError = error as? ScriptError {
        return scriptError.message
    }
    if let apiError = error as? APIHTTPError {
        return "HTTP \(apiError.statusCode): \(apiError.body)"
    }
    return String(reflecting: error)
}

struct IAPConfig: Decodable {
    let keyID: String
    let issuerID: String
    let appID: String

    enum CodingKeys: String, CodingKey {
        case keyID = "Key ID"
        case issuerID = "Issuer ID"
        case appID = "Apple ID"
    }
}

struct IAPProduct {
    let productID: String
    let name: String
    let displayName: String
    let description: String
    let price: String
    let image: String
    let imageURL: URL
}

struct IAPResult {
    let productID: String
    let price: String
    let iapID: String?
    let pricePointID: String?
    let screenshotID: String?
    let status: String
    let error: String?
}

func scriptDirectoryURL() -> URL {
    let arg0 = CommandLine.arguments[0]
    if arg0.hasSuffix(".swift") {
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }

    let executableURL: URL
    if arg0.hasPrefix("/") {
        executableURL = URL(fileURLWithPath: arg0)
    } else {
        executableURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(arg0)
    }
    return executableURL.standardizedFileURL.deletingLastPathComponent()
}

func loadText(from url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    if let utf8 = String(data: data, encoding: .utf8) {
        return utf8.hasPrefix("\u{FEFF}") ? String(utf8.dropFirst()) : utf8
    }
    if let utf16 = String(data: data, encoding: .utf16) {
        return utf16.hasPrefix("\u{FEFF}") ? String(utf16.dropFirst()) : utf16
    }
    throw ScriptError("无法以 UTF-8/UTF-16 读取文件: \(url.path)")
}

func parseCSV(_ content: String) throws -> [[String]] {
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var inQuotes = false
    let chars = Array(content)
    var index = 0

    func endField() {
        row.append(field)
        field = ""
    }

    func endRow() {
        endField()
        if row.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            rows.append(row)
        }
        row = []
    }

    while index < chars.count {
        let char = chars[index]
        if inQuotes {
            if char == "\"" {
                if index + 1 < chars.count, chars[index + 1] == "\"" {
                    field.append("\"")
                    index += 1
                } else {
                    inQuotes = false
                }
            } else {
                field.append(char)
            }
        } else {
            switch char {
            case "\"":
                inQuotes = true
            case ",":
                endField()
            case "\n", "\r", "\r\n":
                endRow()
            default:
                field.append(char)
            }
        }
        index += 1
    }

    if inQuotes {
        throw ScriptError("CSV 存在未闭合的引号")
    }
    if !field.isEmpty || !row.isEmpty {
        endRow()
    }
    return rows
}

func normalizeHeader(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: " ", with: "_")
}

func loadProducts(from csvURL: URL, baseDirectory: URL) throws -> [IAPProduct] {
    let rows = try parseCSV(try loadText(from: csvURL))
    guard let headerRow = rows.first else {
        throw ScriptError("CSV 为空: \(csvURL.path)")
    }

    let headers = headerRow.map { normalizeHeader($0) }
    let dataRows = rows.dropFirst()
    var products: [IAPProduct] = []

    for (index, rawRow) in dataRows.enumerated() {
        if rawRow.first?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#") == true {
            continue
        }

        var mapped: [String: String] = [:]
        for (columnIndex, header) in headers.enumerated() where columnIndex < rawRow.count {
            mapped[header] = rawRow[columnIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let productID = mapped["product_id"] ?? ""
        let name = mapped["reference_name"] ?? ""
        let displayName = mapped["display_name"] ?? ""
        let description = mapped["description"] ?? ""
        let price = mapped["price"] ?? ""
        let image = mapped["screenshot"] ?? ""
        let lineNumber = index + 2

        guard !productID.isEmpty else {
            throw ScriptError("CSV 第 \(lineNumber) 行缺少 Product ID")
        }
        guard !price.isEmpty else {
            throw ScriptError("CSV 第 \(lineNumber) 行缺少 Price: \(productID)")
        }
        guard !image.isEmpty else {
            throw ScriptError("CSV 第 \(lineNumber) 行缺少 Screenshot: \(productID)")
        }

        let resolvedName = name.isEmpty ? productID : name
        let resolvedDisplayName = displayName.isEmpty ? resolvedName : displayName
        let imageURL = resolveFileURL(image, baseDirectory: baseDirectory, csvDirectory: csvURL.deletingLastPathComponent())
        products.append(
            IAPProduct(
                productID: productID,
                name: resolvedName,
                displayName: resolvedDisplayName,
                description: description.isEmpty ? resolvedDisplayName : description,
                price: price,
                image: image,
                imageURL: imageURL
            )
        )
    }

    if products.isEmpty {
        throw ScriptError("CSV 中没有内购项: \(csvURL.path)")
    }
    return products
}

func resolveFileURL(_ path: String, baseDirectory: URL, csvDirectory: URL) -> URL {
    let url = URL(fileURLWithPath: path)
    if url.isFileURL && path.hasPrefix("/") {
        return url
    }

    let candidates = [
        baseDirectory.appendingPathComponent(path),
        csvDirectory.appendingPathComponent(path),
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(path),
    ]
    return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) ?? candidates[0]
}

func fileSizeString(at url: URL) -> String {
    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize else {
        return "不存在"
    }
    return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
}

func pricesMatch(_ lhs: String, _ rhs: String) -> Bool {
    if lhs == rhs {
        return true
    }
    guard let left = Decimal(string: lhs), let right = Decimal(string: rhs) else {
        return false
    }
    return left == right
}

func jsonObject(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ScriptError("响应不是 JSON 对象")
    }
    return object
}

func assetDeliveryState(from attributes: [String: Any]) -> String {
    let value = attributes["assetDeliveryState"]
    if let text = value as? String {
        return text
    }
    if let object = value as? [String: Any], let state = object["state"] as? String {
        return state
    }
    return String(describing: value ?? "unknown")
}

func confirm(_ prompt: String) -> Bool {
    print(prompt, terminator: "")
    fflush(stdout)
    guard let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
        return false
    }
    return line == "y" || line == "yes"
}

func printPreview(config: IAPConfig, configURL: URL, csvURL: URL, privateKeyURL: URL, products: [IAPProduct]) {
    print("========== 配置信息 ==========")
    print("配置文件: \(configURL.path)")
    print("CSV 文件: \(csvURL.path)")
    print("Key ID: \(config.keyID)")
    print("Issuer ID: \(config.issuerID)")
    print("Apple ID: \(config.appID)")
    print("私钥: \(privateKeyURL.lastPathComponent)  \(FileManager.default.fileExists(atPath: privateKeyURL.path) ? "✓" : "✗ 不存在")")
    print("")
    print("========== 内购项（共 \(products.count) 个）==========")

    for (index, product) in products.enumerated() {
        let imageExists = FileManager.default.fileExists(atPath: product.imageURL.path)
        print("\(index + 1). Product ID: \(product.productID)")
        print("   Reference Name: \(product.name)")
        print("   Price: $\(product.price)")
        print("   Localization: en-US")
        print("   Display Name: \(product.displayName)")
        print("   Description: \(product.description)")
        print("   Screenshot: \(product.imageURL.path)  \(imageExists ? "✓ \(fileSizeString(at: product.imageURL))" : "✗ 不存在")")
        print("")
    }
}

func missingRequiredFiles(privateKeyURL: URL, products: [IAPProduct]) -> [String] {
    var missing: [String] = []
    if !FileManager.default.fileExists(atPath: privateKeyURL.path) {
        missing.append(privateKeyURL.path)
    }
    for product in products where !FileManager.default.fileExists(atPath: product.imageURL.path) {
        missing.append("\(product.productID): \(product.imageURL.path)")
    }
    return missing
}

class AppStoreConnectAPI {
    private let keyID: String
    private let issuerID: String
    private let privateKeyURL: URL
    private let baseURL = "https://api.appstoreconnect.apple.com"
    private let session: URLSession
    private var territories: [String]?
    private var signingKey: P256.Signing.PrivateKey?

    init(keyID: String, issuerID: String, privateKeyURL: URL) {
        self.keyID = keyID
        self.issuerID = issuerID
        self.privateKeyURL = privateKeyURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: configuration)
    }

    func generateJWT() throws -> String {
        let key = try loadSigningKey()
        let header: [String: Any] = [
            "alg": "ES256",
            "kid": keyID,
            "typ": "JWT",
        ]
        let now = Date()
        let payload: [String: Any] = [
            "iss": issuerID,
            "iat": Int64(now.timeIntervalSince1970),
            "exp": Int64(now.addingTimeInterval(1200).timeIntervalSince1970),
            "aud": "appstoreconnect-v1",
        ]

        let headerBase64 = base64URLEncode(try JSONSerialization.data(withJSONObject: header))
        let payloadBase64 = base64URLEncode(try JSONSerialization.data(withJSONObject: payload))
        let message = "\(headerBase64).\(payloadBase64)"
        guard let messageData = message.data(using: .utf8) else {
            throw ScriptError("JWT 消息编码失败")
        }
        let signature: P256.Signing.ECDSASignature
        do {
            signature = try key.signature(for: SHA256.hash(data: messageData))
        } catch {
            throw ScriptError("JWT 签名失败: \(errorMessage(error))")
        }
        let signatureBase64 = base64URLEncode(signature.rawRepresentation)
        return "\(message).\(signatureBase64)"
    }

    func createInAppPurchase(appID: String, productName: String, productID: String) async throws -> [String: Any] {
        let payload: [String: Any] = [
            "data": [
                "type": "inAppPurchases",
                "attributes": [
                    "name": productName,
                    "productId": productID,
                    "inAppPurchaseType": "CONSUMABLE",
                ],
                "relationships": [
                    "app": [
                        "data": [
                            "type": "apps",
                            "id": appID,
                        ],
                    ],
                ],
            ],
        ]
        return try await apiRequest(path: "/v2/inAppPurchases", method: "POST", json: payload)
    }

    func createLocalization(inAppPurchaseID: String, displayName: String, description: String, locale: String) async throws -> [String: Any] {
        let payload: [String: Any] = [
            "data": [
                "type": "inAppPurchaseLocalizations",
                "attributes": [
                    "locale": locale,
                    "name": displayName,
                    "description": description,
                ],
                "relationships": [
                    "inAppPurchaseV2": [
                        "data": [
                            "type": "inAppPurchases",
                            "id": inAppPurchaseID,
                        ],
                    ],
                ],
            ],
        ]
        return try await apiRequest(path: "/v1/inAppPurchaseLocalizations", method: "POST", json: payload)
    }

    func pricePointID(for iapID: String, price: String) async throws -> String? {
        let path = "/v2/inAppPurchases/\(iapID)/pricePoints?include=territory&filter[territory]=USA&limit=8000"
        let response = try await apiRequest(path: path, method: "GET")
        guard let data = response["data"] as? [[String: Any]] else {
            return nil
        }
        return data.first(where: { point in
            let customerPrice = (point["attributes"] as? [String: Any])?["customerPrice"] as? String ?? ""
            return pricesMatch(customerPrice, price)
        })?["id"] as? String
    }

    func setPrice(iapID: String, pricePointID: String) async throws -> [String: Any] {
        let payload: [String: Any] = [
            "data": [
                "type": "inAppPurchasePriceSchedules",
                "attributes": [:] as [String: Any],
                "relationships": [
                    "inAppPurchase": [
                        "data": [
                            "type": "inAppPurchases",
                            "id": iapID,
                        ],
                    ],
                    "manualPrices": [
                        "data": [[
                            "type": "inAppPurchasePrices",
                            "id": "${newprice-0}",
                        ]],
                    ],
                    "baseTerritory": [
                        "data": [
                            "type": "territories",
                            "id": "USA",
                        ],
                    ],
                ],
            ],
            "included": [[
                "type": "inAppPurchasePrices",
                "id": "${newprice-0}",
                "attributes": [
                    "startDate": NSNull(),
                ],
                "relationships": [
                    "inAppPurchasePricePoint": [
                        "data": [
                            "type": "inAppPurchasePricePoints",
                            "id": pricePointID,
                        ],
                    ],
                ],
            ]],
        ]
        return try await apiRequest(path: "/v1/inAppPurchasePriceSchedules", method: "POST", json: payload)
    }

    func setGlobalAvailability(iapID: String) async throws {
        let territories = try await allTerritories()
        if territories.isEmpty {
            print("⚠️  无法获取地区列表，跳过全球可用性设置")
            return
        }

        print("设置全球可用性，共 \(territories.count) 个地区...")
        let payload: [String: Any] = [
            "data": [
                "type": "inAppPurchaseAvailabilities",
                "attributes": [
                    "availableInNewTerritories": true,
                ],
                "relationships": [
                    "inAppPurchase": [
                        "data": [
                            "type": "inAppPurchases",
                            "id": iapID,
                        ],
                    ],
                    "availableTerritories": [
                        "data": territories.map { ["type": "territories", "id": $0] },
                    ],
                ],
            ],
        ]
        do {
            _ = try await apiRequest(path: "/v1/inAppPurchaseAvailabilities", method: "POST", json: payload)
            print("✅ 全球可用性设置成功")
        } catch {
            print("⚠️  全球可用性设置失败: \(errorMessage(error))")
        }
    }

    func uploadScreenshot(inAppPurchaseID: String, imageURL: URL) async throws -> String {
        guard FileManager.default.fileExists(atPath: imageURL.path) else {
            throw ScriptError("截图文件不存在: \(imageURL.path)")
        }

        let fileData = try Data(contentsOf: imageURL)
        let fileName = imageURL.lastPathComponent
        let md5Hash = Insecure.MD5.hash(data: fileData).map { String(format: "%02x", $0) }.joined()

        if let existing = try await fetchReviewScreenshot(inAppPurchaseID: inAppPurchaseID),
           let existingID = (existing["data"] as? [String: Any])?["id"] as? String {
            let attributes = (existing["data"] as? [String: Any])?["attributes"] as? [String: Any] ?? [:]
            let checksum = (attributes["sourceFileChecksum"] as? String ?? "").lowercased()
            let state = assetDeliveryState(from: attributes)
            let operations = attributes["uploadOperations"] as? [[String: Any]] ?? []
            let existingSize = (attributes["fileSize"] as? NSNumber)?.intValue

            if checksum == md5Hash && (state == "UPLOAD_COMPLETE" || state == "COMPLETE") {
                print("截图未变化（\(state)），跳过上传")
                print("✅ 截图已是最新")
                return existingID
            }

            if !operations.isEmpty && (existingSize == nil || existingSize == fileData.count) {
                print("复用未完成的截图预留: \(existingID)")
                return try await finishScreenshotUpload(
                    screenshotID: existingID,
                    operations: operations,
                    imageURL: imageURL,
                    md5Hash: md5Hash
                )
            }

            print("删除现有截图并按最新文件重新上传...")
            _ = try await apiRequest(path: "/v1/inAppPurchaseAppStoreReviewScreenshots/\(existingID)", method: "DELETE")
        }

        print("步骤1: 创建截图预留...")
        let reservation = try await createScreenshotReservation(
            inAppPurchaseID: inAppPurchaseID,
            fileName: fileName,
            fileSize: fileData.count
        )
        guard let data = reservation["data"] as? [String: Any],
              let screenshotID = data["id"] as? String else {
            throw ScriptError("截图预留响应缺少 id")
        }
        let attributes = data["attributes"] as? [String: Any] ?? [:]
        let state = assetDeliveryState(from: attributes)
        print("截图ID: \(screenshotID)")

        if state == "UPLOAD_COMPLETE" || state == "COMPLETE" {
            print("现有截图已是 \(state)，跳过上传")
            print("✅ 截图上传成功！")
            return screenshotID
        }

        guard let operations = attributes["uploadOperations"] as? [[String: Any]], !operations.isEmpty else {
            throw ScriptError("截图预留响应缺少 uploadOperations")
        }
        return try await finishScreenshotUpload(
            screenshotID: screenshotID,
            operations: operations,
            imageURL: imageURL,
            md5Hash: md5Hash
        )
    }

    func createBatch(appID: String, products: [IAPProduct]) async -> [IAPResult] {
        var results: [IAPResult] = []
        for product in products {
            var iapID: String?
            do {
                var isUpdate = false
                if let existingID = try await findInAppPurchaseID(appID: appID, productID: product.productID) {
                    iapID = existingID
                    isUpdate = true
                } else {
                    print("创建内购项: \(product.productID) ($\(product.price))...")
                    do {
                        let iapResponse = try await createInAppPurchase(appID: appID, productName: product.name, productID: product.productID)
                        guard let createdID = (iapResponse["data"] as? [String: Any])?["id"] as? String else {
                            throw ScriptError("创建内购项成功但未返回 ID")
                        }
                        iapID = createdID
                    } catch let error as APIHTTPError where error.statusCode == 409 {
                        guard let existingID = try await findInAppPurchaseID(appID: appID, productID: product.productID) else {
                            throw error
                        }
                        iapID = existingID
                        isUpdate = true
                    }
                }

                guard let iapID else {
                    throw ScriptError("未获得内购项 ID")
                }

                if isUpdate {
                    print("内购项已存在，按最新设置更新: \(product.productID) ($\(product.price))...")
                    try await updateInAppPurchaseName(iapID: iapID, name: product.name)
                }

                try await upsertLocalization(
                    inAppPurchaseID: iapID,
                    displayName: product.displayName,
                    description: product.description,
                    locale: "en-US"
                )
                let (pricePointID, screenshotID) = try await applyPriceAvailabilityAndScreenshot(iapID: iapID, product: product)
                results.append(
                    IAPResult(
                        productID: product.productID,
                        price: product.price,
                        iapID: iapID,
                        pricePointID: pricePointID,
                        screenshotID: screenshotID,
                        status: isUpdate ? "updated" : "created",
                        error: nil
                    )
                )
                print("✅ \(product.productID) 内购项\(isUpdate ? "更新" : "创建")完成")
            } catch {
                let message = errorMessage(error)
                results.append(
                    IAPResult(
                        productID: product.productID,
                        price: product.price,
                        iapID: iapID,
                        pricePointID: nil,
                        screenshotID: nil,
                        status: "failed",
                        error: message
                    )
                )
                print("❌ \(product.productID) 内购项处理失败: \(message)")
            }
            print("")
        }
        return results
    }

    private func findInAppPurchaseID(appID: String, productID: String) async throws -> String? {
        let encoded = productID.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+="))) ?? productID
        let response = try await apiRequest(
            path: "/v1/apps/\(appID)/inAppPurchasesV2?filter[productId]=\(encoded)&limit=200",
            method: "GET"
        )
        let items = response["data"] as? [[String: Any]] ?? []
        return items.first(where: { item in
            ((item["attributes"] as? [String: Any])?["productId"] as? String) == productID
        })?["id"] as? String
    }

    private func updateInAppPurchaseName(iapID: String, name: String) async throws {
        print("更新 Reference Name...")
        let payload: [String: Any] = [
            "data": [
                "type": "inAppPurchases",
                "id": iapID,
                "attributes": [
                    "name": name,
                ],
            ],
        ]
        _ = try await apiRequest(path: "/v2/inAppPurchases/\(iapID)", method: "PATCH", json: payload)
    }

    private func upsertLocalization(inAppPurchaseID: String, displayName: String, description: String, locale: String) async throws {
        let response = try await apiRequest(
            path: "/v2/inAppPurchases/\(inAppPurchaseID)/inAppPurchaseLocalizations?limit=200",
            method: "GET"
        )
        let items = response["data"] as? [[String: Any]] ?? []
        if let existingID = items.first(where: { item in
            ((item["attributes"] as? [String: Any])?["locale"] as? String) == locale
        })?["id"] as? String {
            print("更新本地化信息 (\(locale))...")
            let payload: [String: Any] = [
                "data": [
                    "type": "inAppPurchaseLocalizations",
                    "id": existingID,
                    "attributes": [
                        "name": displayName,
                        "description": description,
                    ],
                ],
            ]
            _ = try await apiRequest(path: "/v1/inAppPurchaseLocalizations/\(existingID)", method: "PATCH", json: payload)
            return
        }

        print("创建本地化信息 (\(locale))...")
        do {
            _ = try await createLocalization(
                inAppPurchaseID: inAppPurchaseID,
                displayName: displayName,
                description: description,
                locale: locale
            )
        } catch let error as APIHTTPError where error.statusCode == 409 {
            let retry = try await apiRequest(
                path: "/v2/inAppPurchases/\(inAppPurchaseID)/inAppPurchaseLocalizations?limit=200",
                method: "GET"
            )
            guard let existingID = (retry["data"] as? [[String: Any]] ?? []).first(where: { item in
                ((item["attributes"] as? [String: Any])?["locale"] as? String) == locale
            })?["id"] as? String else {
                throw error
            }
            print("本地化已存在，改为更新 (\(locale))...")
            let payload: [String: Any] = [
                "data": [
                    "type": "inAppPurchaseLocalizations",
                    "id": existingID,
                    "attributes": [
                        "name": displayName,
                        "description": description,
                    ],
                ],
            ]
            _ = try await apiRequest(path: "/v1/inAppPurchaseLocalizations/\(existingID)", method: "PATCH", json: payload)
        }
    }

    private func applyPriceAvailabilityAndScreenshot(iapID: String, product: IAPProduct) async throws -> (String?, String) {
        print("获取价格档位...")
        let pricePointID = try await pricePointID(for: iapID, price: product.price)
        if let pricePointID {
            print("设置价格档位...")
            _ = try await setPrice(iapID: iapID, pricePointID: pricePointID)
        } else {
            print("⚠️  未找到 $\(product.price) 对应的美国区价格档位")
        }

        print("设置全球销售范围...")
        try await setGlobalAvailability(iapID: iapID)

        print("上传审核截图...")
        let screenshotID = try await uploadScreenshot(inAppPurchaseID: iapID, imageURL: product.imageURL)
        return (pricePointID, screenshotID)
    }

    private func finishScreenshotUpload(screenshotID: String, operations: [[String: Any]], imageURL: URL, md5Hash: String) async throws -> String {
        print("步骤2: 上传文件数据...")
        try await uploadFileData(operations: operations, fileURL: imageURL)

        print("步骤3: 提交截图...")
        let commit = try await commitScreenshot(screenshotID: screenshotID, md5Hash: md5Hash)
        let finalState = assetDeliveryState(from: (commit["data"] as? [String: Any])?["attributes"] as? [String: Any] ?? [:])
        print("提交成功！")
        print("最终状态: \(finalState)")
        if finalState == "UPLOAD_COMPLETE" || finalState == "COMPLETE" {
            print("✅ 截图上传成功！")
        } else {
            print("⚠️  截图当前状态: \(finalState)")
        }
        return screenshotID
    }

    private func allTerritories() async throws -> [String] {
        if let territories {
            return territories
        }
        print("获取所有可用地区列表...")
        let response = try await apiRequest(path: "/v1/territories?limit=200", method: "GET")
        let ids = (response["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        territories = ids
        print("✅ 获取到 \(ids.count) 个可用地区")
        return ids
    }

    private func createScreenshotReservation(inAppPurchaseID: String, fileName: String, fileSize: Int) async throws -> [String: Any] {
        let payload: [String: Any] = [
            "data": [
                "type": "inAppPurchaseAppStoreReviewScreenshots",
                "attributes": [
                    "fileName": fileName,
                    "fileSize": fileSize,
                ],
                "relationships": [
                    "inAppPurchaseV2": [
                        "data": [
                            "type": "inAppPurchases",
                            "id": inAppPurchaseID,
                        ],
                    ],
                ],
            ],
        ]

        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await apiRequest(
                    path: "/v1/inAppPurchaseAppStoreReviewScreenshots",
                    method: "POST",
                    json: payload,
                    retryServerErrors: false
                )
            } catch let error as APIHTTPError {
                if let existing = try await fetchReviewScreenshot(inAppPurchaseID: inAppPurchaseID) {
                    let attributes = (existing["data"] as? [String: Any])?["attributes"] as? [String: Any] ?? [:]
                    let operations = attributes["uploadOperations"] as? [[String: Any]] ?? []
                    let state = assetDeliveryState(from: attributes)
                    if !operations.isEmpty || state == "UPLOAD_COMPLETE" || state == "COMPLETE" {
                        print("⚠️  创建预留返回 HTTP \(error.statusCode)，但截图已存在，复用截图ID")
                        return existing
                    }
                    if let screenshotID = (existing["data"] as? [String: Any])?["id"] as? String {
                        print("现有截图不可用（状态: \(state)），删除后重新创建...")
                        _ = try await apiRequest(path: "/v1/inAppPurchaseAppStoreReviewScreenshots/\(screenshotID)", method: "DELETE")
                    }
                }
                if error.statusCode == 409 {
                    throw ScriptError("截图已存在但无法读取现有资源: \(error.body)")
                }
                guard error.statusCode >= 500 || error.statusCode == 429 else {
                    throw error
                }
                print("⚠️  API POST /v1/inAppPurchaseAppStoreReviewScreenshots HTTP \(error.statusCode)，2秒后重试 (第 \(attempt) 次)...")
                print("Error response body: \(error.body)")
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func fetchReviewScreenshot(inAppPurchaseID: String) async throws -> [String: Any]? {
        let paths = [
            "/v2/inAppPurchases/\(inAppPurchaseID)/appStoreReviewScreenshot",
            "/v1/inAppPurchases/\(inAppPurchaseID)/appStoreReviewScreenshot",
        ]
        var response: [String: Any]?
        for path in paths {
            do {
                response = try await apiRequest(path: path, method: "GET")
                break
            } catch let error as APIHTTPError where error.statusCode == 404 {
                continue
            }
        }
        if response == nil {
            let included = try await apiRequest(
                path: "/v2/inAppPurchases/\(inAppPurchaseID)?include=appStoreReviewScreenshot",
                method: "GET"
            )
            if let screenshots = included["included"] as? [[String: Any]],
               let screenshot = screenshots.first(where: { $0["type"] as? String == "inAppPurchaseAppStoreReviewScreenshots" }) {
                response = ["data": screenshot]
            }
        }
        guard let response,
              let data = response["data"] as? [String: Any],
              data["id"] as? String != nil else {
            return nil
        }
        return response
    }

    private func commitScreenshot(screenshotID: String, md5Hash: String) async throws -> [String: Any] {
        let payload: [String: Any] = [
            "data": [
                "type": "inAppPurchaseAppStoreReviewScreenshots",
                "id": screenshotID,
                "attributes": [
                    "uploaded": true,
                    "sourceFileChecksum": md5Hash,
                ],
            ],
        ]
        return try await apiRequest(path: "/v1/inAppPurchaseAppStoreReviewScreenshots/\(screenshotID)", method: "PATCH", json: payload)
    }

    private func uploadFileData(operations: [[String: Any]], fileURL: URL) async throws {
        for operation in operations {
            let method = operation["method"] as? String ?? "PUT"
            guard let urlString = operation["url"] as? String, let url = URL(string: urlString) else {
                throw ScriptError("上传操作缺少 url")
            }
            let headers = operation["requestHeaders"] as? [[String: Any]] ?? []
            let offset = (operation["offset"] as? NSNumber)?.intValue ?? 0
            let length = (operation["length"] as? NSNumber)?.intValue
            let chunk = try readFileChunk(url: fileURL, offset: offset, length: length)
            try await uploadToPresignedURL(method: method, url: url, headers: headers, fileData: chunk)
            print("上传文件成功")
        }
    }

    private func uploadToPresignedURL(method: String, url: URL, headers: [[String: Any]], fileData: Data) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = fileData
        request.setValue(nil, forHTTPHeaderField: "Content-Type")
        for header in headers {
            if let name = header["name"] as? String, let value = header["value"] as? String {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }

        _ = try await sendRequest(request, label: "上传 \(url.host ?? url.absoluteString)")
    }

    private func apiRequest(path: String, method: String, json: [String: Any]? = nil, retryServerErrors: Bool = true) async throws -> [String: Any] {
        guard let url = URL(string: baseURL + path) else {
            throw ScriptError("无效 URL: \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(try generateJWT())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }

        let data = try await sendRequest(request, label: "API \(method) \(path)", retryServerErrors: retryServerErrors)
        if data.isEmpty {
            return [:]
        }
        return try jsonObject(data)
    }

    private func sendRequest(_ request: URLRequest, label: String, retryServerErrors: Bool = true) async throws -> Data {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    print("⚠️  \(label) 未返回 HTTP 响应，2秒后重试 (第 \(attempt) 次)...")
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                if (200..<300).contains(http.statusCode) {
                    return data
                }
                let body = String(data: data, encoding: .utf8) ?? ""
                let error = APIHTTPError(statusCode: http.statusCode, data: data)
                let shouldRetry = http.statusCode == 429 || (retryServerErrors && http.statusCode >= 500)
                if !shouldRetry {
                    print("⚠️  \(label) HTTP \(http.statusCode)")
                    print("Error response body: \(body)")
                    throw error
                }
                print("⚠️  \(label) HTTP \(http.statusCode)，2秒后重试 (第 \(attempt) 次)...")
                print("Error response body: \(body)")
            } catch let error as APIHTTPError {
                throw error
            } catch {
                print("⚠️  \(label) 请求失败: \(errorMessage(error))，2秒后重试 (第 \(attempt) 次)...")
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func loadSigningKey() throws -> P256.Signing.PrivateKey {
        if let signingKey {
            return signingKey
        }
        let privateKeyData = try Data(contentsOf: privateKeyURL)
        guard let privateKeyString = String(data: privateKeyData, encoding: .utf8) else {
            throw ScriptError("Failed to read private key as UTF-8 string")
        }
        let key: P256.Signing.PrivateKey
        do {
            key = try P256.Signing.PrivateKey(pemRepresentation: privateKeyString)
        } catch {
            throw ScriptError("无法解析私钥: \(errorMessage(error))")
        }
        signingKey = key
        return key
    }

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    private func readFileChunk(url: URL, offset: Int, length: Int?) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        if let length {
            return handle.readData(ofLength: length)
        }
        return handle.readDataToEndOfFile()
    }
}

func loadConfig(from url: URL) throws -> IAPConfig {
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw ScriptError("配置文件不存在: \(url.path)")
    }
    do {
        return try JSONDecoder().decode(IAPConfig.self, from: Data(contentsOf: url))
    } catch {
        throw ScriptError("配置文件解析失败: \(errorMessage(error))")
    }
}

func printResults(_ results: [IAPResult]) {
    print("🎉 内购项处理完成！")
    print("📊 结果统计:")
    let created = results.filter { $0.status == "created" }
    let updated = results.filter { $0.status == "updated" }
    let failed = results.filter { $0.status == "failed" }

    func printSuccess(_ result: IAPResult, prefix: String) {
        print("  - \(prefix)$\(result.price): \(result.productID) (ID: \(result.iapID ?? ""))")
        if let pricePointID = result.pricePointID {
            print("    价格档位ID: \(pricePointID)")
        }
        print("    📸 截图ID: \(result.screenshotID ?? "")")
    }

    print("✅ 新建: \(created.count) 个")
    created.forEach { printSuccess($0, prefix: "") }
    print("🔄 更新: \(updated.count) 个")
    updated.forEach { printSuccess($0, prefix: "") }

    print("❌ 失败: \(failed.count) 个")
    for result in failed {
        print("  - \(result.productID): 失败 - \(result.error ?? "")")
    }

    print("\n📍 请在App Store Connect中完成最终审核提交")
}

func run() async throws {
    print("App Store Connect API - 内购项批量创建/更新工具")
    print("")

    let directory = scriptDirectoryURL()
    let configURL = directory.appendingPathComponent("iap_config.json")
    let config = try loadConfig(from: configURL)
    let csvURL = directory.appendingPathComponent("iap_products.csv")
    guard FileManager.default.fileExists(atPath: csvURL.path) else {
        throw ScriptError("CSV 文件不存在: \(csvURL.path)")
    }

    let products = try loadProducts(from: csvURL, baseDirectory: directory)
    let privateKeyURL = directory.appendingPathComponent("AuthKey_\(config.keyID).p8")

    printPreview(config: config, configURL: configURL, csvURL: csvURL, privateKeyURL: privateKeyURL, products: products)

    let missing = missingRequiredFiles(privateKeyURL: privateKeyURL, products: products)
    if !missing.isEmpty {
        print("❌ 以下文件缺失，无法开始上传:")
        missing.forEach { print("  - \($0)") }
        return
    }

    guard confirm("请确认以上信息无误。已存在的内购项会按 CSV 更新。输入 y 开始，其他输入取消：") else {
        print("已取消")
        return
    }

    print("")
    print("🚀 开始批量创建/更新内购项...")
    print("")

    let api = AppStoreConnectAPI(keyID: config.keyID, issuerID: config.issuerID, privateKeyURL: privateKeyURL)
    let results = await api.createBatch(appID: config.appID, products: products)
    printResults(results)
}

do {
    try await run()
} catch {
    fputs("❌ 操作失败: \(errorMessage(error))\n", stderr)
    exit(1)
}
