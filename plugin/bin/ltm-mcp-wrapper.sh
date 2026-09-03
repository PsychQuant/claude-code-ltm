#!/bin/bash
# ltm-mcp-wrapper.sh — 確保 `ltm` 存在且版本正確，然後 `exec ltm mcp`。
#
# 為什麼 plugin 不直接指向 binary：binary 不進 git（每次 release 都是幾十 MB 的
# 二進位），所以 plugin 裝起來時 `bin/` 底下只有這支 script。第一次啟動時它從
# GitHub Release 下載對應版本。
#
# 設計沿用 psychquant-claude-plugins 既有的 wrapper 形狀（agent-cacher、
# che-telegram-mcp）：DESIRED_VERSION 釘住這個 plugin 期望的 binary 版本，
# sidecar 版本檔記錄裝了什麼，不合就重抓。
#
# **原始碼建置永不被覆寫**：搜尋順序把 `.build/` 排在最後，而只有裝在
# $INSTALL_DIR 的那份會被版本檢查換掉。開發時 `make install` 進 ~/bin 的那份
# 會被當成安裝版管理；直接跑 `.build/release/ltm-mcp` 的不受影響。

set -uo pipefail

GITHUB_REPO="PsychQuant/claude-code-ltm"
# **生態工具靠 `^BINARY_NAME=` 這一行認得這個 wrapper 要哪個 binary。**
# `harness-devtools:plugin-deploy` 的 Step 2.5（「binary 有沒有在 release 裡」的
# BLOCK）抽不到它就 `continue`——**靜默跳過整道關卡**。這一行本身在下面的邏輯裡
# 用不到（`ensure_binary` 收參數），存在的理由就是讓那道 gate 打得到。
BINARY_NAME="ltm"
INSTALL_DIR="$HOME/bin"
DESIRED_VERSION="0.4.0"   # 與 Sources/LTMCore/Version.swift 同步（ReleaseVersionSyncTests 釘住）
DOWNLOAD_TIMEOUT=300      # universal binary 較大，給足時間

# **一律用 GitHub Release 的 binary，不撿本機的原始碼建置。**
#
# 先前的搜尋順序含 `~/Developer/<repo>/.build/{release,debug}/` 與
# `/usr/local/bin`、`~/.local/bin`。那讓「我跑的是哪一版」失去單一答案：
# plugin 說 0.3.0、`~/bin/.ltm.version` 說 0.3.0，而實際 exec 的可能是某個
# 半小時前的 debug build。**版本檢查只套用在 `$INSTALL_DIR` 那一份**，撿到別處
# 的就整個跳過檢查——所以那不只是「偏好」，是一個會讓版本宣稱失效的洞。
#
# 順帶消掉的：repo 於 2026-08-26 由 claude-LTM 改名 claude-code-ltm，而寫死的
# 目錄名在改名後會**安靜地**失效（症狀是「它每次都重新下載」，看起來像效能問題
# 而不是路徑錯了）。列舉兩個目錄名可以擋這一次，擋不住下一次。
#
# 開發者要跑自己的 build：直接執行 `.build/release/ltm mcp`，或 `make install`
# 覆蓋 `~/bin/ltm`（下次版本不符時會被換掉，那是對的——它本來就不是那一版）。

mkdir -p "$INSTALL_DIR"

ensure_binary() {
    local name="$1"
    local installed="$INSTALL_DIR/$name"
    local version_file="$INSTALL_DIR/.${name}.version"
    local installed_version=""
    [[ -f "$version_file" ]] && installed_version=$(tr -d '[:space:]' < "$version_file" 2>/dev/null || true)

    # 只看 `$INSTALL_DIR` 那一份，而且版本必須相符——**兩個條件缺一都重抓**。
    local found=""
    [[ -x "$installed" && "$installed_version" == "$DESIRED_VERSION" ]] && found="$installed"

    local need_download=false
    [[ -z "$found" ]] && need_download=true

    if $need_download; then
        # **asset 名就是 binary 名**，因為 `harness-devtools:mcp-deploy` 是這樣上傳的
        # （`?name=$BINARY_NAME`）。先前這裡寫 `${name}-macos-universal`，那會 404
        # ——而 404 的症狀是「plugin 裝好了但 MCP server 起不來」，不是一個看得懂的
        # 錯誤。判準：**wrapper 遷就 pipeline，不是反過來**，因為 pipeline 是共用的。
        local asset="${name}"
        local base="https://github.com/${GITHUB_REPO}/releases/download/v${DESIRED_VERSION}"
        local tmp="${installed}.tmp.$$"
        echo "ltm: 下載 ${name} v${DESIRED_VERSION}" >&2
        if ! curl --fail --location --silent --show-error --max-time "$DOWNLOAD_TIMEOUT" \
                -o "$tmp" "${base}/${asset}"; then
            echo "ltm: 下載 ${name} 失敗（${base}/${asset}）" >&2
            rm -f "$tmp"
            return 1
        fi
        # sha256 比對。**這擋的是截斷與損毀的下載，不是竄改**——雜湊與 binary 走
        # 同一條 TLS 通道，能換掉其中一個的人也能換掉另一個。寫明是因為「有做
        # 雜湊比對」讀起來像後者。
        local sum_tmp="${tmp}.sha256"
        if curl --fail --location --silent --show-error --max-time 60 \
                -o "$sum_tmp" "${base}/${asset}.sha256"; then
            local expected actual
            expected=$(awk '{print $1}' "$sum_tmp")
            actual=$(shasum -a 256 "$tmp" | awk '{print $1}')
            rm -f "$sum_tmp"
            if [[ "$expected" != "$actual" ]]; then
                echo "ltm: ${name} 雜湊不符（下載可能不完整），未安裝" >&2
                rm -f "$tmp"
                return 1
            fi
        else
            rm -f "$sum_tmp"
            echo "ltm: 取不到 ${asset}.sha256，跳過完整性比對" >&2
        fi
        chmod +x "$tmp"
        mv "$tmp" "$installed"
        printf '%s' "$DESIRED_VERSION" > "$version_file"
        found="$installed"
        echo "ltm: 已安裝 ${installed}" >&2
    fi

    printf '%s' "$found"
}

# **單一 binary**：MCP server 是 `ltm mcp` 子命令，不是第二個執行檔。理由見
# `Sources/ltm/MCPCommand.swift`——出貨 pipeline 是單 binary 假設。
# 同一個 binary 也是使用者跑 `ltm build` 建索引用的那個。
LTM=$(ensure_binary "ltm") || {
    echo "ltm: ltm 無法就緒，MCP server 不啟動" >&2
    exit 1
}
exec "$LTM" mcp "$@"
