import Foundation
import SwiftUI
import Combine
import Defaults

@MainActor
final class LLMUsageManager: ObservableObject {
    static let shared = LLMUsageManager()

    @Published var results: [ProviderID: UsageResult] = [:]
    @Published var isRefreshing = false

    private let injectedProviders: [UsageProvider]? // overrides the flag-based default when non-nil
    private var lastRefresh: Date = .distantPast
    private static let minRefreshInterval: TimeInterval = 60
    private var autoRefreshTask: Task<Void, Never>?
    private var isRefreshingPinned = false
    private var settingsObserver: AnyCancellable?

    init(providers: [UsageProvider]? = nil) {
        self.injectedProviders = providers
        guard providers == nil else { return }
        let keys: [Defaults._AnyKey] = [.enableLLMUsageFeature, .pinnedUsageProvider, .llmUsageRefreshMinutes]
            + ProviderID.allCases.map { $0.enabledKey as Defaults._AnyKey }
        settingsObserver = Defaults.publisher(keys: keys)
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] in Task { @MainActor in self?.updateAutoRefresh() } }
    }

    private static let allProviders: [UsageProvider] = [ClaudeUsageProvider(), CodexUsageProvider(), CursorUsageProvider(), AntigravityUsageProvider(), NewAPIUsageProvider()]

    private var enabledProviders: [UsageProvider] {
        if let injectedProviders { return injectedProviders }
        return Self.allProviders.filter { Defaults[$0.id.enabledKey] }
    }

    /// The provider whose limits are pinned under the closed notch, if it is still enabled.
    var pinnedProvider: ProviderID? {
        guard Defaults[.enableLLMUsageFeature],
              let id = ProviderID(rawValue: Defaults[.pinnedUsageProvider]),
              Defaults[id.enabledKey] else { return nil }
        return id
    }

    /// Refreshes every enabled provider. Token counts and cost (a scan of local logs) are only
    /// fetched while those details are shown; otherwise this is one small request per provider.
    func refreshAll(force: Bool = false) {
        guard !isRefreshing else { return }
        let providers = enabledProviders
        // A provider that has never reported (e.g. just enabled) is fetched even inside the throttle window.
        let missing = providers.contains { results[$0.id] == nil }
        guard force || missing || Date().timeIntervalSince(lastRefresh) >= Self.minRefreshInterval else { return }
        lastRefresh = Date()
        isRefreshing = true
        let enabledIDs = Set(providers.map { $0.id })
        results = results.filter { enabledIDs.contains($0.key) } // drop disabled providers' stale results
        for p in providers where results[p.id] == nil { results[p.id] = .loading }
        let limitsOnly = !Defaults[.showLLMUsageDetails]
        Task {
            await runRefresh(providers: providers, limitsOnly: limitsOnly)
            isRefreshing = false
        }
    }

    private func runRefresh(providers: [UsageProvider], limitsOnly: Bool) async {
        let now = Date()
        let previous = results
        await withTaskGroup(of: (ProviderID, UsageResult).self) { group in
            for provider in providers {
                var last: UsageSnapshot?
                if case .success(let snapshot) = previous[provider.id] { last = snapshot }
                group.addTask { [last] in
                    do {
                        let snapshot = limitsOnly
                            ? try await provider.fetchLimitsOnly(now: now, previous: last)
                            : try await provider.fetchSnapshot(now: now)
                        return (provider.id, .success(snapshot))
                    } catch {
                        return (provider.id, .failure(error.localizedDescription))
                    }
                }
            }
            for await (id, result) in group { results[id] = result }
        }
    }

    /// Limits for the pinned provider alone. Kept apart from refreshAll so it neither blocks nor
    /// throttles a refresh the user asks for.
    private func refreshPinned() {
        guard !isRefreshingPinned, let pinned = pinnedProvider,
              let provider = enabledProviders.first(where: { $0.id == pinned }) else { return }
        isRefreshingPinned = true
        Task {
            await runRefresh(providers: [provider], limitsOnly: true)
            isRefreshingPinned = false
        }
    }

    // MARK: - Pinned auto-refresh

    /// While limits are pinned under the closed notch nothing else opens the Usage tab, so keep
    /// them current here: a limits-only refresh every few minutes, and shortly after a window resets.
    private func updateAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        guard pinnedProvider != nil else { return }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshPinned()
                let delay = self.nextAutoRefreshDelay(now: Date())
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func nextAutoRefreshDelay(now: Date) -> TimeInterval {
        let interval = TimeInterval(max(1, Defaults[.llmUsageRefreshMinutes]) * 60)
        guard let pinned = pinnedProvider, case .success(let snapshot) = results[pinned] else { return interval }
        let resets = UsageLimitWording.rows(for: pinned, snapshot: snapshot)
            .compactMap { $0.limit.resetsAt?.timeIntervalSince(now) }
            .filter { $0 > 0 }
        // 30 s of slack lets the provider roll its window over before we ask again.
        guard let soonest = resets.min() else { return interval }
        return max(30, min(interval, soonest + 30))
    }
}
