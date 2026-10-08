import Foundation

/// One server's auto-archive preferences. Stored per server in UserDefaults by
/// `AutoArchiveStore`; Settings edits the same keys through `@AppStorage`.
struct AutoArchiveSettings: Equatable {
    static let idleDayOptions = [7, 14, 30, 60]
    static let defaultIdleDays = 30

    var isEnabled = true
    var idleDays = AutoArchiveSettings.defaultIdleDays
    /// When on, chats the keep model scores as worth keeping wait in the review
    /// sheet instead of being archived; when off, every idle chat is archived.
    var asksBeforeArchivingKeepers = true

    var idleInterval: TimeInterval { TimeInterval(max(idleDays, 1)) * 86_400 }
}

/// Per-server auto-archive state: the settings, the learned keep model, and
/// the chats the user chose to keep (so they are not offered again until they
/// sit idle for another full threshold). Keys follow the other per-server
/// preferences: `autoArchive.<name>|<server absoluteString>`.
struct AutoArchiveStore {
    var defaults: UserDefaults = .standard

    static func key(_ name: String, for server: URL) -> String {
        "autoArchive.\(name)|\(server.absoluteString)"
    }

    static func isEnabledKey(for server: URL) -> String { key("isEnabled", for: server) }
    static func idleDaysKey(for server: URL) -> String { key("idleDays", for: server) }
    static func asksBeforeArchivingKeepersKey(for server: URL) -> String { key("asksBeforeKeepers", for: server) }
    private static func modelKey(for server: URL) -> String { key("keepModel", for: server) }
    private static func keptKey(for server: URL) -> String { key("kept", for: server) }

    func settings(for server: URL) -> AutoArchiveSettings {
        var settings = AutoArchiveSettings()
        if let isEnabled = defaults.object(forKey: Self.isEnabledKey(for: server)) as? Bool {
            settings.isEnabled = isEnabled
        }
        if let days = defaults.object(forKey: Self.idleDaysKey(for: server)) as? Int, days > 0 {
            settings.idleDays = days
        }
        if let asks = defaults.object(forKey: Self.asksBeforeArchivingKeepersKey(for: server)) as? Bool {
            settings.asksBeforeArchivingKeepers = asks
        }
        return settings
    }

    func model(for server: URL) -> KeepPreferenceModel {
        guard let data = defaults.data(forKey: Self.modelKey(for: server)),
              let model = try? JSONDecoder().decode(KeepPreferenceModel.self, from: data)
        else { return KeepPreferenceModel() }
        return model
    }

    func setModel(_ model: KeepPreferenceModel, for server: URL) {
        guard let data = try? JSONEncoder().encode(model) else { return }
        defaults.set(data, forKey: Self.modelKey(for: server))
    }

    func resetModel(for server: URL) {
        defaults.removeObject(forKey: Self.modelKey(for: server))
    }

    /// Session ID to the time (seconds since 1970) the user chose to keep it.
    func keptAt(for server: URL) -> [String: Double] {
        defaults.dictionary(forKey: Self.keptKey(for: server)) as? [String: Double] ?? [:]
    }

    func markKept(_ sessionID: String, at date: Date, for server: URL) {
        var kept = keptAt(for: server)
        kept[sessionID] = date.timeIntervalSince1970
        defaults.set(kept, forKey: Self.keptKey(for: server))
    }

    /// Drops keep marks for chats that are gone or whose keep period ended.
    func pruneKept(present sessionIDs: Set<String>, now: Date, idleInterval: TimeInterval, for server: URL) {
        let kept = keptAt(for: server)
        let pruned = kept.filter { sessionIDs.contains($0.key) && now.timeIntervalSince1970 - $0.value < idleInterval }
        guard pruned.count != kept.count else { return }
        defaults.set(pruned, forKey: Self.keptKey(for: server))
    }

    /// Removing the server drops everything stored for it.
    func remove(for server: URL) {
        for name in ["isEnabled", "idleDays", "asksBeforeKeepers", "keepModel", "kept"] {
            defaults.removeObject(forKey: Self.key(name, for: server))
        }
    }
}

/// A tiny on-device naive Bayes model of which idle chats the user keeps
/// (Summarize & Archive, Keep, or Undo of an auto-archive) versus throws away
/// (plain Archive). Features come only from `SessionSummary`, so scoring never
/// fetches a transcript. Below `minimumExamples` decisions the score is the
/// heuristic prior; above it, the learned score is blended in.
struct KeepPreferenceModel: Codable, Equatable {
    struct Example: Codable, Equatable {
        let sessionID: String
        let features: [String]
        let kept: Bool
    }

    static let maximumExamples = 500
    static let minimumExamples = 10
    /// Examples needed before the learned score fully replaces the prior.
    static let fullConfidenceExamples = 40
    static let candidateThreshold = 0.5

    /// Title words that suggest a personal or decision-bearing conversation.
    static let personalKeywords: Set<String> = [
        "family", "health", "plan", "feel", "decide", "career",
        "relationship", "money", "baby", "interview"
    ]

    private(set) var examples: [Example] = []

    /// Records one decision. A newer decision about the same chat replaces the
    /// older one, and only the newest `maximumExamples` are kept.
    mutating func train(_ session: SessionSummary, kept: Bool) {
        guard let sessionID = session.sessionId, !sessionID.isEmpty else { return }
        examples.removeAll { $0.sessionID == sessionID }
        examples.append(Example(sessionID: sessionID, features: Self.features(for: session), kept: kept))
        if examples.count > Self.maximumExamples {
            examples.removeFirst(examples.count - Self.maximumExamples)
        }
    }

    mutating func forget(sessionID: String) {
        examples.removeAll { $0.sessionID == sessionID }
    }

    /// Counts the examples once, so a pass scores many sessions cheaply.
    func scorer() -> Scorer { Scorer(examples: examples) }

    func score(_ session: SessionSummary) -> Double { scorer().score(session) }

    struct Scorer {
        private let keptTotal: Int
        private let discardedTotal: Int
        private let keptCounts: [String: Int]
        private let discardedCounts: [String: Int]

        init(examples: [Example]) {
            var keptTotal = 0
            var discardedTotal = 0
            var keptCounts: [String: Int] = [:]
            var discardedCounts: [String: Int] = [:]
            for example in examples {
                if example.kept {
                    keptTotal += 1
                    for feature in Set(example.features) { keptCounts[feature, default: 0] += 1 }
                } else {
                    discardedTotal += 1
                    for feature in Set(example.features) { discardedCounts[feature, default: 0] += 1 }
                }
            }
            self.keptTotal = keptTotal
            self.discardedTotal = discardedTotal
            self.keptCounts = keptCounts
            self.discardedCounts = discardedCounts
        }

        var exampleCount: Int { keptTotal + discardedTotal }

        /// Probability-like keep score in 0...1.
        func score(_ session: SessionSummary) -> Double {
            let prior = KeepPreferenceModel.priorScore(for: session)
            guard exampleCount >= KeepPreferenceModel.minimumExamples else { return prior }
            let weight = min(1, Double(exampleCount) / Double(KeepPreferenceModel.fullConfidenceExamples))
            return (1 - weight) * prior + weight * learnedScore(session)
        }

        /// Laplace-smoothed naive Bayes over the features present on the session.
        func learnedScore(_ session: SessionSummary) -> Double {
            let kept = Double(keptTotal)
            let discarded = Double(discardedTotal)
            var logOdds = log((kept + 1) / (discarded + 1))
            for feature in Set(KeepPreferenceModel.features(for: session)) {
                let keptLikelihood = (Double(keptCounts[feature] ?? 0) + 1) / (kept + 2)
                let discardedLikelihood = (Double(discardedCounts[feature] ?? 0) + 1) / (discarded + 2)
                logOdds += log(keptLikelihood / discardedLikelihood)
            }
            return 1 / (1 + exp(-logOdds))
        }
    }

    /// Before there is enough data: a longer chat, or a title that sounds
    /// personal, is worth asking about.
    static func priorScore(for session: SessionSummary) -> Double {
        let longEnough = (session.messageCount ?? 0) >= 6
        let personal = !titleWords(session.title).isDisjoint(with: personalKeywords)
        return longEnough || personal ? 0.75 : 0.25
    }

    static func features(for session: SessionSummary) -> [String] {
        var features = titleWords(session.title).sorted().prefix(12).map { "w:\($0)" }
        features.append("messages:\(messageBucket(session.messageCount))")
        if let created = session.createdAt, let last = session.lastMessageAt, last >= created {
            let span = last - created
            features.append(span < 600 ? "span:minutes" : span < 86_400 ? "span:day" : "span:days")
        }
        if let project = session.projectId, !project.isEmpty { features.append("project") }
        if let profile = session.profile?.trimmingCharacters(in: .whitespacesAndNewlines), !profile.isEmpty {
            features.append("profile:\(profile.lowercased())")
        }
        return features
    }

    static func titleWords(_ title: String?) -> Set<String> {
        guard let title else { return [] }
        let words = title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
        return Set(words)
    }

    private static func messageBucket(_ count: Int?) -> String {
        switch count ?? 0 {
        case ..<2: return "0-1"
        case ..<6: return "2-5"
        case ..<16: return "6-15"
        default: return "16+"
        }
    }
}

/// What one auto-archive pass does: chats to archive quietly and chats to
/// offer for review.
struct AutoArchivePlan: Equatable {
    var archive: [SessionSummary] = []
    var review: [SessionSummary] = []
}

/// Pure eligibility and split for an auto-archive pass.
enum AutoArchivePolicy {
    /// Seconds since 1970 of the chat's last activity, or nil when unknown.
    static func lastActivity(of session: SessionSummary) -> Double? {
        let value = session.lastMessageAt ?? session.updatedAt ?? session.createdAt ?? 0
        return value > 0 ? value : nil
    }

    static func isIdle(_ session: SessionSummary, now: Date, settings: AutoArchiveSettings) -> Bool {
        guard let last = lastActivity(of: session) else { return false }
        return now.timeIntervalSince1970 - last >= settings.idleInterval
    }

    /// A chat this pass may touch: a normal, settled, unpinned webui chat
    /// idle past the threshold, not open, and not recently kept by the user.
    static func isEligible(
        _ session: SessionSummary,
        now: Date,
        settings: AutoArchiveSettings,
        keptAt: [String: Double],
        excludedSessionIDs: Set<String>
    ) -> Bool {
        guard let sessionID = session.sessionId, !sessionID.isEmpty,
              !excludedSessionIDs.contains(sessionID),
              session.pinned != true,
              session.archived != true,
              session.isStreaming != true,
              (session.activeStreamId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              session.hasPendingUserMessage != true,
              !session.isSessionReadOnly,
              !session.requiresExternalImport,
              isIdle(session, now: now, settings: settings)
        else { return false }
        if let kept = keptAt[sessionID], now.timeIntervalSince1970 - kept < settings.idleInterval {
            return false
        }
        return true
    }

    static func plan(
        sessions: [SessionSummary],
        now: Date,
        settings: AutoArchiveSettings,
        keptAt: [String: Double] = [:],
        excludedSessionIDs: Set<String> = [],
        scorer: KeepPreferenceModel.Scorer
    ) -> AutoArchivePlan {
        guard settings.isEnabled else { return AutoArchivePlan() }
        var plan = AutoArchivePlan()
        for session in sessions where isEligible(
            session,
            now: now,
            settings: settings,
            keptAt: keptAt,
            excludedSessionIDs: excludedSessionIDs
        ) {
            // Scheduled-task output is never a conversation worth a digest.
            if settings.asksBeforeArchivingKeepers,
               !session.isCronSession,
               scorer.score(session) >= KeepPreferenceModel.candidateThreshold {
                plan.review.append(session)
            } else {
                plan.archive.append(session)
            }
        }
        return plan
    }
}
