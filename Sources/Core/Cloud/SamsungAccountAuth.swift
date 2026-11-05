import CryptoKit
import Foundation

/// Samsung Account web sign-in for desktop: the user signs in on Samsung's own
/// page in the default browser, Samsung redirects to the `ms-app://` callback
/// that this app registers, and we exchange the code for tokens.
/// Protocol knowledge: charlesbel/samsung-re-health and samsung-re-find (MIT).
public struct SamsungAccountAuth: Sendable {
    /// Samsung Account SDK "master" client used for the browser sign-in.
    static let masterClientID = "yfrtglt53o"
    /// The Samsung Cloud app id for Reminder; assumed to double as its OAuth client id,
    /// as it does for Samsung Health. Unverified until a real sign-in succeeds.
    public static let reminderClientID = "8o8b82h22a"
    /// Samsung's registered callback for its own Windows app. Fixed; we only need to be its handler.
    public static let redirectURI = "ms-app://s-1-15-2-4027708247-2189610-1983755848-2937435718-1578786913-2158692839-1974417358"
    static let entryPointURL = URL(string: "https://account.samsung.com/accounts/ANDROIDSDK/getEntryPoint")!
    static let pendingMaxAge: TimeInterval = 15 * 60

    public enum AuthError: LocalizedError, Sendable {
        case entryPoint, untrustedURL(String), pendingExpired, redirectMismatch, missingParameter(String), decrypt
        case http(String, Int), malformed(String)
        public var errorDescription: String? {
            switch self {
            case .entryPoint: return "Samsung Account entry point is unavailable."
            case .untrustedURL(let host): return "Samsung returned an untrusted auth server (\(host))."
            case .pendingExpired: return "The sign-in attempt expired. Start again."
            case .redirectMismatch: return "The browser callback did not match this sign-in."
            case .missingParameter(let name): return "Samsung's callback is missing \(name)."
            case .decrypt: return "Could not decrypt Samsung's callback."
            case .http(let step, let status): return "Samsung \(step) failed with HTTP \(status)."
            case .malformed(let step): return "Samsung \(step) returned an unexpected response."
            }
        }
    }

    /// State kept between opening the browser and receiving the callback. In memory only.
    public struct Pending: Sendable {
        let state: String
        let verifier: String
        let deviceID: String
        let createdAt: Date
    }

    /// Everything a Samsung sign-in yields; stored inside `CloudCredential`.
    public struct Identity: Sendable, Equatable {
        public var authServer: String
        public var masterToken: String
        public var loginID: String
        public var userID: String
        public var deviceID: String
        public init(authServer: String, masterToken: String, loginID: String, userID: String, deviceID: String) {
            self.authServer = authServer; self.masterToken = masterToken; self.loginID = loginID; self.userID = userID; self.deviceID = deviceID
        }
    }

    public struct ServiceToken: Sendable, Equatable {
        public var accessToken: String
        public var refreshToken: String
        public var expiresAt: Date
    }

    let session: URLSession

    public init(session: URLSession = .cloud) { self.session = session }

    // MARK: Step 1 — build the sign-in URL

    public func start(existingDeviceID: String? = nil, locale: Locale = .current) async throws -> (url: URL, pending: Pending) {
        let entry = try await json(URLRequest(url: Self.entryPointURL, timeoutInterval: 20), step: "entry point")
        guard let signIn = entry["signInURI"].string, let iterations = entry["chkDoNum"].int,
              let publicKey = entry["pkiPublicKey"].string.flatMap({ Data(base64Encoded: $0) }),
              let signInURL = URL(string: signIn), Self.isTrustedAccountURL(signInURL, pathPrefix: "/accounts/")
        else { throw AuthError.entryPoint }

        let deviceID = existingDeviceID ?? SamsungCrypto.randomBytes(16).hexString
        let state = String(SamsungCrypto.base64URL(SamsungCrypto.randomBytes(15)).prefix(20))
        let pkce = SamsungCrypto.pkce()
        let country = (locale.region?.identifier ?? "US").lowercased()
        let payload: [String: JSONValue] = [
            "clientId": .string(Self.masterClientID), "code_challenge": .string(pkce.challenge),
            "code_challenge_method": .string("S256"), "competitorDeviceYNFlag": .string("Y"),
            "countryCode": .string(country), "deviceInfo": .string("Google|com.android.chrome"),
            "deviceModelID": .string("Pixel 8 Pro"), "deviceName": .string("Google Pixel 8 Pro"),
            "deviceOSVersion": .string("35"), "devicePhysicalAddressText": .string("ANID:\(deviceID)"),
            "deviceType": .string("APP"), "deviceUniqueID": .string(deviceID),
            "redirect_uri": .string(Self.redirectURI), "replaceableClientConnectYN": .string("N"),
            "replaceableClientId": .string(""), "replaceableDevicePhysicalAddressText": .string(""),
            "responseEncryptionType": .string("1"), "responseEncryptionYNFlag": .string("Y"),
            "scope": .string(""), "state": .string(state), "svcIptLgnID": .string(""), "iosYNFlag": .string("Y"),
        ]
        let svcParam = try Self.encryptServiceParameter(payload, iterations: Int(iterations), publicKeyDER: publicKey)
        let localeTag = locale.identifier.replacingOccurrences(of: "_", with: "-")
        var components = URLComponents(url: signInURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = "locale=\(Self.percentEncode(localeTag))&svcParam=\(svcParam)&mode=C"
        guard let url = components.url else { throw AuthError.entryPoint }
        return (url, Pending(state: state, verifier: pkce.verifier, deviceID: deviceID, createdAt: Date()))
    }

    /// AES-128-CBC of the JSON payload under a PBKDF2 key, that key RSA-wrapped with Samsung's entry-point public key.
    static func encryptServiceParameter(_ payload: [String: JSONValue], iterations: Int, publicKeyDER: Data) throws -> String {
        guard iterations >= 1 else { throw AuthError.entryPoint }
        let password = Data(SamsungCrypto.sha256Base64(String(iterations)).utf8)
        let salt = SamsungCrypto.randomBytes(16)
        let key = try SamsungCrypto.pbkdf2(password: password, salt: salt, iterations: iterations, length: 16)
        let wrappedKey = try SamsungCrypto.rsaEncrypt(spkiDER: publicKeyDER, plaintext: Data(key.base64EncodedString().utf8))
        let iv = SamsungCrypto.randomBytes(16)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let ciphertext = try SamsungCrypto.aesCBCEncrypt(key: key, iv: iv, plaintext: try encoder.encode(JSONValue.object(payload)))
        let envelope: [String: JSONValue] = [
            "chkDoNum": .string(String(iterations)),
            "svcEncParam": .string(ciphertext.base64EncodedString()),
            "svcEncKY": .string(wrappedKey.base64EncodedString()),
            "svcEncIV": .string(iv.hexString),
        ]
        return percentEncode(try encoder.encode(JSONValue.object(envelope)).base64EncodedString())
    }

    // MARK: Step 2 — handle the ms-app:// callback

    public static func isCallback(_ url: URL) -> Bool {
        url.scheme == "ms-app" && url.host == URL(string: redirectURI)?.host
    }

    public func complete(callback: URL, pending: Pending) async throws -> Identity {
        guard Date().timeIntervalSince(pending.createdAt) < Self.pendingMaxAge else { throw AuthError.pendingExpired }
        guard Self.isCallback(callback) else { throw AuthError.redirectMismatch }
        var params: [String: String] = [:]
        for item in URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            guard params[item.name] == nil else { throw AuthError.missingParameter(item.name) }
            params[item.name] = item.value
        }
        func value(_ name: String) throws -> String {
            guard let v = params[name], !v.isEmpty else { throw AuthError.missingParameter(name) }
            return v
        }
        let responseKey: String, authServer: String, code: String, loginID: String
        do {
            responseKey = try SamsungCrypto.aesECBDecrypt(textKey: pending.state, hex: try value("state"))
            authServer = try SamsungCrypto.aesECBDecrypt(textKey: responseKey, hex: try value("auth_server_url"))
            code = try SamsungCrypto.aesECBDecrypt(textKey: responseKey, hex: try value("code"))
            loginID = try SamsungCrypto.aesECBDecrypt(textKey: responseKey, hex: try value("retValue"))
        } catch let error as AuthError { throw error } catch { throw AuthError.decrypt }
        let server = try Self.trustedAuthServer(authServer)

        let body = try await json(Self.form(url: server.appendingPathComponent("auth/oauth2/authenticate"), fields: [
            ("grant_type", "authorization_code"), ("serviceType", "M"), ("client_id", Self.masterClientID),
            ("code", code), ("code_verifier", pending.verifier), ("username", loginID),
            ("physical_address_text", pending.deviceID),
        ]), step: "sign-in")
        guard let token = body["userauth_token"].string ?? body["userAuthToken"].string,
              let userID = body["userId"].string ?? body["user_id"].string, !token.isEmpty, !userID.isEmpty
        else { throw AuthError.malformed("sign-in") }
        return Identity(authServer: server.absoluteString, masterToken: token, loginID: loginID, userID: userID, deviceID: pending.deviceID)
    }

    // MARK: Step 3 — service tokens

    /// Issues an access/refresh token pair for the Reminder client from the master session.
    public func issueToken(identity: Identity, clientID: String = reminderClientID) async throws -> ServiceToken {
        let server = try Self.trustedAuthServer(identity.authServer)
        let pkce = SamsungCrypto.pkce()
        var components = URLComponents(url: server.appendingPathComponent("auth/oauth2/v2/authorize"), resolvingAgainstBaseURL: false)!
        var query: [URLQueryItem] = [
            .init(name: "response_type", value: "code"), .init(name: "serviceType", value: "M"),
            .init(name: "client_id", value: clientID), .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "childAccountSupported", value: "Y"),
            .init(name: "userauth_token", value: identity.masterToken),
            .init(name: "physical_address_text", value: identity.deviceID),
            .init(name: "login_id", value: identity.loginID),
        ]
        components.queryItems = query
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var authorize = try await json(request, step: "authorization")
        if authorize["code"].string == nil, authorize["privacyAccepted"].string == "N" {
            // Samsung wants the request repeated without login_id when privacy terms are pending.
            query.removeLast()
            components.queryItems = query
            request.url = components.url!
            authorize = try await json(request, step: "authorization")
        }
        guard let code = authorize["code"].string, !code.isEmpty else { throw AuthError.malformed("authorization") }

        let token = try await json(Self.form(url: server.appendingPathComponent("auth/oauth2/token"), fields: [
            ("grant_type", "authorization_code"), ("code", code), ("client_id", clientID), ("client_secret", ""),
            ("physical_address_text", identity.deviceID), ("code_verifier", pkce.verifier),
        ]), step: "token")
        return try Self.serviceToken(from: token)
    }

    public func refresh(_ current: ServiceToken, identity: Identity, clientID: String = reminderClientID) async throws -> ServiceToken {
        let server = try Self.trustedAuthServer(identity.authServer)
        let token = try await json(Self.form(url: server.appendingPathComponent("auth/oauth2/token"), fields: [
            ("grant_type", "refresh_token"), ("client_id", clientID), ("refresh_token", current.refreshToken),
        ]), step: "token refresh")
        return try Self.serviceToken(from: token)
    }

    // MARK: Helpers

    static func serviceToken(from body: JSONValue) throws -> ServiceToken {
        guard let access = body["access_token"].string, let refresh = body["refresh_token"].string,
              !access.isEmpty, !refresh.isEmpty else { throw AuthError.malformed("token") }
        let expires = TimeInterval(body["expires_in"].int ?? 3600)
        return ServiceToken(accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(expires))
    }

    static func isTrustedAccountURL(_ url: URL, pathPrefix: String) -> Bool {
        url.scheme == "https" && url.host == "account.samsung.com" && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443) && url.path.hasPrefix(pathPrefix) && url.query == nil && url.fragment == nil
    }

    /// Samsung may hand back a regional auth host; allow only Samsung-owned domains, bare https origin.
    static func trustedAuthServer(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        let shown = String(trimmed.prefix(80)).replacingOccurrences(of: "[^A-Za-z0-9.:/-]", with: "?", options: .regularExpression)
        guard let url = URL(string: trimmed), url.scheme == "https", let host = url.host?.lowercased(),
              Self.isSamsungHost(host),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil,
              let origin = URL(string: "https://\(host)")
        else { throw AuthError.untrustedURL(shown) }
        return origin
    }

    static func isSamsungHost(_ host: String) -> Bool {
        for domain in ["samsung.com", "samsungosp.com"] where host == domain || host.hasSuffix("." + domain) { return true }
        return false
    }

    static func form(url: URL, fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(fields.map { "\($0)=\(percentEncode($1))" }.joined(separator: "&").utf8)
        return request
    }

    static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func json(_ request: URLRequest, step: String) async throws -> JSONValue {
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch let error as URLError { throw CloudError.transport(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw AuthError.malformed(step) }
        // Redirect-following is disabled on the session delegate; a 3xx here means an untrusted hop.
        guard (200..<300).contains(http.statusCode) else { throw AuthError.http(step, http.statusCode) }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data), value.object != nil else { throw AuthError.malformed(step) }
        return value
    }
}

extension SamsungCrypto {
    static func sha256Base64(_ text: String) -> String {
        Data(SHA256.hash(data: Data(text.utf8))).base64EncodedString()
    }
}
