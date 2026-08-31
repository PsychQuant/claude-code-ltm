import Foundation

/// 極小的旗標解析。
///
/// 手寫的理由見 Package.swift（零第三方依賴）。它只認得這個 CLI 實際用到的
/// 形狀：`--flag`、`--key value`、`--key=value`，其餘是位置參數。
struct Arguments {
    private(set) var positional: [String] = []
    private var flags: Set<String> = []
    private var values: [String: String] = [:]

    /// 需要帶值的選項。列舉出來才能區分 `--project foo`（吃掉 foo）與
    /// `--record foo`（`foo` 是位置參數）——否則 `--record` 會安靜地把下一個
    /// 參數吞掉。
    init(_ raw: [String], valueOptions: Set<String>) {
        var index = 0
        while index < raw.count {
            let token = raw[index]
            if token.hasPrefix("--"), let equals = token.firstIndex(of: "=") {
                let key = String(token[token.index(token.startIndex, offsetBy: 2)..<equals])
                values[key] = String(token[token.index(after: equals)...])
            } else if token.hasPrefix("--") {
                let key = String(token.dropFirst(2))
                if valueOptions.contains(key), index + 1 < raw.count {
                    values[key] = raw[index + 1]
                    index += 1
                } else {
                    flags.insert(key)
                }
            } else if token.hasPrefix("-"), token.count > 1, !token.hasPrefix("--") {
                flags.insert(String(token.dropFirst()))
            } else {
                positional.append(token)
            }
            index += 1
        }
    }

    func has(_ name: String) -> Bool { flags.contains(name) }
    func value(_ name: String) -> String? { values[name] }
    func integer(_ name: String) -> Int? { values[name].flatMap(Int.init) }

    /// 出現了但不被這個子命令認得的選項。
    ///
    /// 回報未知選項而不是忽略：一個打錯的 `--jsno` 被忽略時，使用者拿到的是
    /// 人類可讀輸出而不是 JSON，而他會以為 `--json` 沒作用。
    func unknown(known: Set<String>) -> [String] {
        (flags.union(values.keys)).subtracting(known).sorted()
    }
}

enum Output {
    static func error(_ message: String) {
        // `try?`：診斷訊息沒有能力殺掉行程（#50）。
        try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
    }
}
