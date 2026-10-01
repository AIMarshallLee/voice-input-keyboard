import Foundation

struct SessionToken: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String

    init() {
        rawValue = UUID().uuidString
    }

    init?(rawValue: String) {
        guard UUID(uuidString: rawValue) != nil else { return nil }
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard UUID(uuidString: value) != nil else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "SessionToken must contain a UUID"
            )
        }
        rawValue = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum DictationEntryPoint: String, Codable, Equatable, Sendable {
    case foreground
    case inPlace
}

enum DictationAuthorizationPolicy: String, Codable, Equatable, Sendable {
    case requestIfNeeded
    case readOnly
}

struct TextProcessingSnapshot: Equatable, Sendable {
    let selectedText: String?
    let keyboardType: Int
    let language: String
    let translateEnabled: Bool
    let translateTarget: String
    let voiceEditEnabled: Bool
    let livePreviewEnabled: Bool
    let expectedContextFingerprint: String?
}

struct DictationSessionRequest: Equatable, Sendable {
    let token: SessionToken
    let entryPoint: DictationEntryPoint
    let authorizationPolicy: DictationAuthorizationPolicy
    let whisper: Bool
    let processing: TextProcessingSnapshot
}

enum EditIntent: Codable, Equatable, Sendable {
    case dictate
    case append
    case rewrite
    case translate(targetLanguage: String)
    case delete
}

enum EditOperation: String, Codable, Equatable, Sendable {
    case insertAtCursor
    case replaceSelection
    case deleteSelection
    case previewOnly
}

struct EditPlan: Codable, Equatable, Sendable {
    let intent: EditIntent
    let operation: EditOperation
    let text: String
    let expectedContextFingerprint: String?
    let requiresConfirmation: Bool
}

enum DictationPermissionKind: String, Equatable, Sendable {
    case speech
    case microphone
}

enum DictationFailure: Error, Equatable, Sendable {
    case permissionDenied(DictationPermissionKind)
    case permissionRequiresForeground(DictationPermissionKind)
    case recognitionUnavailable
    case audioSession
    case audioCapture
    case recognition
    case noSpeech
    case startTimeout
    case finalizationTimeout
    case processing
    case processingTimeout
    case interrupted
    case inputRouteLost
    case mediaServicesReset
    case outputPersistence
}

extension DictationFailure {
    var userMessage: String {
        switch self {
        case .permissionDenied(.speech), .permissionRequiresForeground(.speech):
            return "请在系统设置中允许语音识别"
        case .permissionDenied(.microphone), .permissionRequiresForeground(.microphone):
            return "请在系统设置中允许麦克风"
        case .recognitionUnavailable:
            return "语音识别不可用，请检查网络或设备端识别支持"
        case .audioSession, .audioCapture:
            return "无法启动麦克风，请重试"
        case .recognition:
            return "语音识别失败，请重试"
        case .noSpeech:
            return "未识别到语音"
        case .startTimeout:
            return "语音启动超时，请重试"
        case .finalizationTimeout:
            return "完成识别超时，请重试"
        case .processing:
            return "文字处理失败，请重试"
        case .processingTimeout:
            return "文字处理超时，请重试"
        case .interrupted:
            return "录音被系统中断，请重试"
        case .inputRouteLost:
            return "麦克风连接已变化，请重试"
        case .mediaServicesReset:
            return "音频服务已重置，请重试"
        case .outputPersistence:
            return "无法保存识别结果，请重试"
        }
    }
}

enum DictationSessionEvent: Equatable, Sendable {
    case authorizing
    case preparing
    case listening(partial: String)
    case processing
    case completed(EditPlan)
    case failed(DictationFailure)
    case cancelled
}

struct DictationSessionEventEnvelope: Equatable, Sendable {
    let token: SessionToken
    let sequence: UInt64
    let event: DictationSessionEvent
}

enum DictationTerminal: Equatable, Sendable {
    case completed(EditPlan)
    case failed(DictationFailure)
    case cancelled
}

enum DictationOutputCommitStatus: Equatable, Sendable {
    case written
    case alreadyTerminal
    case cancelled
    case ioFailure
}
