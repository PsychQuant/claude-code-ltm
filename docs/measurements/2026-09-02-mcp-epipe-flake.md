# `mcpExitsNamedWhenStdoutCloses` 的 flake：失敗形態、探測、與修法效力（#57）

**日期**：2026-09-02〜03。**機器**：M5 Max、128 GB、macOS 27、Swift 6 toolchain、
系統 libsqlite3 3.54.0。所有迴圈都是 `swift test`（全套件，平行執行）。

## 失敗形態（確定）

server 端零擾動追蹤（環境變數閘、結束時一次寫 stderr，臨時注入 `MCPCommand`，
已還原）在多次 flake 得到逐字一致的時間線：

> `L1 initialize | W1=148B | L2 tools/list | W2=665B（成功）| nil after 2 errno=0 feof=1`

因果序：test 關讀端 → 寫 tools/list → server 讀 L2 → **W2 寫成功** → stdin EOF →
exit 0。連送 5 則時 W2–W6 全部成功，跨 4.4 ms（下界；上界未知）。

「失敗要 5 秒」是 swift-testing 失敗後 backtrace 符號化的成本；測試本體 17 ms。

## 重現率（改前）

| 形狀 | 紅／總 |
|---|---|
| filtered 單跑 | 0/40 |
| 全套件 | 1/30、1/30、4/120、3/120、4/120、1/120、1/200 |

命令（每輪）：`OUT=$(swift test 2>&1); grep -qE "with [0-9]+ issue" <<<"$OUT"`。

## 探測（每項直接實驗；零命中支持「該設定下未重現」，不是邏輯排除）

| 候選 | 實驗 | 結果 |
|---|---|---|
| 外部行程繼承 pipe fd | parent 端 pipe fd `F_SETFD FD_CLOEXEC`（確認 `run()` 後仍在）；120× 全套 | 4/120 |
| `fork()` 子行程 | `pthread_atfork` child handler＋backtrace；120× | 零觸發 |
| Foundation `read(upToCount:)` | raw `read(2)` 取代；120×。另探針：讀 1B 後 raw read 得 199B（無預讀） | 3/120 |
| Foundation `close()` 延遲 | 探針：Foundation／raw read × Foundation／raw close，CPU 負載，各 200 輪 | close 後成功寫入 0 |
| dispatch 讀源 | grep `readabilityHandler|DispatchIO|makeReadSource` | 零 |
| XNU spawn fd 表複製窗口 | 8 執行緒風暴：`/usr/bin/true` 76,675 次、debug `ltm` 32,593 次；寫者每 200 µs 寫一次、時戳比 close | close 後成功寫入 0 |
| 並發 `readDataToEndOfFile` | 6 執行緒 3,744 輪 | 0 |
| （DA）本行程以別 fd 號持有 | fd 表掃描；30 次全套 | 零別名，但 30 次無 flake，**未取樣到目標狀態**——未決 |

## 修法效力

| 版本 | 紅／總 | 備註 |
|---|---|---|
| 持續送請求（每 5 ms、≤2 s）、`try?` | 0/200 | **但** verify 實測：host SIGPIPE=SIG_DFL，server 退出後補寫會殺掉整個測試行程——負載下 5/270 exit 141 |
| ＋`F_SETNOSIGPIPE`＋有界等待（10 s 逾時 terminate/kill） | **0/100 紅、0/100 整輪 crash** | 全套件 ×100，全程 8 個 `yes > /dev/null` CPU spinner（重現第一版 5/270 host-kill 的負載條件）；exit code 逐輪檢查 |

`F_SETNOSIGPIPE` 本身的效力（獨立探針，child 先 `waitUntilExit` 再對其 stdin write）：無旗標 → 行程被 SIGPIPE 殺、exit 141、無輸出；有旗標 → `write(contentsOf:)` 拋 `NSCocoaErrorDomain code=512`、行程存活、exit 0。

## 誠實邊界

- 全部單機；flake 率本身有 30–200 次的取樣噪音。
- 「0/200」是統計證據不是證明；持有者活得比 2 s 久時測試會以「必須是正常 exit」紅。
- 機制未定。
