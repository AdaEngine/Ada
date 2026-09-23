import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import Security
import StoreKit

#if os(macOS)
    import AppKit
#elseif os(iOS)
    import UIKit
#endif

@MainActor
@Observable
final class EditorCloudAccount: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = EditorCloudAccount()
    var server =
        ProcessInfo.processInfo.environment["ADA_CLOUD_API_URL"] ?? UserDefaults.standard
        .string(forKey: "AdaEditor.cloud.server") ?? (Bundle.main.object(forInfoDictionaryKey: "AdaCloudAPIURL") as? String ?? "")
    var status = ""
    var busy = false
    var accountID: String?
    var pro = false
    var cloudServicesAvailable = false
    var billingAvailable = false
    private var availability: EditorCloudValue = [:]
    var publicationURL: String?
    var expiresAt: Date?
    var applySettings: ((EditorCloudValue) -> Void)?
    @ObservationIgnored private var credentials: EditorCloudValue = [:]
    @ObservationIgnored private var authentication: ASWebAuthenticationSession?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var transactionLoop: Task<Void, Never>?
    @ObservationIgnored private var applying = false
    @ObservationIgnored private var syncing = false
    @ObservationIgnored private var refreshTask: Task<EditorCloudValue, Error>?
    static let settingKeys = ["appearance.agentActivityGlowEnabled", "appearance.agentGlowAccent", "appearance.agentGlowRadius", "appearance.agentGlowOpacity", "editor.fontSize"]

    override init() {
        super.init()
        if let data = try? Self.keychainRead(), let value = try? JSONDecoder().decode(EditorCloudValue.self, from: data), value["server"].string == server {
            credentials = value
            accountID = value["accountId"].string
        }
    }
    func start() {
        guard loop == nil else {
            return
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                if let self, self.accountID != nil {
                    do { try await self.sync() } catch { self.status = "Settings saved locally. Sync will retry: \(error.localizedDescription)" }
                }
                try? await Task.sleep(for: .seconds(10))
            }
        }
        transactionLoop = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self, self.accountID != nil else {
                    continue
                }
                do { try await self.acceptPurchase(update) } catch { self.status = "Purchase verification will retry: \(error.localizedDescription)" }
            }
        }
    }
    func perform(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else {
            return
        }
        busy = true
        Task {
            defer { busy = false }
            do { try await work() } catch { status = error.localizedDescription }
        }
    }
    func signInOnWebsite() async throws {
        guard let endpoint = URL(string: server), Self.isAllowedCloudURL(endpoint) else {
            throw CloudError.message("Cloud sign-in is not configured for this build.")
        }
        if credentials["server"].string != nil && credentials["server"].string != server {
            try clearSession()
        }
        let verifier = Self.base64URL(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        let state = Self.base64URL(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let request = try await self.request("/auth/desktop/start", method: "POST", body: ["challenge": .string(challenge), "state": .string(state)], authenticated: false)
        guard
            let address = request["authorizeURL"].string, let authorizeURL = URL(string: address),
            Self.isAllowedCloudURL(authorizeURL), authorizeURL.host == endpoint.host,
            authorizeURL.port == endpoint.port, authorizeURL.scheme == endpoint.scheme
        else {
            throw CloudError.message("Unexpected sign-in website")
        }
        status = "Complete sign-in on the Ada website."
        defer { authentication = nil }
        let callback = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: authorizeURL, callbackURLScheme: "adaeditor") { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? CloudError.message("Sign-in cancelled"))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            authentication = session
            if !session.start() {
                continuation.resume(throwing: CloudError.message("Unable to open the sign-in website"))
            }
        }
        let code = try Self.exchangeCode(from: callback, expectedState: state)
        try await saveSession(try await self.request("/auth/exchange", method: "POST", body: ["code": .string(code), "verifier": .string(verifier)], authenticated: false))
    }
    static func isAllowedCloudURL(_ url: URL) -> Bool {
        guard url.host != nil, url.user == nil, url.password == nil else {
            return false
        }
        if url.scheme == "https" {
            return true
        }
        #if DEBUG
            return url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")
        #else
            return false
        #endif
    }
    static func exchangeCode(from url: URL, expectedState: String) throws -> String {
        guard
            url.scheme == "adaeditor", url.host == "cloud", url.path == "/callback", url.fragment == nil,
            let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let items = parts.queryItems,
            items.filter({ $0.name == "state" }).count == 1,
            items.first(where: { $0.name == "state" })?.value == expectedState,
            items.filter({ $0.name == "code" }).count == 1,
            let code = items.first(where: { $0.name == "code" })?.value,
            code.count == 43, code.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
        else {
            throw CloudError.message("Invalid sign-in callback. Please start sign-in again.")
        }
        return code
    }
    private func saveSession(_ value: EditorCloudValue) async throws {
        if let owner = value["accountId"].string, owner != accountID {
            let neutralKey = "AdaEditor.cloud.neutralSettings"
            if UserDefaults.standard.data(forKey: neutralKey) == nil {
                UserDefaults.standard.set(try JSONEncoder().encode(localSettings()), forKey: neutralKey)
            }
            let existing = UserDefaults.standard.data(forKey: "AdaEditor.cloud.sync." + owner).flatMap { try? JSONDecoder().decode(EditorCloudValue.self, from: $0) }?["baseline"]
            let neutral = UserDefaults.standard.data(forKey: neutralKey).flatMap { try? JSONDecoder().decode(EditorCloudValue.self, from: $0) }
            if let baseline = existing ?? neutral {
                try applyLocal(baseline)
            }
        }
        credentials = value
        credentials["server"] = .string(server)
        accountID = value["accountId"].string
        try Self.keychainWrite(JSONEncoder().encode(credentials))
        try await refreshPlan()
        if cloudServicesAvailable {
            try await sync()
            status = "Signed in. Settings synced."
        } else {
            status = "Signed in. Cloud Services will open soon."
        }
        start()
    }
    func refreshPlan() async throws {
        let plan = try await request("/billing")
        pro = plan["pro"].bool ?? false
        applyAvailability(plan["availability"])
        expiresAt = plan["expiresAt"].seconds > 0 ? Date(timeIntervalSince1970: plan["expiresAt"].seconds) : nil
    }
    private func applyAvailability(_ value: EditorCloudValue) {
        availability = value
        cloudServicesAvailable = value["cloudServicesAvailable"].bool == true
        billingAvailable = value["billingAvailable"].bool == true
    }
    private func refreshAvailability() async throws {
        cloudServicesAvailable = false
        billingAvailable = false
        applyAvailability(try await request("/availability"))
    }
    func signOut() async throws {
        try? await sync()
        _ = try await request("/auth/logout", method: "POST", body: [:])
        try clearSession()
        status = "Signed out on all devices."
    }
    private func clearSession() throws {
        credentials = [:]
        accountID = nil
        pro = false
        publicationURL = nil
        cloudServicesAvailable = false
        billingAvailable = false
        availability = [:]
        Self.keychainDelete()
        if let data = UserDefaults.standard.data(forKey: "AdaEditor.cloud.neutralSettings"), let neutral = try? JSONDecoder().decode(EditorCloudValue.self, from: data) {
            try applyLocal(neutral)
        }
    }
    private func localSettings() -> EditorCloudValue {
        var result: EditorCloudValue = [:]
        for key in Self.settingKeys {
            if let raw = UserDefaults.standard.object(forKey: "AdaEditor." + key), let data = try? JSONSerialization.data(withJSONObject: raw, options: .fragmentsAllowed),
                let value = try? JSONDecoder().decode(EditorCloudValue.self, from: data) {
                result[key] = value
            } else {
                result[key] = .null
            }
        }
        return result
    }
    private func applyLocal(_ values: EditorCloudValue) throws {
        for key in Self.settingKeys {
            if values[key] == .null {
                UserDefaults.standard.removeObject(forKey: "AdaEditor." + key)
            } else {
                UserDefaults.standard.set(try JSONSerialization.jsonObject(with: JSONEncoder().encode(values[key]), options: .fragmentsAllowed), forKey: "AdaEditor." + key)
            }
        }
        applySettings?(values)
    }
    func sync() async throws {
        guard let owner = accountID, !applying, !syncing else {
            return
        }
        syncing = true
        defer { syncing = false }
        try await refreshAvailability()
        guard cloudServicesAvailable else {
            status = "Cloud Services will open soon."
            return
        }
        let key = "AdaEditor.cloud.sync." + owner
        var state = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(EditorCloudValue.self, from: $0) } ?? [:]
        var local: EditorCloudValue = [:]
        for setting in Self.settingKeys {
            if let value = UserDefaults.standard.object(forKey: "AdaEditor." + setting), let bytes = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
                let json = try? JSONDecoder().decode(EditorCloudValue.self, from: bytes) {
                local[setting] = json
            } else {
                local[setting] = .null
            }
        }
        let previous = state["baseline"]
        if previous != .null {
            var changes: EditorCloudValue = [:]
            for setting in Self.settingKeys where local[setting] != previous[setting] { changes[setting] = local[setting] }
            if !changes.object.isEmpty {
                var queue = state["queue"].array
                queue.append(["operationId": .string(UUID().uuidString), "changes": changes])
                state["queue"] = .array(queue)
                state["baseline"] = local
                UserDefaults.standard.set(try JSONEncoder().encode(state), forKey: key)
            }
        }
        // Retried mutations keep their operation IDs and never replay a whole stale snapshot.
        for operation in state["queue"].array {
            guard accountID == owner else {
                return
            }
            _ = try await request("/settings", method: "PATCH", body: operation)
            var queue = state["queue"].array
            if !queue.isEmpty {
                queue.removeFirst()
            }
            state["queue"] = .array(queue)
            UserDefaults.standard.set(try JSONEncoder().encode(state), forKey: key)
        }
        if previous == .null {
            _ = try await request("/settings", method: "PATCH", body: ["operationId": .string(UUID().uuidString), "changes": local, "onlyMissing": true])
        }
        let snapshot = try await request("/settings")
        guard accountID == owner else {
            return
        }
        let currentLocal = localSettings()
        var visibleValues = snapshot["values"]
        for setting in Self.settingKeys where currentLocal[setting] != local[setting] { visibleValues[setting] = currentLocal[setting] }
        applying = true
        defer { applying = false }
        for setting in Self.settingKeys {
            let value = visibleValues[setting]
            if value == .null {
                UserDefaults.standard.removeObject(forKey: "AdaEditor." + setting)
            } else {
                let bytes = try JSONEncoder().encode(value)
                UserDefaults.standard.set(try JSONSerialization.jsonObject(with: bytes, options: .fragmentsAllowed), forKey: "AdaEditor." + setting)
            }
        }
        state["baseline"] = snapshot["values"]
        UserDefaults.standard.set(try JSONEncoder().encode(state), forKey: key)
        applySettings?(visibleValues)
    }
    func buyPro() async throws {
        guard let owner = accountID.flatMap(UUID.init(uuidString:)) else {
            throw CloudError.message("Sign in before purchasing Pro.")
        }
        try await refreshAvailability()
        guard billingAvailable, cloudServicesAvailable else {
            throw CloudError.message("Cloud Services will open soon.")
        }
        if availability["mode"].string != "worldwide" {
            guard
                let storefront = await Storefront.current,
                availability["allowedAppleStorefronts"].array.contains(where: { $0.string == storefront.countryCode })
            else {
                throw CloudError.message("Cloud Services will open soon in your App Store region.")
            }
        }
        guard let id = Bundle.main.object(forInfoDictionaryKey: "AdaCloudProProductID") as? String, !id.isEmpty else {
            throw CloudError.message("App Store Pro is not configured for this build.")
        }
        guard let product = try await Product.products(for: [id]).first else {
            throw CloudError.message("Pro is unavailable in this storefront.")
        }
        switch try await product.purchase(options: [.appAccountToken(owner)]) {
        case let .success(verification): try await acceptPurchase(verification)
        case .pending: status = "Purchase is awaiting approval."
        case .userCancelled: status = "Purchase cancelled."
        @unknown default: status = "Purchase status is unavailable."
        }
    }
    private func acceptPurchase(_ result: VerificationResult<Transaction>) async throws {
        guard case let .verified(transaction) = result else {
            throw CloudError.message("Unverified App Store transaction")
        }
        _ = try await request("/billing/apple/transaction", method: "POST", body: ["signedTransaction": .string(result.jwsRepresentation)])
        await transaction.finish()
        try await refreshPlan()
    }
    func restorePurchases() async throws {
        guard accountID != nil else {
            throw CloudError.message("Sign in before restoring purchases.")
        }
        try await AppStore.sync()
        for await result in Transaction.currentEntitlements { try await acceptPurchase(result) }
        try await refreshPlan()
        status = "Purchases restored."
    }
    func publish(zip: URL, mode: String = "invite", pageID: String? = nil) async throws {
        guard let owner = accountID else {
            throw CloudError.message("Sign in first.")
        }
        try await refreshAvailability()
        guard cloudServicesAvailable else {
            throw CloudError.message("Cloud Services will open soon.")
        }
        let scoped = zip.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                zip.stopAccessingSecurityScopedResource()
            }
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: zip.path)
        guard let bytes = attributes[.size] as? Int64, bytes > 0, bytes <= 300_000_000 else {
            throw CloudError.message("Choose a ZIP up to 300 MB.")
        }
        let fingerprint = owner + zip.lastPathComponent + String(bytes) + String((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) + mode + (pageID ?? "")
        let operationKey = "AdaEditor.cloud.upload." + Self.base64URL(Data(SHA256.hash(data: Data(fingerprint.utf8))))
        let operation = UserDefaults.standard.string(forKey: operationKey) ?? UUID().uuidString
        UserDefaults.standard.set(operation, forKey: operationKey)
        var upload = try await request(
            "/uploads",
            method: "POST",
            body: ["operationId": .string(operation), "bytes": .integer(bytes), "mode": .string(mode), "pageId": pageID.map(EditorCloudValue.string) ?? .null]
        )
        guard let id = upload["id"].string else {
            throw CloudError.message("Invalid upload response")
        }
        if upload["status"].string == "created" {
            guard let value = upload["uploadURL"].string, let url = URL(string: value), url.scheme == "https" else {
                throw CloudError.message("Upload endpoint must use HTTPS")
            }
            var put = URLRequest(url: url)
            put.httpMethod = "PUT"
            put.timeoutInterval = 600
            status = "Uploading web build…"
            let (_, response) = try await URLSession.shared.upload(for: put, fromFile: zip)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw CloudError.message("Upload interrupted. Retry to resume the same upload.")
            }
            upload = try await request("/uploads/" + id + "/complete", method: "POST", body: [:])
        }
        let deadline = Date().addingTimeInterval(1800)
        while ["queued", "processing"].contains(upload["status"].string ?? ""), Date() < deadline {
            status = "Checking web build…"
            try await Task.sleep(for: .seconds(2))
            upload = try await request("/uploads/" + id)
        }
        guard ["ready", "published"].contains(upload["status"].string ?? "") else {
            throw CloudError.message(upload["error"].string ?? "Build is not ready; retry later.")
        }
        let published = try await request("/uploads/" + id + "/publish", method: "POST", body: [:])
        publicationURL = published["url"].string
        UserDefaults.standard.removeObject(forKey: operationKey)
        status = "Published until " + Date(timeIntervalSince1970: published["expiresAt"].seconds).formatted()
    }
    func createMultiplayerRoom() async throws -> EditorCloudValue {
        guard accountID != nil else {
            throw CloudError.message("Sign in to AdaEngine Cloud before hosting a Web multiplayer room.")
        }
        return try await request("/multiplayer/sessions", method: "POST", body: [:])
    }

    func request(_ path: String, method: String = "GET", body: EditorCloudValue? = nil, authenticated: Bool = true, retry: Bool = true) async throws -> EditorCloudValue {
        guard let base = URL(string: server), Self.isAllowedCloudURL(base), let url = URL(string: server.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1" + path) else {
            throw CloudError.message("Cloud server is not configured.")
        }
        if authenticated, credentials["server"].string != server {
            throw CloudError.message("Sign in to this server first.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated, let token = credentials["accessToken"].string {
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudError.message("Invalid server response")
        }
        let result = (try? JSONDecoder().decode(EditorCloudValue.self, from: data)) ?? [:]
        if http.statusCode == 401, authenticated, retry, let refresh = credentials["refreshToken"].string {
            if refreshTask == nil {
                refreshTask = Task { try await self.request("/auth/refresh", method: "POST", body: ["refreshToken": .string(refresh)], authenticated: false, retry: false) }
            }
            guard let task = refreshTask else {
                throw CloudError.message("Unable to refresh session")
            }
            defer { refreshTask = nil }
            let refreshed = try await task.value
            credentials["accessToken"] = refreshed["accessToken"]
            credentials["refreshToken"] = refreshed["refreshToken"]
            try Self.keychainWrite(JSONEncoder().encode(credentials))
            return try await self.request(path, method: method, body: body, authenticated: authenticated, retry: false)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CloudError.message(result["error"]["message"].string ?? "Cloud request failed (\(http.statusCode))")
        }
        return result
    }
    func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
            NSApplication.shared.keyWindow ?? ASPresentationAnchor()
        #else
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        #endif
    }
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    private static var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.adaengine.cloud", kSecAttrAccount as String: "session"]
    }
    private static func keychainRead() throws -> Data? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &value)
        guard result == errSecSuccess || result == errSecItemNotFound else {
            throw CloudError.message("Keychain unavailable (\(result))")
        }
        return value as? Data
    }
    private static func keychainWrite(_ data: Data) throws {
        let result = SecItemUpdate(keychainQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            var query = keychainQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
                throw CloudError.message("Unable to save session in Keychain")
            }
        } else if result != errSecSuccess {
            throw CloudError.message("Unable to update Keychain")
        }
    }
    private static func keychainDelete() { SecItemDelete(keychainQuery as CFDictionary) }
    enum CloudError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case let .message(message) = self {
                message
            } else {
                nil
            }
        }
    }
}
