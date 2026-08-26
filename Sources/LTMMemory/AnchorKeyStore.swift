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

    public enum StoreError: Error, Equatable {
        case keychainFailed(status: Int32, operation: String)
        case malformedKey(bytes: Int)
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
            guard let material = Data(hexEncoded: hex), material.count >= 32 else {
                throw StoreError.malformedKey(bytes: hex.count / 2)
            }
            return AnchorKey(material: material)
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
        // 只在這台機器解鎖後可讀，且**不進 iCloud Keychain 同步**——同步等於把
        // 它送到別的地方，而這把密鑰的價值就在於它不離開這台機器。
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

extension Data {
    /// 十六進位字串 → bytes。長度為奇數或含非十六進位字元時回 `nil`。
    init?(hexEncoded hex: String) {
        let scalars = Array(hex.utf8)
        guard scalars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(scalars.count / 2)
        for i in stride(from: 0, to: scalars.count, by: 2) {
            guard let high = Data.nibble(scalars[i]), let low = Data.nibble(scalars[i + 1])
            else { return nil }
            bytes.append(high << 4 | low)
        }
        self.init(bytes)
    }

    private static func nibble(_ ascii: UInt8) -> UInt8? {
        switch ascii {
        case 0x30...0x39: return ascii - 0x30
        case 0x61...0x66: return ascii - 0x61 + 10
        case 0x41...0x46: return ascii - 0x41 + 10
        default: return nil
        }
    }
}
