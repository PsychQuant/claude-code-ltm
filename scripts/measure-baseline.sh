#!/bin/bash
# 基準查詢量測（#63）：讀 scripts/baseline-queries.txt，逐條跑
#   ltm query --all-projects --k <k> --json -- <查詢>
# **stdout 第一行是 `set sha256:<12 hex> k=<k>`（非註解行內容的指紋與這次的 k——查詢集一換，指紋就換；
# verdict 全是「前 k 名」的性質，k 不同也不可比；紀錄要連這一行一起引，兩次量測這一行不同就不能逐列對齊，
# `#N` 只是檔內位置），之後每列 `#N <ms>ms <verdict>`**（例如
# `#3 812ms clean tool=1`；`<ms>` 是整數毫秒，後面緊接字面 `ms`）。
# 查詢文字、命中內容與密鑰不進 stdout／stderr——這句只對**第四行 `exec` 生效之後**的世界成立。
# 防禦邊界（一條性質，不點名、不說「只有」：R14 寫成總括判準、R15 寫成封閉六項、R16 寫成「第一行之前只有 BASH_ENV」，三版都在
# 第一個未列的成員上為假——R17 三個讀者各拿一個：經繼承的 `export -f builtin`、`PS4` 命令替換＋繼承的 xtrace、`bash --login`
# 的 profile）：**凡是在第四行 `exec` 生效之前，能在本行程執行呼叫端的程式碼、或改變前四行任一命令字語意的機制，一律不在防禦內**。
# 切點是護甲**完成**的那一刻，不是它開始的那一刻——前四行本身跑在呼叫端的 shell 裡，那裡的一切都是呼叫端的。查法：在 `BASH_ENV`
# 放一行、或 `export -f builtin`、或 `PS4='$(…)'` 配 `SHELLOPTS=xtrace`，任一種都在 exec 之前執行。這一類等同操作者自己 cat 查詢檔。
# exec 之後：環境只含白名單（下方），`BASH_ENV`／`SHELLOPTS`／匯出的函式與變數／`PS4`／`PYTHONPATH` 都不在——測試驅動的是這一側
# （xtrace、errexit、allexport、readonly、同名函式、DEBUG trap、經繼承的 `BASH_FUNC_*` 函式，各一臂）。前兩行 `builtin trap - …` 與
# `builtin set +x` 防的是**意外**（呼叫端環境裡殘留的 `set -x`／DEBUG trap 會 trace 到第四行、密鑰在那裡展開）——不是防禦，是
# 讓意外不延續；有臂（假密鑰）。
# 哨兵 `LTM_MB_CLEAN=$$`（exec 不換 PID）擋的是**殘留**（profile 裡的 export、上一次的環境、別的 PID）不是**偽造**：任何在 execve
# 前知道子行程 PID 的父行程都對得上（`bash -c '單一命令'` 不 fork）；對上之後 fd 3 沒有正確的頭標記時，在 fd 建得起來的世界裡 → 70
# （四臂），fd 耗盡時見下方 rlimit。PID 重用時殘留值也會撞上，同樣落到 70。
# 前四行程式碼：
#   1. `builtin trap - DEBUG ERR RETURN EXIT`（trap 會在下一個命令前重開 xtrace，R15）。
#   2. `builtin set +x`。順序不能反：`set +x` 放第一行時，DEBUG trap 在第二行前重開 xtrace、之後每一行都被 trace（R17 實測，
#      密鑰在 fd 3 子 shell 裡就上 stderr）。繼承的 xtrace 下前兩行各被 trace 一次、`PS4` 各展開一次——這是結構下限，而 PS4 在
#      exec 之前，屬防禦外。
#   3. `LTM_MB_WHITELIST="…"`：白名單的唯一一份，寫端與讀端共用（同步測試釘它與這段散文、與 `Sources/` 裡 `environment["…"]`
#      讀的每一個名字互相釘住：散文＝變數；Sources ⊆ 變數；變數 − Sources ＝ 腳本自己用的五個）。
#   4. `builtin exec -c /usr/bin/env PATH=… HOME=… LTM_MB_CLEAN=$$ /bin/bash -- "$0" "$@" 3< <(白名單) || exit 70`：以**空環境**
#      重新啟動自己。argv 上只有 PATH、HOME（re-exec 出來的 bash 要用它展開 PATH 裡的 `~` 才找得到 `$0`；`${HOME+"HOME=$HOME"}` 的
#      內層引號讓含空白的值仍是一個字——查法 `HOME='/a b' bash -c 'printf "[%s]" ${HOME+"HOME=$HOME"}'`）與哨兵；白名單裡有設的變數
#      以 NUL 分隔的 `NAME=VALUE` 走**繼承的 fd 3**（值不經任何行程的 argv——R14 版把密鑰寫成 `env` 的 argv，execve 稽核會永久記下
#      它，R15）。fd 3 有 framing：第一筆 `LTM_MB_FD3=$$`、最後一筆 `LTM_MB_END=1`；讀端要求頭標記的值對、每筆是 `NAME=VALUE`、
#      NAME 在白名單且 `export` 收得下（非法識別碼由 `export` 自己拒絕、腳本看它的離開碼）、看到尾標記才算到齊、每次 `read` 十秒內要返回——任一不成立 → 70（R16／R17，
#      各有臂）。`|| exit 70` 只在重導目標開不出來（不存在的路徑、管線建不出來）時 fire；`/dev/fd` dup 失敗那一段 bash 直接結束
#      shell，`||` 沒機會跑（見 rlimit）。
#   白名單：HOME、LC_ALL、LANG、TMPDIR、LTM_BIN、LTM_BASELINE_QUERIES、以及 ltm 自己讀的 CLAUDE_CONFIG_DIR、LTM_ANCHOR_KEY、
#   LTM_ANCHOR_KEY_SERVICE、LTM_BUILD_BATCH_CHUNKS、LTM_BUILD_MEMORY_BUDGET_MB、LTM_CORPUS_ROOT、LTM_DERIVED_ROOT、LTM_MEMORY_ROOT、
#   LTM_TEST_CLOCK_STEP_SECONDS（R14 版只傳三個 LTM_*，指向受控索引的量測會靜默量到真索引，R15）。白名單裡的東西**原樣轉發**：
#   呼叫端殘留的 `LTM_DERIVED_ROOT` 會讓這一輪量到別棵索引而指紋不變（指紋只認查詢集）、rc 0；`LTM_ANCHOR_KEY` 值錯 → 事件全
#   orphan 而 rc 0（.claude/rules/anchor-key-in-probes.md）；PATH 上的 python3 被換掉 → 查詢集上該行程的 stdout；`/usr/bin/env` 不在
#   → 126。這幾條各有各的訊號或沒有訊號，是白名單這個機制本身的另一面。
#   兩個 python 都以 `-I -S` 啟動：cwd 不進 `sys.path`（cwd 放一支 `hashlib.py` 就能整份接走查詢集並回一個合形狀的假指紋、放一支
#   `json.py` 就能改掉每一列 verdict，R15／R16，各有臂）、PYTHONPATH／user site 不進（`-I`）、解譯器自己的 site-packages 與 `.pth`／
#   `sitecustomize` 也不進（`-S`，R16；無臂——要驅動得改系統的 site）；`-I` 含 `-E`，所以刻意不轉發任何 `PYTHON*`。
#   R13 曾對這一族逐名字修（`builtin read`／`builtin printf`／`builtin unset`、`set +e`、readonly 只查 `QF_CONTENT`），R14 一輪
#   再冒五個同名（`set`、`local`、`[`、`readonly SETID`、`readonly bad`）——列舉會漏，判準不會；那些拼法在 re-exec 之後驅動不了，
#   R14 已拆（程式碼行裡沒有 `builtin read`；這句話自己與上一句會被 grep 命中）。
# 判準（re-exec 之後）是「每一個拿得到查詢內容的子行程，它的 stderr 都不是可能載內容的通道」：指紋 python、judge python、
# ltm 的 stderr 都丟掉，judge 與 ltm 的 stdin 都接 /dev/null（judge 對 ltm 寫的 `close_fds=True` 是 Python 的預設值，寫出來是文件、
# 無行為）；兩個 process substitution 的子 shell 只跑 builtin `printf`，運算元不會上 stderr。繼承的描述子：fd 3 看到尾標記就關
# （尾標記之後的記錄不讀）；process substitution 自己的讀端（bash 3.2 配 63，關不掉）只被指紋 python 繼承（judge 只有 0／1／2，
# R17 實測）——白名單的寫端寫完即退出，尾標記是它最後一筆，所以指紋 python 起跑時那個描述子已在 EOF（R16／R17 實測 `os.read`
# 回空）；它是衛生問題不是通道，寫在這裡是讓下一個把寫端換成長命行程的人知道它會變成通道。
# 跨 exec 保留、白名單清不掉的行程狀態：cwd（後果由 `-I -S` 關掉）、umask、關掉或重導的 fd（stderr 關掉 → 診斷消失）、信號處置、
# rlimit。`nofile` 由高往低的實測階梯（R17，門檻隨呼叫端已開的 fd 數移動，不寫數字）：正常 → **rc 0 零輸出**（`/dev/fd` dup 失敗，
# bash 直接結束 shell，`||` 與讀端的 70 都沒機會跑）→ rc 1 零列（撞「任一列 error」的號）→ 70（管線建不出來，`||` fire）→ 134。
# 這一段從腳本內關不掉。所以**離開碼 0 的意義是「0 且 stdout 第一行是 set 行」**——這是消費端的硬規則，不是註腳；任何讓 set 行
# 印不出來的失效（`SHELLOPTS=noexec`／`onecmd`、fd 耗盡、…）都落在這條規則下，紀錄本來就要連那一行一起抄。
# 作業系統的可見面：查詢原文在執行期會在 python3 與 ltm 的 argv 上（CLI 的查詢就是位置參數、`--` 終止符用得對），同一帳號的行程
# `ps -ww` 看得到（Linux 上 `/proc/<pid>/cmdline` 預設任何帳號可讀；容器 PID namespace、hidepid 下更窄）、存活時間是那一列的
# wall clock；密鑰不在任何 argv 上（R15，execve 稽核不再記下它），但它在 re-exec 的 bash、每個 judge 與 ltm 的**環境**裡，存活
# 時間是整個 run，同帳號 `ps -E`／`/proc/<pid>/environ` 看得到——那正是 anchor-key-in-probes.md 要它待的地方。這些都不是本腳本的
# 輸出通道；寫在這裡是因為第一句是全稱。
# `$0` 同時是 re-exec 的目標：腳本餵 stdin（`bash -s < measure-baseline.sh`）時 `$0` 是 `/bin/bash`，re-exec 會拿它當腳本跑 →
# 126；不支援。呼叫端用哪個 bash 都會被換成 `/bin/bash`（shebang 本來就是它）。
# 指紋揭露什麼：見 docs/measurements/README.md 的量測段（單一版本，這裡不複述——R8 抓到兩份漂移、R12 抓到這裡又複述了一半）。
#
# 為什麼這麼小氣：這支腳本會在 Claude Code session 裡被跑。今天會進索引的是逐字稿裡的純字串
# `message.content`（使用者鍵入的 prompt 常是這一種，整段）、`text` block（使用者輸入、Claude 的散文）
# 與 tool_use 的七個 metadata 欄位（`CorpusScanner.toolMetadataFields`，含 Bash 的 `command=`／
# `description=`、`ltm_query` MCP 工具的 `query=`）。Bash 的 stdout 是 tool_result、
# 今天不被索引——但 Claude 引述輸出的那句散文一定被索引。印了查詢字串，就等著被引述（#63 的 root cause）。
#
# verdict（封閉字母表；只有這幾個，不得類推。四處列舉——本檔頭的「error tokens」行、docs/measurements/README.md、
# 測試的 errorTokens、程式碼裡的 `error(...)` 輸出點——由 Tests/LTMMCPTests/BaselineQueryFileTests.swift 的同步測試
# 逐一相等，`ERROR_TOKENS` 變數等於它們扣掉 `<rc>`／`sig<N>` 兩個樣式 token 的子集。「輸出點」的判法是形狀：
# 程式碼裡**每一個** `error(` 出現（整行註解除外）都必須是兩種輸出述句形狀之一——python 的
# `print(…); sys.exit(0)` 且字面在雙引號裡、bash 的 `valid_row "$row" || row="0 error(<token>)"`——不然測試紅，
# **行尾註解裡的字面也紅**（valid_row 用變數 E_OPEN 比對、不寫字面，所以沒有任何一行被略過）。它擋的是
# 刪掉／改名輸出點而清單沒跟；不證明那一行可達或會執行，那由每個 token 的行為測試扛）：
#   clean tool=<n>   前 k 名沒有任何一個 snippet 含**這條查詢的原文**（空白摺疊、大小寫摺疊後的子字串比對）。
#   self  tool=<n>   前 k 名至少一個 snippet 含這條查詢的原文——儀器看見了自己（量測命令列、
#                    `ltm_query query=…`、被引述的那句散文，都是這個形狀）。這一輪該條的命中品質不可比；
#                    耗時仍可比。
#   empty tool=0     零命中。查詢已經對不到任何東西——這不是 clean，但也不計入離開碼。
#   error(<token>)   這一列沒量到。token 是下面這一行的封閉集合：
#   error tokens：<rc> sig<N> blank exec json shape judge
#                    <rc>＝ltm 非零離開碼（不含 0、無前導零）；sig<N>＝ltm 被訊號 N 殺掉（N≥1）；blank＝這一行在 Unicode 空白摺疊
#                    後是空的（例如只有 U+3000；不跑 ltm，因為空針對任何命中都算 self）；exec＝ltm 起不來；
#                    json＝輸出不是 JSON；shape＝JSON 不是陣列、或**前 k 個**元素不是帶字串 snippet 的物件（第 k+1 筆不看，R8）；
#                    judge＝judge 自己掛了、印了不合形狀的東西、或這條查詢的 bytes 不是合法 UTF-8（R15：surrogate 永遠對不上
#                    snippet 的真 Unicode，會安靜地判 clean）。
# `tool=<n>` 是前 k 名裡含 `⟨tool ` 的 snippet 數。它**不是**污染訊號，只是給 #62 前後比較看的觀察值——
# 理由、誠實邊界、第一版判準為何被換掉，只有一份，在 docs/measurements/README.md 的 `tool=<n>` 段（這裡不複述）。
#
# `self` 會漏什麼（這份清單必然不完整）：查詢原文**跨過** metadata 欄位 200 字元截斷的命令——前綴進了
# 索引、會靠它排名，self 卻判 clean（完全落在截斷之後的則不在索引裡、也不會靠它排名）；空白與大小寫
# 以外的改寫（全形／半形、標點、換序）；
# 反過來，語料裡本來就逐字含這串字的**實質** turn 會被判 self——那不是污染，是正常召回，self 分不出來。
# 要分，只能在 Claude Code 之外的 shell 讀命中內容。
#
# <ms>：ltm 行程 fork→exit 的 monotonic 牆鐘（含 process 啟動、查詢前的增量併入、檢索、輸出），
# 不含 judge。單一樣本、沒有暖身；第 1 列是否系統性偏高**沒有量過**（要量：同一集合連跑兩次、比第 1 列），
# 比較各列前先看這點。跟舊紀錄的命令
# （`.build/release/ltm query "$q" --k 5`，單一 project、無 --json）量的不是同一件事，
# 不要把本腳本的列與 2026-09-01 之前的表對齊——見 docs/measurements/README.md。
#
# 離開碼（腳本自己的 `exit N` 是封閉集合，同步測試對照程式碼；re-exec 失敗的 126／127 見下一行）：0 1 64 65 66 69 70
#   re-exec 那一行失敗時 bash 自己給 126／127，在集合外、無測試——查法：把 `/usr/bin/env` 換成不存在的路徑 → 126（R15）。
#   0 全部量到（含 empty；消費端要同時看到 set 行——見上方 rlimit 段的硬規則）；1 任一列 error(…)（每列照印完才離開）；
#   64 k 不是 1–1000 的整數、或給了超過一個引數（舊習慣把查詢放第二個參數時，字串已進 metadata，這次不算量到，R14）；
#   65 查詢檔沒有任何非註解行；66 查詢檔不是可讀的一般檔案、讀不了、含 NUL、或讀取中斷；69 ltm 不是可執行的一般檔案；
#   70 沒有 python3、算不出查詢集指紋、或白名單沒有完整經 fd 3 到達（R16）。在 set 行印出**之後**才判定的有兩個：1（有列）與
#   65（無列）；其餘 stdout 都是空的。
#
# 「第 N 條非註解行」：去掉行首行尾的 **ASCII** 空白（空格、tab、CR、VT、FF；`read` 已吃掉 LF；刻意不用
# [:space:]，它隨 locale 變、Swift 的不變）之後，空行與 `#` 開頭的行不算。全形空白（U+3000）與 NBSP 不是
# 空白——測試同時斷言查詢檔裡沒有這類字元，所以這條定義在腳本、測試、檔案三邊一致（含 CRLF：測試用
# `components(separatedBy: "\n")` 切行，CR 留在行尾由同一個 ASCII 集剝掉）。
#
# 用法：LTM_ANCHOR_KEY="$(~/bin/ltm memory --export-key)" scripts/measure-baseline.sh [k]
#   LTM_BIN（預設 ~/bin/ltm）、LTM_BASELINE_QUERIES（預設本腳本旁的 baseline-queries.txt——「本腳本旁」照 bash 找腳本
#   運算元的順序解：`$0` 含斜線取其目錄；裸名先看 cwd、再沿 PATH 取第一個可讀的檔案）——兩者明確給空字串是錯（66／69），
#   不是「用預設」（R14；k 同，R10）、k 1–1000（預設 5）。密鑰請用命令替換直接餵進環境，不要落地（.claude/rules/anchor-key-in-probes.md）。
builtin trap - DEBUG ERR RETURN EXIT
builtin set +x
LTM_MB_WHITELIST="HOME LC_ALL LANG TMPDIR LTM_BIN LTM_BASELINE_QUERIES CLAUDE_CONFIG_DIR LTM_ANCHOR_KEY LTM_ANCHOR_KEY_SERVICE LTM_BUILD_BATCH_CHUNKS LTM_BUILD_MEMORY_BUDGET_MB LTM_CORPUS_ROOT LTM_DERIVED_ROOT LTM_MEMORY_ROOT LTM_TEST_CLOCK_STEP_SECONDS"
case "${LTM_MB_CLEAN-}" in
    "$$")
        { IFS= read -t 10 -r -d '' kv && [ "$kv" = "LTM_MB_FD3=$$" ]; } 2>/dev/null <&3 || { echo "白名單沒有經 fd 3 到達（頭標記缺或值錯）" >&2; exit 70; }
        mb_end=0
        while IFS= read -t 10 -r -d '' kv <&3 2>/dev/null; do
            case "$kv" in
                LTM_MB_END=1) mb_end=1; break ;;
                *=*) mb_name="${kv%%=*}"
                     case " $LTM_MB_WHITELIST " in *" $mb_name "*) export "$kv" 2>/dev/null || { echo "fd 3 上的記錄無法 export" >&2; exit 70; } ;; *) echo "白名單外的名字經 fd 3 到達" >&2; exit 70 ;; esac ;;
                *) echo "fd 3 上的記錄不是 NAME=VALUE" >&2; exit 70 ;;
            esac
        done
        [ "$mb_end" = 1 ] || { echo "白名單沒有完整經 fd 3 到達（尾標記缺或讀取逾時）" >&2; exit 70; }
        exec 3<&-; unset LTM_MB_CLEAN kv mb_end mb_name ;;
    *) builtin exec -c /usr/bin/env "PATH=${PATH-}" ${HOME+"HOME=$HOME"} "LTM_MB_CLEAN=$$" /bin/bash -- "$0" "$@" 3< <(builtin printf '%s\0' "LTM_MB_FD3=$$"; for v in $LTM_MB_WHITELIST; do if [[ -n "${!v+set}" ]]; then builtin printf '%s=%s\0' "$v" "${!v}"; fi; done; builtin printf '%s\0' LTM_MB_END=1) || exit 70 ;;
esac
set -u
# 自己的目錄：仿 bash 找腳本運算元的順序——`$0` 含斜線就是那個目錄（尾端補 `/` 讓 `/x.sh` 解到根目錄——這一臂沒有測試，複本放不進
# `/`，R14；經 symlink 呼叫時是 symlink 所在的目錄，不解 symlink）；裸名時 bash 先看 cwd，再沿 PATH 逐一元素：先做 tilde 展開，
# 再取**第一個可讀的檔案**。實測（bash 3.2.57；R13／R14）：644 取用、000 跳過、同名目錄跳過、空檔取用；cwd 有一份 000 時 bash
# 直接 Permission denied 不退回 PATH（所以 cwd 那一臂不需要 `-r`）；tilde 展開對 `~/x` 與 `~+/x` 都做。空的 PATH 元素 bash 當 cwd，
# 這裡的 `${e:-.}` 也是——但 cwd 那一臂一定先命中，這條路徑上分辨不出來、無臂（R15）。這裡照同一順序自己走，但 tilde **只仿
# `~` 與 `~/`**（HOME 沒設時 bash 用 passwd 的家目錄，這裡不仿、一遇到就停）——`~+`、`~-`、`~user` 不仿，而且一遇到就**停止搜尋**、直接 66：R14 版只是跳過那個元素
# 繼續往後找，後面若另有一份同名腳本就量到它而 rc 0（R15）。R13 寫「這條退路實務上到不了」是第四句沒查過的全稱。R12 版用 `command -v`，
# 它**偏好可執行檔**：PATH 前面一份 644、後面一份 755 時 bash 跑前者、它回後者，量到別棵樹的查詢檔而 rc 0（R13）。前三版各錯在
# 一句沒查過的全稱：R10 `dirname`（缺席時 `cd ""` 回 0、退回 cwd）、R11 裸名一律 cwd、R12「`command -v` 就是 bash 的順序」。
# CDPATH 已被 re-exec 清掉（它會把解出的路徑印進命令替換、也會選到別棵樹，R12）。測試十一臂，指紋都必須是 bash 實際跑的那份
# 旁邊的查詢檔：經 PATH 的裸名、相對路徑、cwd 裡的裸名、cwd 與 PATH 各一份時取 cwd、644 排在 755 之前時取 644、000 排在 755
# 之前時跳過 000、PATH 元素寫成字面 `~/…`、PATH 元素只有 `~`、`~/…` 而 HOME 沒設 → 66、`~+/…` 後面另有一份 → 66、cwd 放一支假
# `hashlib.py` 指紋仍是真的。
d=
case "$0" in
    */*) d="${0%/*}/" ;;
    *) if [ -f "./$0" ]; then d=.; else
           p="${PATH-}"
           while :; do
               e="${p%%:*}"
               case "$e" in
                   '~'|'~/'*) if [ -n "${HOME-}" ]; then e="${HOME}${e#\~}"; else break; fi ;;
                   '~'*) break ;;
               esac
               if [ -f "${e:-.}/$0" ] && [ -r "${e:-.}/$0" ]; then d="${e:-.}"; break; fi
               case "$p" in *:*) p="${p#*:}" ;; *) break ;; esac
           done
       fi ;;
esac
{ [ -n "$d" ] && HERE=$(cd -- "$d" 2>/dev/null && pwd); } || HERE=/nonexistent
QF="${LTM_BASELINE_QUERIES-$HERE/baseline-queries.txt}"
LTM="${LTM_BIN-${HOME:-}/bin/ltm}"   # HOME 沒設也不能讓 set -u 隱式地以 1 離開（那會與「1 = 任一列 error」撞號，R8）
[ "$#" -le 1 ] || { echo "只接受一個引數 [k]（多給的引數不回顯）" >&2; exit 64; }
K="${1-5}"   # 明確給了空字串是錯，不是「用預設」（R10）
# k：只准數字（字面集合 `[!0123456789]` 是同檔的一致寫法——指紋檢查用它的理由是**含字母**的 range 隨 locale 排序而變；純數字
# range 在五個 locale 找不到反例，所以這裡是一致性、不是實測的必要，R14）；原始字串超過 20 個字元先擋（閘在剝零之前，把剝零
# 的展開成本綁在 20 個字元內——成本隨長度成長，數字不在紀錄裡就不寫，R14；20 個字元以內的前導零仍合法）；再剝前導零（一次展開；
# `007`、`01000` 都合法，正規化後印進 set 行——R10 版直接印 `k=007`，R11 版 `$((K))` 當八進位）；再擋位數（剝完零還有 5 位以上
# 不可能在 1–1000；不先擋，`[ -ge ]` 對超過 intmax 的字串會多印一行 `[:` 的 integer 診斷——查法
# `bash -c '[ 18446744073709551621 -ge 1 ]; echo $?'` → 2 加一行診斷（3.2 與 5.3 措辭不同），兩版都不 wrap；R12 寫成「靜默 wrap
# 成 5」，那是同一個 commit 已經刪掉的 `$((10#$K))` 才有的行為，R13）；再範圍檢查。順序由測試釘住（`01000` → k=1000；
# 21 個字元 → 64；`18446744073709551621` → 64 且 stderr 只有那一句）。
case "$K" in ''|*[!0123456789]*) echo "k 必須是 1–1000 的整數" >&2; exit 64 ;; esac
[ "${#K}" -le 20 ] || { echo "k 必須是 1–1000 的整數" >&2; exit 64; }
K="${K#"${K%%[!0]*}"}"; K="${K:-0}"
case "$K" in ?????*) echo "k 必須是 1–1000 的整數" >&2; exit 64 ;; esac
[ "$K" -ge 1 ] && [ "$K" -le 1000 ] || { echo "k 必須是 1–1000 的整數" >&2; exit 64; }
[ -f "$QF" ] && [ -r "$QF" ] || { echo "查詢檔不是可讀的一般檔案：$QF" >&2; exit 66; }
[ -f "$LTM" ] && [ -x "$LTM" ] || { echo "ltm 不是可執行的一般檔案：$LTM" >&2; exit 69; }
command -v python3 >/dev/null 2>&1 || { echo "需要 python3 計時與解析 --json" >&2; exit 70; }

# 查詢檔只開一次、用 builtin `read` 讀（不經 PATH 上的任何子行程、不落地）：`read -r -d ''` 讀到 NUL 回 0（bash 變數存不了它
# → 66）、讀到 EOF 回 1（正常，尾端換行原樣保留）、其他（訊號中斷）→ 66；重導失敗時 read 沒跑、變數維持 unset → 66——這個
# shell 是 re-exec 出來的，`QF_CONTENT` 不可能預先存在（不是 export 進來的、不是 readonly；R12／R13 為那兩種各加的 `unset` 與 70
# 在 re-exec 之後驅動不了，拆掉，R14）。指紋與逐列量測共用讀進來的這一份，中間換檔不會讓第一行的身分與列內容錯配。
# **沒有測試能驅動的**：換檔的 race、「讀不了」那一臂（只在 -r 檢查之後的 race 窗口可達）、以及短讀（I/O 錯誤中途停、rc 仍是 1、
# 內容不完整）——最後這個偵測不到，只有指紋會與完整集合不同、跨兩次量測比對得出來。R8 版用 `$(cat; printf x)` 加 tr／wc 的
# NUL 檢查：那條 `|| exit 66` 不可達（命令替換的離開碼是 printf 的），而三個 PATH 子行程各拿到整份查詢集、stderr 沒重導（R9）。
{ IFS= read -r -d '' QF_CONTENT < "$QF"; } 2>/dev/null; rc=$?
[ "${QF_CONTENT+set}" = set ] || { echo "查詢檔讀不了：$QF" >&2; exit 66; }
case "$rc" in 1) ;; 0) echo "查詢檔含 NUL：$QF" >&2; exit 66 ;; *) echo "查詢檔讀取中斷（read 回 $rc）：$QF" >&2; exit 66 ;; esac
# 查詢集指紋：對「第 N 條非註解行」的同一個定義（ASCII trim、跳過空行與 #）逐行 sha256，只印 12 個 hex。
# 內容經 process substitution 的管線給 fd 3（不上命令列、不進環境、不落地——herestring 在 bash 3.2 會寫 $TMPDIR
# 暫存檔，R9），留在 python 行程裡，不上 stdout；stderr 也丟掉——它是唯一整份讀進查詢集的行程，
# 檔頭那句「不進 stdout／stderr」的全稱曾漏了它（R7）。
SETID=$(python3 -I -S - 3< <(printf '%s' "$QF_CONTENT") 2>/dev/null <<'PY'
import hashlib, sys
ws = " \t\r\v\f"
h = hashlib.sha256()
# 只在 LF 切行（跟 bash 的 read 與測試的 components(separatedBy: "\n") 一樣）：text-mode 逐行迭代連
# 單獨的 CR 也會切，那會讓兩個不同的查詢集算出同一個指紋。newline="" 是為了讓 read() 不把 CRLF 翻譯掉。
with open("/dev/fd/3", encoding="utf-8", errors="surrogateescape", newline="") as f:
    data = f.read()
for raw in data.split("\n"):
    line = raw.strip(ws)
    if not line or line.startswith("#"):
        continue
    h.update(line.encode("utf-8", "surrogateescape")); h.update(b"\n")
print(h.hexdigest()[:12])
PY
) || SETID=""
# 指紋必須恰好 12 個小寫 hex：逐字元對字面集合比對，不用 [0-9a-f] 這種 range（bash 3.2 隨 locale 排序而變）。
fp_ok=1
case "$SETID" in ????????????) ;; *) fp_ok=0 ;; esac
i=0; while [ $fp_ok -eq 1 ] && [ $i -lt 12 ]; do
    case "${SETID:$i:1}" in [0123456789abcdef]) ;; *) fp_ok=0 ;; esac; i=$((i + 1))
done
[ $fp_ok -eq 1 ] || { echo "算不出查詢集指紋" >&2; exit 70; }
# k 也印在同一行：verdict 全是「前 k 名」的性質，兩份紀錄 k 不同就不能逐列對齊（R4）。
printf 'set sha256:%s k=%s\n' "$SETID" "$K"

# 一條查詢一個 python：起 ltm、用 monotonic 計時、解析 --json、只印一行「<ms> <verdict>」。
# 不印任何 snippet；judge 自己的 stdin 接 /dev/null（R7：它曾繼承查詢內容），python 端對 ltm 再設一次
# DEVNULL 是縱深、目前沒有測試分得出來（R8）；stderr 由外層整個丟掉。命中只看前 k 筆——「前 k 名」的語意由
# judge 自己截，不靠 ltm 自律（R7：多回傳的命中會安靜地改變 self 與 tool=<n>），連形狀檢查也只看
# 前 k 筆（R8：第 k+1 筆畸形不該讓整列量不到）。
RUN='
import json, os, subprocess, sys, time
ltm, k = sys.argv[1], sys.argv[2]
# argv 是 python 依 filesystem encoding 解碼過的：C locale 且沒有 UTF-8 mode 時非 ASCII 會變成 surrogate，而 snippet 由 json.loads
# 解成真 Unicode——逐字命中也對不上、判成 clean（R14，codex）。還原成原始 bytes、以 UTF-8 **strict** 解（bytes 本身不是合法 UTF-8
# 也是同一個失效方向，R15 → error(judge)），ltm 的 argv 也傳原始 bytes。-I 讓環境旗標進不來、macOS 的 fs encoding 恆為 UTF-8，
# 所以這兩行沒有任何平台的測試驅動得到；留著是正確性，不宣稱有測試。
raw = os.fsencode(sys.argv[3])
try:
    query = raw.decode("utf-8")
except UnicodeDecodeError:
    print("0 error(judge)"); sys.exit(0)
def norm(s):
    return " ".join(s.split()).casefold()
q = norm(query)
if not q:
    print("0 error(blank)"); sys.exit(0)
t0 = time.monotonic_ns()
try:
    p = subprocess.run([ltm, "query", "--all-projects", "--k", k, "--json", "--", raw],
                       stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, close_fds=True)
except OSError:
    print("0 error(exec)"); sys.exit(0)
ms = (time.monotonic_ns() - t0) // 1_000_000
rc = p.returncode
if rc != 0:
    print(f"{ms} error({rc})" if rc > 0 else f"{ms} error(sig{-rc})"); sys.exit(0)
try:
    hits = json.loads(p.stdout)
except Exception:
    print(f"{ms} error(json)"); sys.exit(0)
if not isinstance(hits, list):
    print(f"{ms} error(shape)"); sys.exit(0)
hits = hits[:int(k)]
if not all(isinstance(h, dict) and isinstance(h.get("snippet"), str) for h in hits):
    print(f"{ms} error(shape)"); sys.exit(0)
if not hits:
    print(f"{ms} empty tool=0"); sys.exit(0)
tool = sum(1 for h in hits if "⟨tool " in h["snippet"])
selfhit = any(q in norm(h["snippet"]) for h in hits)
print(f"{ms} " + ("self" if selfhit else "clean") + f" tool={tool}")
'
# judge 印出來的那一列在執行期也要合形狀（不只靠測試釘）：<ms> 全數字、verdict 在字母表內、
# error token 只能是數字、sig＋數字、或 ERROR_TOKENS 裡的字面（不是「像 token 的字元」——bash 3.2 的
# [a-z] 隨 locale 排序而變，字面比對不會；數字也用字面集合 `[!0123456789]`——同檔一致寫法，同步測試釘住程式碼行裡沒有任何
# `[X-Y]` 形式的 range，R13／R14）。不合就整列換成 error(judge)——寧可少一列量測，也不讓不明
# 字串上 stdout。多行的列不必另外擋：每個位元組都落在 ms（只准數字）或 rest（各臂完整限制到結尾）裡。
ERROR_TOKENS="blank exec json shape judge"
# valid_row 裡刻意不寫 error( 的字面（連這個變數的定義也拆開寫）：同步測試把程式碼裡每一個 error( 出現都當
# 輸出點候選、不是輸出述句形狀就紅（含行尾註解裡的字面——R6 曾在上一行留一條 error(timeout) 註解當接線的
# canary，R7 指出它無主、而且哪天 timeout 進了字母表就無聲失效；現在不剝註解也就沒有接線要驅動），
# 這裡是比對不是輸出。
E_OPEN="error"'('
valid_row() {
    local ms="${1%% *}" rest="${1#* }"
    case "$ms" in ''|*[!0123456789]*) return 1 ;; esac
    case "$rest" in
        'clean tool='*|'self tool='*) case "${rest#* tool=}" in ''|*[!0123456789]*) return 1 ;; esac ;;
        'empty tool=0') ;;
        "$E_OPEN"*")")
            local tok="${rest#"$E_OPEN"}"; tok="${tok%)}"
            case "$tok" in
                ''|0*|sig0*) return 1 ;;
                sig*) case "${tok#sig}" in ''|*[!0123456789]*) return 1 ;; esac ;;
                *[!0123456789]*) case " $ERROR_TOKENS " in *" $tok "*) ;; *) return 1 ;; esac ;;
            esac ;;
        *) return 1 ;;
    esac
    return 0
}
ws=$' \t\r\v\f'
n=0; bad=0
while IFS= read -r raw || [ -n "$raw" ]; do
    line="${raw#"${raw%%[!$ws]*}"}"
    line="${line%"${line##*[!$ws]}"}"
    case "$line" in ''|\#*) continue ;; esac
    n=$((n + 1))
    row=$(python3 -I -S -c "$RUN" "$LTM" "$K" "$line" </dev/null 2>/dev/null) || row=""
    valid_row "$row" || row="0 error(judge)"
    case "${row#* }" in "$E_OPEN"*) bad=$((bad + 1)) ;; esac
    printf '#%d %sms %s\n' "$n" "${row%% *}" "${row#* }"
done < <(printf '%s' "$QF_CONTENT")
[ "$n" -gt 0 ] || { echo "查詢檔沒有任何非註解行" >&2; exit 65; }
[ "$bad" -eq 0 ] || exit 1
