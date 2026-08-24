import Foundation
import CryptoKit

/// Stores only hashes of the editor context so a recreated keyboard extension can
/// safely reconnect to the session it started without persisting user text.
struct KeyboardSessionRecoverySnapshot: Codable, Equatable {
    let session: String
    let contextBeforeDigest: String
    let contextAfterDigest: String
    let selectedTextDigest: String
    let hasContextEvidence: Bool
    let timestamp: TimeInterval
}

enum KeyboardSessionRecoveryStore {
    static let maxAge: TimeInterval = 10 * 60

    private static let storageKey = "keyboardSessionRecovery.v1"
    private static let missingValueMarker = "<nil>"
    private static let contextCharacterLimit = 96

    @discardableResult
    static func save(
        session: String,
        contextBefore: String?,
        contextAfter: String?,
        selectedText: String?,
        timestamp: TimeInterval = Date().timeIntervalSince1970,
        defaults: UserDefaults = SharedDefaults.shared
    ) -> KeyboardSessionRecoverySnapshot? {
        guard UUID(uuidString: session) != nil else { return nil }
        let snapshot = makeSnapshot(
            session: session,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            selectedText: selectedText,
            timestamp: timestamp
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return nil }
        defaults.set(data, forKey: storageKey)
        return snapshot
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
        contextBefore: String?,
        contextAfter: String?,
        selectedText: String?,
        timestamp: TimeInterval
    ) -> KeyboardSessionRecoverySnapshot {
        KeyboardSessionRecoverySnapshot(
            session: session,
            contextBeforeDigest: digest(normalizeBefore(contextBefore)),
            contextAfterDigest: digest(normalizeAfter(contextAfter)),
            selectedTextDigest: digest(selectedText ?? missingValueMarker),
            hasContextEvidence: [contextBefore, contextAfter, selectedText]
                .compactMap { $0 }
                .contains { !$0.isEmpty },
            timestamp: timestamp
        )
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
