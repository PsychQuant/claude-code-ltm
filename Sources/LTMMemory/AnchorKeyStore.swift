import Foundation
import LTMCore
import Security

/// Anchor 密鑰的存放（#12）。
///
/// ## 為什麼是 Keychain，而不是記憶層目錄裡的一個檔
///
/// 這把密鑰要擋的是「拿到記憶層備份的人」。把它放在 `~/.claude-ltm/memory/`
/// 旁邊，備份會連它一起帶走——那等於沒有加密鑰。**密鑰必須不與 event store
/// 一起同步**，而 Keychain 是這台機器上唯一天然滿足這個條件的地方。
///
/// ## 換機器
///
/// 舊 anchor 在新機器上會全體 orphan，除非密鑰跟著搬。**那是刻意的**：能夠
/// 「只搬記憶層就繼續用」的設計，正是「只偷記憶層就能還原原文」的另一面。
/// 搬移是使用者明示的動作，走 `ltm memory --export-key` / `--import-key`。
public enum AnchorKeyStore {
    /// Keychain 的 service 識別，與 `LTM_ANCHOR_KEY_SERVICE` 可覆寫。
    ///
    /// 可覆寫是為了測試能用獨立的 service 名，不去碰使用者真正的那一把。
    public static var service: String {
        ProcessInfo.processInfo.environment["LTM_ANCHOR_KEY_SERVICE"] ?? "claude-ltm-anchor-key"
    }

    public enum StoreError: Error, Equatable, CustomStringConvertible {
        case keychainFailed(status: Int32, operation: String)
        case malformedKey(bytes: Int)
        /// 這個環境沒有可用的登入鑰匙圈（#45）。
        case noLoginKeychain(searched: String)

        public var description: String {
            switch self {
            case .keychainFailed(let status, let operation):
                return "鑰匙圈操作失敗（\(operation)，OSStatus \(status)）。"
            case .malformedKey(let bytes):
                return "密鑰格式不對（\(bytes) bytes，需要 32）。"
            case .noLoginKeychain(let searched):
                return """
                    這個環境沒有可用的登入鑰匙圈（找過 \(searched)）。
                    常見於：SSH 進來、launchd／cron、CI、或以另一個 HOME 執行。

                    anchor 密鑰改從環境變數給：

                      export LTM_ANCHOR_KEY=$(ltm memory --export-key)   # 在有鑰匙圈的 session 匯出

                    這**不是**關掉加密鑰——它是密鑰的另一個來源，給壞值一樣會拒絕。
                    """
            }
        }
    }

    /// 在碰 Keychain **之前**判斷這個環境有沒有登入鑰匙圈（#45）。
    ///
    /// ## 為什麼要先判斷，而不是讓 API 回錯誤
    ///
    /// 因為它不會回錯誤。舊版檔案式 keychain 在找不到登入鑰匙圈時**彈一個 modal
    /// 對話框**（「找不到鑰匙圈來儲存『default』」）並停在那裡等人點——失敗沒有
    /// 變成 status code，變成一個等人的視窗。實測過兩次：一次讓測試卡了 116 秒，
    /// 一次在驗證 wrapper 時彈給使用者。
    ///
    /// ## 為什麼不改用 data-protection keychain
    ///
    /// 那一層沒有登入鑰匙圈的概念，本來是對的解。**但它要
    /// `keychain-access-groups` entitlement，而那需要嵌 provisioning profile**——
    /// Developer ID 的 CLI 發布做不到。實測（2026-08-26）：
    ///
    /// | 簽法 | `SecItemAdd` with `kSecUseDataProtectionKeychain` |
    /// |---|---|
    /// | ad-hoc | `-34018`（errSecMissingEntitlement）|
    /// | Developer ID，無 entitlement | `-34018` |
    /// | Developer ID ＋ entitlement，無 profile | 行程被 **SIGKILL** |
    ///
    /// 所以這條路關著，剩下的只有「先判斷」。
    ///
    /// ## 誠實邊界
    ///
    /// 這是**啟發式**，不是 API 的答案：它看 `~/Library/Keychains/` 底下有沒有
    /// login keychain 檔。把鑰匙圈放在非標準位置的人會被誤擋——代價是一則指名
    /// 補救方式的錯誤，而不是一個卡住的對話框。方向刻意選這邊。
    /// **用 `$HOME`，不是 `NSHomeDirectory()`**（#45）。
    ///
    /// 後者讀的是密碼資料庫裡的家目錄，**不跟隨 `HOME` 環境變數**；而舊版 keychain
    /// 層找 login keychain 用的是 `$HOME`。實測：以假 `HOME` 執行時
    /// `NSHomeDirectory()` 仍回真實家目錄，於是這道 pre-check 看到真的鑰匙圈、
    /// 判定「有」，然後 `SecItemAdd` 照樣走進對話框那條路並回 `-60006`
    /// （The authorization was canceled by the user）。
    ///
    /// **檢查的東西必須與被檢查的那一層看的是同一個。**
    static func loginKeychainDirectory() -> String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return home + "/Library/Keychains"
    }

    static func hasUsableLoginKeychain() -> Bool {
        hasUsableLoginKeychain(inKeychainDirectory: loginKeychainDirectory())
    }

    /// 上面那個的**純函式版本**，目錄由呼叫端給。
    ///
    /// 分出來是為了讓測試不必動 `HOME`——那是 **process 全域**的，而 swift-testing
    /// 預設平行跑。本 repo 為這件事付過代價：`CorpusLocation` 的一條測試改了
    /// `CLAUDE_CONFIG_DIR`，讓另一條無關的測試三次跑紅一次
    /// （`readOnlyRoot(configDirectory:home:)` 的 doc 記著這件事）。
    ///
    /// **偶爾成功的測試比偶爾失敗的更糟**，而改全域環境的測試兩者都會發生。
    static func hasUsableLoginKeychain(inKeychainDirectory dir: String) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return false
        }
        return entries.contains { $0.hasPrefix("login.keychain") }
    }

    /// 讀出現有的密鑰；沒有就產生一把並存起來。
    ///
    /// **不提供「讀不到就用未加密鑰」的退路**（#12 的決定：無 opt-out）。一個
    /// 會靜默退回未加密鑰的分支，會讓這整件事的價值取決於沒有人踩到它。
    ///
    /// ## `LTM_ANCHOR_KEY` 是**另一個來源**，不是 opt-out
    ///
    /// 「要不要加密鑰」與「密鑰從哪來」是兩件事。前者沒有選項；後者有兩個：
    /// Keychain（預設）與這個環境變數（64 個十六進位字元）。兩者給的都是真的
    /// 密鑰，所以走哪一條都不會退化成未加密鑰——**給了一個壞值會拋，不會放行**。
    ///
    /// 它存在的兩個理由：
    ///
    /// 1. **跨機器遷移**：`--export-key` 匯出、在新機器上餵進來。
    /// 2. **測試與 CI**：swift-testing 的 exit test 會 re-exec 測試 binary，而那個
    ///    subprocess 沒有登入鑰匙圈 session——實測 macOS 會彈出「找不到鑰匙圈」
    ///    對話框並把測試卡住（一條測試等了 116 秒）。沒有這條路，這個功能等於
    ///    要求每個跑測試的人手動點掉對話框。
    public static func loadOrCreate() throws -> AnchorKey {
        if let hex = ProcessInfo.processInfo.environment["LTM_ANCHOR_KEY"] {
            guard let key = AnchorKey(hex: hex) else {
                throw StoreError.malformedKey(bytes: hex.count / 2)
            }
            return key
        }
        // **在碰 Keychain 之前擋掉沒有登入鑰匙圈的環境**（#45）——否則
        // `SecItemAdd` 會彈 modal 並停在那裡等人點，而不是回一個錯誤。
        guard hasUsableLoginKeychain() else {
            throw StoreError.noLoginKeychain(searched: loginKeychainDirectory())
        }
        if let existing = try load() { return existing }
        let fresh = AnchorKey.generate()
        try save(fresh)
        return fresh
    }

    public static func load() throws -> AnchorKey? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw StoreError.keychainFailed(status: status, operation: "SecItemCopyMatching")
        }
        guard let data = item as? Data, data.count >= 32 else {
            throw StoreError.malformedKey(bytes: (item as? Data)?.count ?? 0)
        }
        return AnchorKey(material: data)
    }

    public static func save(_ key: AnchorKey) throws {
        var attributes = baseQuery()
        attributes[kSecValueData as String] = key.exported
        // **不進 iCloud Keychain 同步**——同步等於把它送到別的地方，而這把密鑰的
        // 價值就在於它不離開這台機器。
        //
        // **這個保證來自「沒有設 `kSecAttrSynchronizable`」，不是來自下面這一行**
        // （#45）。SDK header 寫明 `kSecAttrAccessible` 要在 macOS 生效需要同時設
        // `kSecUseDataProtectionKeychain`，而那條路對本專案的發布形式關著（見
        // `hasUsableLoginKeychain` 的說明）。舊版 keychain 的項目預設就是本機
        // 限定、不同步，所以**結果成立而理由不同**——先前這則註解把保證掛在一個
        // 不生效的屬性上。
        //
        // 留著這一行是無害的（不生效但不出錯），而拿掉它會讓日後改用
        // data-protection keychain 時少一個該有的設定。
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = [kSecValueData as String: key.exported] as CFDictionary
            let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, update)
            guard updateStatus == errSecSuccess else {
                throw StoreError.keychainFailed(status: updateStatus, operation: "SecItemUpdate")
            }
            return
        }
        guard status == errSecSuccess else {
            throw StoreError.keychainFailed(status: status, operation: "SecItemAdd")
        }
    }

    public static func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keychainFailed(status: status, operation: "SecItemDelete")
        }
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "default",
        ]
    }
}
