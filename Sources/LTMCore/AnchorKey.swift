import CryptoKit
import Foundation

/// Anchor 內容摘要的密鑰。
///
/// ## 為什麼摘要要加密鑰（#12）
///
/// `contentHash` 先前是未加密鑰的 `SHA256(normalized)`。而生產端唯一的 anchor
/// 建構點綁的是**整則 turn 的全文**，所以曝險完全取決於 turn 本身有多短——
/// 實測本機語料取樣 5,684 則：
///
/// | 門檻 | 佔比 |
/// |---|---|
/// | 長度 < 4 | 1.35% |
/// | 長度 < 8 | 1.74% |
/// | 長度 < 32 | 9.27% |
///
/// 最短的樣本是「繼續」（2 字）、「讀回驗證：」（5 字）。對這種 turn 做常見
/// 短句的 SHA-256 字典比對是平凡可行的，而**記憶層是本 repo 唯一必須備份的
/// 資料**——備份外流即可還原那些原文。
///
/// 同一份 code 對 `NoteReference` 早就承認過同一種攻擊（「短句的雜湊可被字典
/// 攻擊還原，那等同把 note 原文放進 canonical 層」）並改用隨機 ID。**同一種
/// 攻擊，兩套標準**，這裡是把標準對齊。
///
/// ## 為什麼是參數而不是全域
///
/// 與 `CorpusContainmentPolicy` 同一個理由：密鑰是**機器的性質**，不是某次
/// 呼叫的性質，但把它做成全域可變狀態會讓「忘了設定」變成一個安靜的降級
/// ——而降級的方向是回到未加密鑰。做成必填參數，忘記就編不過。
///
/// ## 誠實邊界
///
/// 這**不是**加密。持有密鑰的人仍然可以對短句做字典比對——密鑰擋的是「只拿到
/// 記憶層備份」的人。所以它的價值完全取決於密鑰**不與 event store 一起同步**，
/// 而那是儲存端的責任（見 `LTMMemory` 的 Keychain 存取），不是這個型別的。
public struct AnchorKey: Sendable, Equatable {
    private let material: SymmetricKey

    public init(material: Data) {
        precondition(material.count >= 32, "anchor 密鑰至少要 32 bytes，收到 \(material.count)")
        self.material = SymmetricKey(data: material)
    }

    /// 從十六進位字串建構。長度為奇數、含非十六進位字元、或不足 32 bytes 時回 `nil`。
    ///
    /// 解析只寫在這裡一份：`ltm memory --import-key` 與 `AnchorKeyStore` 的
    /// `LTM_ANCHOR_KEY` 都用它，而「同一件事有兩個寫者」在這裡的漂移方向是
    /// 「其中一份接受了另一份會拒絕的字串」。
    public init?(hex: String) {
        let ascii = Array(hex.utf8)
        guard ascii.count % 2 == 0 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x61...0x66: return c - 0x61 + 10
            case 0x41...0x46: return c - 0x41 + 10
            default: return nil
            }
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(ascii.count / 2)
        for i in stride(from: 0, to: ascii.count, by: 2) {
            guard let h = nibble(ascii[i]), let l = nibble(ascii[i + 1]) else { return nil }
            bytes.append(h << 4 | l)
        }
        guard bytes.count >= 32 else { return nil }
        self.init(material: Data(bytes))
    }

    /// 十六進位表示。**這是秘密**——只用於明示的匯出。
    public var hexEncoded: String { exported.map { String(format: "%02x", $0) }.joined() }

    /// 產生一把新的隨機密鑰。
    public static func generate() -> AnchorKey {
        AnchorKey(material: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    /// 匯出原始 bytes，供跨機器遷移。
    ///
    /// **換機器時舊 anchor 會全體 orphan，除非密鑰跟著搬**——那是刻意的，因為
    /// 「備份外流即可還原原文」正是這件事要擋的。匯出是使用者明示的動作。
    public var exported: Data { material.withUnsafeBytes { Data($0) } }

    /// 測試用的固定密鑰。
    ///
    /// 具名而不是隨手造，是為了讓 diff 一眼看得出哪些呼叫端是測試端。
    /// **生產路徑用到它就是 bug**，而那在 code review 上看得見。
    public static let forTesting = AnchorKey(
        material: Data(repeating: 0x2A, count: 32))

    func authenticationCode(for message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: material))
    }

    public static func == (lhs: AnchorKey, rhs: AnchorKey) -> Bool {
        lhs.exported == rhs.exported
    }
}
