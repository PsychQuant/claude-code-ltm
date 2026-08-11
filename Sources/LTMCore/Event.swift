import Foundation

/// 索引建置的識別碼。事件記下它，是為了讓「跨 generation 的比較」在報告時
/// 能被辨認出來而不是被靜靜地混在一起算。
public struct GenerationID: Sendable, Hashable, Codable, CustomStringConvertible {
    public let value: String
    /// 字面值常數用。非法值是程式錯誤 → trap。
    public init(_ value: String) { self.value = OpaqueIdentifier.require(value, "GenerationID") }
    /// 外來資料用（解碼、CLI 參數）。非法值 → throw，不進 canonical store。
    public init(validating value: String) throws {
        try OpaqueIdentifier.validate(value)
        self.value = value
    }
    public init(from decoder: any Decoder) throws {
        try self.init(validating: try decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }
    public var description: String { value }
}

/// 當下生效的排序策略識別碼。
public struct RankingPolicyID: Sendable, Hashable, Codable, CustomStringConvertible {
    public let value: String
    public init(_ value: String) { self.value = OpaqueIdentifier.require(value, "RankingPolicyID") }
    public init(validating value: String) throws {
        try OpaqueIdentifier.validate(value)
        self.value = value
    }
    public init(from decoder: any Decoder) throws {
        try self.init(validating: try decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }
    public var description: String { value }
}

/// 指向一則自由文字 note 的不透明 ref。
///
/// 用隨機 ID、**不用**內容雜湊：短句的雜湊可被字典攻擊還原，那等同把 note
/// 原文放進 canonical 層。note 本文住在另一個 opt-in 加密 store（本 change
/// 範圍外）。
public struct NoteReference: Sendable, Hashable, Codable, CustomStringConvertible {
    public let id: UUID
    public init(id: UUID) { self.id = id }
    public static func random() -> NoteReference { NoteReference(id: UUID()) }
    /// UUID 是唯一可表達的形狀——沒有一個 initializer 收得下自由文字。
    public init(from decoder: any Decoder) throws {
        self.id = try decoder.singleValueContainer().decode(UUID.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(id)
    }
    public var description: String { id.uuidString }
}

/// 一次呈現的不透明識別碼。
///
/// 存在的理由是歸屬：同一個 anchor 可能在很多次呈現裡出現過，只靠
/// (anchor, generation) 無法判斷某次點擊來自哪一次呈現，於是也就無法判斷該
/// 記在哪一個策略頭上。這是隨機 ID、不含任何內容，與 note ref 同一種東西。
public struct PresentationID: Sendable, Hashable, Codable, CustomStringConvertible {
    public let id: UUID
    public init(id: UUID) { self.id = id }
    public static func random() -> PresentationID { PresentationID(id: UUID()) }
    public init(from decoder: any Decoder) throws {
        self.id = try decoder.singleValueContainer().decode(UUID.self)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(id)
    }
    public var description: String { id.uuidString }
}

/// 互動事件的種類。封閉五值。
public enum EventKind: String, Sendable, Codable, CaseIterable {
    case shown
    case opened
    case cited
    case pinned
    case dismissed
}

public enum EventValidationError: Error, Sendable, Equatable {
    case pinRequiresNoteReference
    case noteReferenceOnNonPinEvent
}

/// 一筆 canonical 使用歷史。
///
/// 欄位全是指標與識別碼：沒有 chunk 原文、沒有 query 原文、沒有 note 原文。
/// 這條約束靠 schema 保證，不靠自律——要新增會存文字的欄位，先回去讀
/// CLAUDE.md 的記憶層硬約束。
public struct Event: Sendable, Hashable, Codable {
    public let kind: EventKind
    public let anchor: Anchor
    public let timestamp: Date
    public let generation: GenerationID
    public let policy: RankingPolicyID
    /// 只有 `.pinned` 有值；其餘一律 nil。由 init 驗證，解碼路徑同樣走這條驗證。
    public let noteRef: NoteReference?
    /// 這筆互動來自哪一次呈現。非呈現情境（例如從別處直接引用）為 nil。
    public let presentation: PresentationID?

    public init(
        kind: EventKind,
        anchor: Anchor,
        timestamp: Date,
        generation: GenerationID,
        policy: RankingPolicyID,
        noteRef: NoteReference?,
        presentation: PresentationID? = nil
    ) throws {
        switch (kind, noteRef) {
        case (.pinned, nil): throw EventValidationError.pinRequiresNoteReference
        case (.pinned, _): break
        case (_, .some): throw EventValidationError.noteReferenceOnNonPinEvent
        case (_, nil): break
        }
        self.kind = kind
        self.anchor = anchor
        self.timestamp = timestamp
        self.generation = generation
        self.policy = policy
        self.noteRef = noteRef
        self.presentation = presentation
    }

    /// 非 pin 的互動事件。kind 由呼叫端在編譯期選定，構造不會失敗。
    public static func interaction(
        _ kind: NonPinKind,
        anchor: Anchor,
        at timestamp: Date,
        generation: GenerationID,
        policy: RankingPolicyID,
        presentation: PresentationID? = nil
    ) -> Event {
        // 已由 NonPinKind 排除 .pinned，故此處不可能拋出。
        try! Event(
            kind: kind.eventKind, anchor: anchor, timestamp: timestamp,
            generation: generation, policy: policy, noteRef: nil,
            presentation: presentation)
    }

    /// pin 事件。ref 在此生成，note 原文不經過這一層。
    public static func pin(
        anchor: Anchor,
        at timestamp: Date,
        generation: GenerationID,
        policy: RankingPolicyID,
        presentation: PresentationID? = nil
    ) -> Event {
        try! Event(
            kind: .pinned, anchor: anchor, timestamp: timestamp,
            generation: generation, policy: policy, noteRef: .random(),
            presentation: presentation)
    }

    /// 解碼一律走驗證後的 init：外來檔案寫進來的第六種 kind、或 kind 與
    /// noteRef 不相稱的紀錄，都在邊界上被擋掉而不是進到 store 裡。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: try c.decode(EventKind.self, forKey: .kind),
            anchor: try c.decode(Anchor.self, forKey: .anchor),
            timestamp: try c.decode(Date.self, forKey: .timestamp),
            generation: try c.decode(GenerationID.self, forKey: .generation),
            policy: try c.decode(RankingPolicyID.self, forKey: .policy),
            noteRef: try c.decodeIfPresent(NoteReference.self, forKey: .noteRef),
            presentation: try c.decodeIfPresent(PresentationID.self, forKey: .presentation))
    }
}

/// 非 pin 的四種 kind。存在的理由是讓 `Event.interaction` 在型別上就不可能
/// 收到 `.pinned`，於是那條 `try!` 是可證明不會觸發的，而不是樂觀假設。
public enum NonPinKind: Sendable, CaseIterable {
    case shown
    case opened
    case cited
    case dismissed

    public var eventKind: EventKind {
        switch self {
        case .shown: .shown
        case .opened: .opened
        case .cited: .cited
        case .dismissed: .dismissed
        }
    }
}
