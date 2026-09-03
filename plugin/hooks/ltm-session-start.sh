#!/bin/bash
# SessionStart hook：一句提醒，任何 source（startup / resume / clear / compact）都印；不跑查詢。
cat > /dev/null   # 讀掉 stdin 的 JSON，避免寫端收到 SIGPIPE
echo "ltm：本機有 Claude Code 長期記憶。要回想過去對話請呼叫 ltm_query；輸入含「之前／上次／當初／earlier／last time」等線索時會自動附上回想（LTM_RECALL_MODE=cued|always|off）。"
exit 0
