import Foundation

actor ClaudeCredentialStore {
    static let shared = ClaudeCredentialStore()
    private var cached: ClaudeQuotaClient.Credentials?

    fileprivate func get() -> ClaudeQuotaClient.Credentials? { cached }
    fileprivate func set(_ creds: ClaudeQuotaClient.Credentials) { cached = creds }
    fileprivate func clear() { cached = nil }

    // Atomically replace the cache with a fresh load from source. Running the load
    // inside the actor closes the window where a concurrent reader could slot a stale
    // credential in between a separate clear() and set().
    fileprivate func reload(from load: @Sendable () -> ClaudeQuotaClient.Credentials?) -> ClaudeQuotaClient.Credentials? {
        cached = load()
        return cached
    }
}

struct ClaudeQuotaClient {
    let session: URLSession
    init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }

    /// Where a credential was read from, so a refreshed pair can be written back to the
    /// same item and nothing else: service alone can match several Keychain items.
    fileprivate enum CredentialSource: Sendable {
        case file(URL)
        case keychain(service: String, account: String?)
    }

    /// One Claude Code OAuth credential. `raw` is the credential JSON exactly as read:
    /// Claude Code keeps more under `claudeAiOauth` than the three fields used here
    /// (scopes, subscriptionType, rateLimitTier, refreshTokenExpiresAt), and a write-back
    /// must hand all of it back untouched.
    fileprivate struct Credentials: Sendable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Int64
        let raw: Data
        let source: CredentialSource

        /// nil when the JSON has no usable pair. A logged-out Claude Code leaves the item in
        /// place with empty tokens and `expiresAt: 0`; that is "no credential", not one to refresh.
        static func parse(_ data: Data, source: CredentialSource) -> Credentials? {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = obj["claudeAiOauth"] as? [String: Any],
                  let access = oauth["accessToken"] as? String, !access.isEmpty,
                  let refresh = oauth["refreshToken"] as? String, !refresh.isEmpty,
                  let expires = (oauth["expiresAt"] as? NSNumber)?.int64Value
            else { return nil }
            return Credentials(accessToken: access, refreshToken: refresh, expiresAt: expires, raw: data, source: source)
        }
    }

    private enum ResetsAt: Decodable {
        case iso(String)
        case epochMs(Double)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .iso(s) }
            else { self = .epochMs(try c.decode(Double.self)) }
        }
        var date: Date? {
            switch self {
            case .iso(let s):
                // The usage endpoint returns fractional seconds ("2026-07-03T00:30:00.282668+00:00");
                // the default formatter rejects those, so try the fractional form first.
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = formatter.date(from: s) { return date }
                formatter.formatOptions = [.withInternetDateTime]
                return formatter.date(from: s)
            case .epochMs(let ms): return Date(timeIntervalSince1970: ms / 1000)
            }
        }
    }

    private struct Window: Decodable {
        let utilization: Double
        let resetsAt: ResetsAt
    }

    /// The per-model weekly windows may be present with nulls on plans that do not meter them,
    /// so they decode leniently and can never fail the whole response.
    private struct LenientWindow: Decodable {
        let utilization: Double?
        let resetsAt: ResetsAt?
    }

    private struct UsageResponse: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?
        let sevenDaySonnet: LenientWindow?
        let sevenDayOpus: LenientWindow?

        enum CodingKeys: String, CodingKey { case fiveHour, sevenDay, sevenDaySonnet, sevenDayOpus }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            fiveHour = try c.decodeIfPresent(Window.self, forKey: .fiveHour)
            sevenDay = try c.decodeIfPresent(Window.self, forKey: .sevenDay)
            sevenDaySonnet = (try? c.decodeIfPresent(LenientWindow.self, forKey: .sevenDaySonnet)) ?? nil
            sevenDayOpus = (try? c.decodeIfPresent(LenientWindow.self, forKey: .sevenDayOpus)) ?? nil
        }
    }

    typealias Limits = (session: UsageLimit?, week: UsageLimit?, models: [UsageLimitRow])
    private static let noLimits: Limits = (nil, nil, [])

    private enum FetchOutcome {
        case success(Limits)
        case authFailure // 401/403: the access token is no longer accepted.
        case otherFailure // network/decoding/5xx: reloading credentials would not help.
    }

    func fetchLimits() async -> Limits {
        guard let creds = await currentCredentials() else { return Self.noLimits }
        switch await attemptFetch(creds) {
        case .success(let limits):
            return limits
        case .authFailure:
            // Claude Code likely rotated the OAuth token out from under our cache
            // (revoked access token, or a refresh token it already consumed). Drop the
            // cached copy, re-read from source (file → Keychain, which CC has updated),
            // and retry exactly once. No retry on non-auth failures.
            guard let fresh = await reloadCredentials() else { return Self.noLimits }
            if case .success(let limits) = await attemptFetch(fresh) { return limits }
            return Self.noLimits
        case .otherFailure:
            return Self.noLimits
        }
    }

    private func attemptFetch(_ creds: Credentials) async -> FetchOutcome {
        guard let token = await validAccessToken(creds) else { return .authFailure }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.69", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .otherFailure }
            if http.statusCode == 401 || http.statusCode == 403 { return .authFailure }
            guard (200..<300).contains(http.statusCode) else { return .otherFailure }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let decoded = try decoder.decode(UsageResponse.self, from: data)
            let sessionLimit = decoded.fiveHour.map { UsageLimit(used: $0.utilization, limit: 100, resetsAt: $0.resetsAt.date) }
            let weekLimit = decoded.sevenDay.map { UsageLimit(used: $0.utilization, limit: 100, resetsAt: $0.resetsAt.date) }
            let models = [("Sonnet", decoded.sevenDaySonnet), ("Opus", decoded.sevenDayOpus)].compactMap { name, window -> UsageLimitRow? in
                // Shown only when the plan actually meters that model: a null or untouched, unscheduled window is noise.
                guard let window, let used = window.utilization, used > 0 || window.resetsAt != nil else { return nil }
                return UsageLimitRow(title: "Weekly · \(name) only", shortTitle: name,
                                     limit: UsageLimit(used: used, limit: 100, resetsAt: window.resetsAt?.date))
            }
            return .success((sessionLimit, weekLimit, models))
        } catch {
            return .otherFailure
        }
    }

    private func currentCredentials() async -> Credentials? {
        if let cached = await ClaudeCredentialStore.shared.get() { return cached }
        guard let loaded = Self.loadCredentialsFromSource() else { return nil }
        await ClaudeCredentialStore.shared.set(loaded)
        return loaded
    }

    // Force a re-read from source, bypassing the in-memory cache. Called after an auth
    // failure so a token rotated by Claude Code is picked up without an app restart.
    // The invalidate-and-reload is a single atomic actor operation (see reload(from:)).
    private func reloadCredentials() async -> Credentials? {
        await ClaudeCredentialStore.shared.reload(from: { Self.loadCredentialsFromSource() })
    }

    // File first never prompts; Keychain only as fallback. On the Keychain path, read the
    // freshest "Claude Code-credentials*" item: newer Claude Code stores its token under a
    // per-install hash suffix and no longer updates the un-suffixed item.
    private static func loadCredentialsFromSource() -> Credentials? {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: path), let parsed = Credentials.parse(data, source: .file(path)) {
            return parsed
        }
        guard let item = KeychainReader.freshestGenericPassword(
            servicePrefix: "Claude Code-credentials", readSecret: ClaudeKeychainStore.read
        ) else { return nil }
        return Credentials.parse(Data(item.secret.utf8), source: .keychain(service: item.service, account: item.account))
    }

    /// Read-only by design: Toplet never refreshes Claude Code's token or writes it back. A refresh
    /// here could race Claude Code's own and sign it out. An expired token is re-read from source
    /// (Claude Code rotates it whenever it runs); if it is still expired the limits are unavailable
    /// until Claude Code is opened.
    private func validAccessToken(_ creds: Credentials) async -> String? {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if creds.expiresAt > nowMs { return creds.accessToken }
        if let reloaded = await reloadCredentials(), reloaded.expiresAt > nowMs { return reloaded.accessToken }
        return nil
    }
}
