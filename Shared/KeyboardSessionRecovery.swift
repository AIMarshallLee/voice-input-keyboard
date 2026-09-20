import Foundation
import CryptoKit

enum KeyboardSessionLaunchMode: String, Codable, Equatable {
    case inPlace
    case manualOpen
}

/// Stores only hashes of the editor context so a recreated keyboard extension can
/// safely reconnect to the session it started without persisting user text.
struct KeyboardSessionRecoverySnapshot: Codable, Equatable {
    let session: String
    let contextBeforeDigest: String
    let contextAfterDigest: String
    let selectedTextDigest: String
    let hasContextEvidence: Bool
    let timestamp: TimeInterval
    let launchMode: KeyboardSessionLaunchMode
    let contextFingerprint: String

    init(session: String, contextBeforeDigest: String, contextAfterDigest: String,
         selectedTextDigest: String, hasContextEvidence: Bool, timestamp: TimeInterval,
         launchMode: KeyboardSessionLaunchMode, contextFingerprint: String) {
        self.session = session
        self.contextBeforeDigest = contextBeforeDigest
        self.contextAfterDigest = contextAfterDigest
        self.selectedTextDigest = selectedTextDigest
        self.hasContextEvidence = hasContextEvidence
        self.timestamp = timestamp
        self.launchMode = launchMode
        self.contextFingerprint = contextFingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case session, contextBeforeDigest, contextAfterDigest, selectedTextDigest
        case hasContextEvidence, timestamp, launchMode, contextFingerprint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        session = try container.decode(String.self, forKey: .session)
        contextBeforeDigest = try container.decode(String.self, forKey: .contextBeforeDigest)
        contextAfterDigest = try container.decode(String.self, forKey: .contextAfterDigest)
        selectedTextDigest = try container.decode(String.self, forKey: .selectedTextDigest)
        hasContextEvidence = try container.decode(Bool.self, forKey: .hasContextEvidence)
        timestamp = try container.decode(TimeInterval.self, forKey: .timestamp)
        launchMode = try container.decodeIfPresent(KeyboardSessionLaunchMode.self, forKey: .launchMode) ?? .manualOpen
        contextFingerprint = try container.decodeIfPresent(String.self, forKey: .contextFingerprint)
            ?? KeyboardSessionRecoveryStore.combineDigests(contextBeforeDigest, contextAfterDigest, selectedTextDigest)
    }
}

enum KeyboardSessionRecoveryStore {
    static let maxAge: TimeInterval = 10 * 60

    private static let storageKey = "keyboardSessionRecovery.v1"
    private static let missingValueMarker = "<nil>"
    private static let contextCharacterLimit = 96

    @discardableResult
    static func save(
        session: String,
        launchMode: KeyboardSessionLaunchMode,
        contextBefore: String?,
        contextAfter: String?,
        selectedText: String?,
        timestamp: TimeInterval = Date().timeIntervalSince1970,
        defaults: UserDefaults = SharedDefaults.shared
    ) -> KeyboardSessionRecoverySnapshot? {
        guard UUID(uuidString: session) != nil else { return nil }
        let snapshot = makeSnapshot(
            session: session,
            launchMode: launchMode,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            selectedText: selectedText,
            timestamp: timestamp
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return nil }
        defaults.set(data, forKey: storageKey)
        return snapshot
    }

    @discardableResult
    static func markManualOpen(session: String, defaults: UserDefaults = SharedDefaults.shared) -> Bool {
        guard let snapshot = load(defaults: defaults), snapshot.session == session else { return false }
        return storeManualSnapshot(snapshot, session: session, timestamp: snapshot.timestamp, defaults: defaults)
    }

    @discardableResult
    static func rebindForManualHandoff(
        from source: SessionToken, to replacement: SessionToken,
        timestamp: TimeInterval = Date().timeIntervalSince1970,
        defaults: UserDefaults = SharedDefaults.shared
    ) -> Bool {
        guard source != replacement, timestamp.isFinite, timestamp > 0,
              let snapshot = load(defaults: defaults), snapshot.session == source.rawValue else { return false }
        return storeManualSnapshot(snapshot, session: replacement.rawValue, timestamp: timestamp, defaults: defaults)
    }

    private static func storeManualSnapshot(
        _ snapshot: KeyboardSessionRecoverySnapshot, session: String,
        timestamp: TimeInterval, defaults: UserDefaults
    ) -> Bool {
        let updated = KeyboardSessionRecoverySnapshot(session: session,
            contextBeforeDigest: snapshot.contextBeforeDigest, contextAfterDigest: snapshot.contextAfterDigest,
            selectedTextDigest: snapshot.selectedTextDigest, hasContextEvidence: snapshot.hasContextEvidence,
            timestamp: timestamp, launchMode: .manualOpen, contextFingerprint: snapshot.contextFingerprint)
        guard let data = try? JSONEncoder().encode(updated) else { return false }
        defaults.set(data, forKey: storageKey)
        return true
    }

    static func load(
        now: TimeInterval = Date().timeIntervalSince1970,
        maxAge: TimeInterval = KeyboardSessionRecoveryStore.maxAge,
        defaults: UserDefaults = SharedDefaults.shared
    ) -> KeyboardSessionRecoverySnapshot? {
        guard let data = defaults.data(forKey: storageKey),
              let snapshot = try? JSONDecoder().decode(
                  KeyboardSessionRecoverySnapshot.self,
                  from: data
              ),
              UUID(uuidString: snapshot.session) != nil,
              snapshot.timestamp <= now,
              now - snapshot.timestamp <= maxAge else {
            defaults.removeObject(forKey: storageKey)
            return nil
        }
        return snapshot
    }

    static func matches(
        _ snapshot: KeyboardSessionRecoverySnapshot,
        contextBefore: String?,
        contextAfter: String?,
        selectedText: String?
    ) -> Bool {
        let candidate = makeSnapshot(
            session: snapshot.session,
            launchMode: snapshot.launchMode,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            selectedText: selectedText,
            timestamp: snapshot.timestamp
        )
        return candidate.contextBeforeDigest == snapshot.contextBeforeDigest
            && candidate.contextAfterDigest == snapshot.contextAfterDigest
            && candidate.selectedTextDigest == snapshot.selectedTextDigest
    }

    static func clear(
        expectedSession: String? = nil,
        defaults: UserDefaults = SharedDefaults.shared
    ) {
        if let expectedSession,
           let current = load(defaults: defaults),
           current.session != expectedSession {
            return
        }
        defaults.removeObject(forKey: storageKey)
    }

    private static func makeSnapshot(
        session: String,
        launchMode: KeyboardSessionLaunchMode,
        contextBefore: String?,
        contextAfter: String?,
        selectedText: String?,
        timestamp: TimeInterval
    ) -> KeyboardSessionRecoverySnapshot {
        let before = digest(normalizeBefore(contextBefore))
        let after = digest(normalizeAfter(contextAfter))
        let selected = digest(selectedText ?? missingValueMarker)
        return KeyboardSessionRecoverySnapshot(
            session: session,
            contextBeforeDigest: before,
            contextAfterDigest: after,
            selectedTextDigest: selected,
            hasContextEvidence: [contextBefore, contextAfter, selectedText]
                .compactMap { $0 }
                .contains { !$0.isEmpty },
            timestamp: timestamp,
            launchMode: launchMode,
            contextFingerprint: combineDigests(before, after, selected)
        )
    }

    static func combineDigests(_ before: String, _ after: String, _ selected: String) -> String {
        digest("\(before)|\(after)|\(selected)")
    }

    private static func normalizeBefore(_ value: String?) -> String {
        guard let value else { return missingValueMarker }
        return String(value.suffix(contextCharacterLimit))
    }

    private static func normalizeAfter(_ value: String?) -> String {
        guard let value else { return missingValueMarker }
        return String(value.prefix(contextCharacterLimit))
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
