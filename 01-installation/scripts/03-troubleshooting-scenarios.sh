#!/usr/bin/env bash
# =====================================================================
# 第 1 章 / 問題排查情境模擬 (對應 README 1.9 節)
# 用法:bash 01-installation/scripts/03-troubleshooting-scenarios.sh
#
# 前提:本機 PostgreSQL 已啟動,且目前的作業系統使用者能用預設值連線
#       (Homebrew:安裝者本人即超級使用者;容器:以 postgres 使用者執行)。
# 只建立 ts_ 開頭的角色與資料庫,結尾全部清掉;可重複執行。
# 標示「示範」的情境需要一個壞掉的環境才能重現,腳本只印出診斷指令與
# 健康 / 故障時的輸出長相;其餘情境會真的執行並印出真實錯誤訊息。
# 標示「macOS」的檢查在沒有該指令的環境會自動略過。
# =====================================================================
set -uo pipefail
export PATH="/opt/homebrew/opt/postgresql@17/bin:$PATH"

section() { printf '\n── %s ──\n' "$1"; }
have()    { command -v "$1" >/dev/null 2>&1; }
# 執行一條預期會失敗的指令,把真實錯誤訊息印出來
expect_fail() {
    local out rc
    out=$("$@" 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then
        printf '  預期失敗 (exit=%s):\n    %s\n' "$rc" "$out"
    else
        printf '  ⚠️ 本來預期失敗卻成功了:\n    %s\n' "$out"
    fi
}
psqlq() { psql -X -q -At -d postgres "$@"; }

cleanup() {
    psqlq -c "DROP DATABASE IF EXISTS ts_missing_db;"  >/dev/null 2>&1 || true
    psqlq -c "DROP DATABASE IF EXISTS ts_latin1;"      >/dev/null 2>&1 || true
    psqlq -c "DROP ROLE IF EXISTS ts_app;"             >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

echo "════ 前置:確認基本連線 (排查順序第 0 步) ════"
if ! pg_isready >/dev/null 2>&1; then
    echo "❌ pg_isready 失敗:伺服器沒起來或連線參數不對。先處理情境 B 再回來。"
    exit 1
fi
pg_isready
printf '  連線身分:%s / 預設資料庫:%s\n' \
    "$(psqlq -c 'SELECT current_user;')" "$(psqlq -c 'SELECT current_database();')"

# =====================================================================
section "情境 A:psql: command not found (示範)"
# =====================================================================
cat <<'TXT'
  排查 1:PATH 裡到底有沒有 psql?
    $ which psql            # 健康:/opt/homebrew/opt/postgresql@17/bin/psql
                            # 故障:psql not found
  排查 2:套件真的裝了嗎?執行檔在哪?(macOS)
    $ brew --prefix postgresql@17   # /opt/homebrew/opt/postgresql@17
    $ ls "$(brew --prefix postgresql@17)/bin/psql"
  排查 3:為什麼裝了卻不在 PATH?
    postgresql@17 是 keg-only formula:Homebrew 刻意不把它連到 /opt/homebrew/bin,
    避免和其他版本衝突,所以要自己把 bin 加進 PATH。
  排查 4:PATH 順序 — 若同時有多個版本,前面的贏
    $ echo "$PATH" | tr ':' '\n' | grep -n postgres
TXT
printf '  目前環境:which psql → %s\n' "$(command -v psql || echo '(not found)')"
if have brew; then
    printf '  brew --prefix postgresql@17 → %s\n' "$(brew --prefix postgresql@17 2>/dev/null || echo '(未安裝)')"
else
    echo "  (brew 不存在,略過 macOS 檢查)"
fi
printf '  PATH 中的 postgres 相關項目:\n'
echo "$PATH" | tr ':' '\n' | grep -n -i postgres | sed 's/^/    /' || echo "    (無)"

# =====================================================================
section "情境 B:connection refused / No such file or directory (示範)"
# =====================================================================
cat <<'TXT'
  兩種訊息代表兩種路徑:
    "could not connect to server: No such file or directory
       Is the server running locally and accepting connections on that socket?"
       → 走 Unix socket (沒給 -h),socket 檔不存在 = 伺服器沒起來或 socket 目錄不同
    "connection to server at "localhost" (::1), port 5432 failed: Connection refused"
       → 走 TCP (給了 -h),該埠沒有人在聽 = 沒起來、埠不同、或 listen_addresses 沒含這個位址
  排查 1:伺服器行程在不在?
    $ pg_isready                       # 健康:localhost:5432 - accepting connections
                                       # 故障:localhost:5432 - no response
    $ brew services list | grep postgresql        # macOS:started / error / none
    $ pg_ctl -D "$PGDATA" status                  # 通用:pg_ctl: server is running (PID: …)
  排查 2:有人在聽 5432 嗎?
    $ lsof -nP -iTCP:5432 -sTCP:LISTEN            # macOS/Linux (需 lsof)
    $ ss -ltnp | grep 5432                        # Linux
  排查 3:沒起來 → 看日誌,啟動失敗一定有原因寫在裡面
    $ tail -50 /opt/homebrew/var/log/postgresql@17.log      # Homebrew
    $ docker logs <container>                                # Docker
    常見:資料目錄權限、埠被占 (情境 E)、上次沒乾淨關機留下 postmaster.pid、磁碟滿
  修正:brew services start postgresql@17 (或 pg_ctl start),再 pg_isready 驗證
TXT
echo "  目前環境:"
if have brew;  then brew services list 2>/dev/null | grep -i postgres | sed 's/^/    /' || echo "    (brew services 無 postgres)"; else echo "    (brew 不存在,略過)"; fi
if have lsof;  then lsof -nP -iTCP:5432 -sTCP:LISTEN 2>/dev/null | sed 's/^/    /' || echo "    (lsof:5432 無人監聽 — 可能只走 socket)"; else echo "    (lsof 不存在,略過)"; fi
if have ss;    then ss -ltn 2>/dev/null | grep 5432 | sed 's/^/    /' || echo "    (ss:5432 無 TCP 監聽)"; fi
printf '    unix_socket_directories = %s\n' "$(psqlq -c 'SHOW unix_socket_directories;')"
printf '    listen_addresses        = %s\n' "$(psqlq -c 'SHOW listen_addresses;')"
printf '    log_directory           = %s\n' "$(psqlq -c "SELECT current_setting('log_directory');")"

# =====================================================================
section "情境 C:FATAL: role / database does not exist (真實執行)"
# =====================================================================
echo "  psql 的預設值:-U 沒給 → 用作業系統使用者名;-d 沒給 → 用和 -U 相同的名字。"
echo "  C-1 用一個不存在的角色連線:"
expect_fail psql -X -U ts_nobody -d postgres -c "SELECT 1;"
echo "  C-2 用存在的角色,但沒給 -d,而同名資料庫不存在:"
psqlq -c "CREATE ROLE ts_app LOGIN;" >/dev/null
expect_fail psql -X -U ts_app -c "SELECT 1;"
echo "  排查:列出角色與資料庫,看看實際有什麼"
echo "    \\du 相當於:"
psqlq -c "SELECT rolname, rolsuper, rolcanlogin FROM pg_roles WHERE rolname NOT LIKE 'pg\_%' ORDER BY 1;" | sed 's/^/      /'
echo "    \\l 相當於:"
psqlq -c "SELECT datname FROM pg_database WHERE NOT datistemplate ORDER BY 1;" | sed 's/^/      /'
echo "  修正:明確指定 -d postgres (或建立同名資料庫);建立缺少的角色"
psql -X -U ts_app -d postgres -Atc "SELECT 'ts_app 連上 ' || current_database() || ' 成功';" | sed 's/^/    /'

# =====================================================================
section "情境 D:password / peer authentication failed (示範 + 真實查詢)"
# =====================================================================
cat <<'TXT'
  訊息長相:
    FATAL:  password authentication failed for user "app"
    FATAL:  Peer authentication failed for user "app"      (Linux 套件版常見)
    FATAL:  no pg_hba.conf entry for host "10.0.0.5", user "app", database "bookstore"
  排查 1:伺服器用哪個 pg_hba.conf?(以超級使用者)
    SHOW hba_file;
  排查 2:pg_hba.conf 是「由上往下第一條符合的規則決定」,看哪一行接住了你的連線
    SELECT line_number, type, database, user_name, address, auth_method FROM pg_hba_file_rules;
    - peer  :只認作業系統使用者名 = 資料庫角色名 (只適用本機 socket)
    - trust :不問密碼 (Homebrew 預設,只該用在本機開發)
    - scram-sha-256:問密碼
  排查 3:走 socket 還是 TCP?-h localhost 走 TCP,規則不同 (host 而非 local)
  修正:
    - 改 pg_hba.conf 後不用重啟:SELECT pg_reload_conf();
    - 密碼別寫在指令裡:~/.pgpass (host:port:db:user:password,chmod 600)
TXT
echo "  目前環境的 hba_file 與規則:"
printf '    hba_file = %s\n' "$(psqlq -c 'SHOW hba_file;')"
psqlq -F ' | ' -c "SELECT line_number, type, database, user_name, coalesce(address,''), auth_method FROM pg_hba_file_rules WHERE error IS NULL;" | sed 's/^/    /'

# =====================================================================
section "情境 E:port already in use / 第二個 cluster (示範)"
# =====================================================================
cat <<'TXT'
  日誌裡的訊息:
    LOG:  could not bind IPv4 address "127.0.0.1": Address already in use
    HINT: Is another postmaster already running on port 5432?
  典型原因:同時裝了兩個版本 (postgresql@16 與 @17)、Docker 容器也映射了 5432、
           或上一個 postgres 沒關乾淨。
  排查 1:誰占著 5432?
    $ lsof -nP -iTCP:5432 -sTCP:LISTEN     # 看 COMMAND / PID
    $ ss -ltnp | grep 5432                 # Linux
  排查 2:是不是連到「另一個」伺服器?版本對不上就是線索
    $ psql -d postgres -c "SHOW server_version; SHOW data_directory;"
  修正:停掉不要的那個 (brew services stop postgresql@16 / docker stop …),
        或讓其中一個改埠:postgresql.conf 的 port = 5433,連線時 -p 5433 或 export PGPORT=5433
TXT
echo "  目前環境:"
printf '    server_version = %s\n' "$(psqlq -c 'SHOW server_version;')"
printf '    port           = %s\n' "$(psqlq -c 'SHOW port;')"
printf '    data_directory = %s\n' "$(psqlq -c 'SHOW data_directory;')"

# =====================================================================
section "情境 F:中文亂碼 (真實執行)"
# =====================================================================
echo "  亂碼有三個可能出錯的層:資料庫編碼、client_encoding、終端機 locale。"
echo "  排查 1:資料庫本身是 UTF8 嗎?"
printf '    server_encoding = %s\n' "$(psqlq -c 'SHOW server_encoding;')"
echo "  排查 2:client_encoding 跟終端機一致嗎?(由 LANG/LC_ALL 或 PGCLIENTENCODING 決定)"
printf '    client_encoding = %s,LANG=%s,LC_ALL=%s\n' \
    "$(psqlq -c 'SHOW client_encoding;')" "${LANG:-}" "${LC_ALL:-}"
echo "  F-1 重現:client_encoding 設成 LATIN1 後,含中文的查詢連送都送不出去"
expect_fail psql -X -d postgres -c "SET client_encoding TO 'LATIN1'; SELECT '中文測試';"
echo "  F-2 重現:資料庫編碼是 LATIN1 時,中文有兩種下場"
psqlq -c "CREATE DATABASE ts_latin1 ENCODING 'LATIN1' LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0;" >/dev/null
psql -X -q -d ts_latin1 -c "CREATE TABLE t(s text);"
printf '    連到 ts_latin1 時 client_encoding 自動變成 = %s (跟著資料庫走,不做轉換)\n' \
    "$(psql -X -At -d ts_latin1 -c 'SHOW client_encoding;')"
echo "  F-2a 不轉換 → UTF8 位元組原封不動塞進 LATIN1 資料庫,讀出來就是亂碼:"
psql -X -q -d ts_latin1 -c "INSERT INTO t VALUES ('中文');"
psql -X -At -F ' | ' -d ts_latin1 -c "SET client_encoding TO 'UTF8'; SELECT s AS 讀回, octet_length(s) AS bytes, length(s) AS chars FROM t;" | sed 's/^/    /'
echo "    (2 個中文字變成 6 個字元 — 資料已經壞了,不是顯示問題)"
echo "  F-2b 明確告訴伺服器 client 是 UTF8 → 伺服器嘗試轉換,轉不了就報錯 (至少不會存壞資料):"
expect_fail env PGCLIENTENCODING=UTF8 psql -X -d ts_latin1 -c "INSERT INTO t VALUES ('中文');"
echo "  修正:資料庫一律用 ENCODING 'UTF8' (setup/01 已這樣寫);client 端 SET client_encoding TO 'UTF8'"
psql -X -d postgres -Atc "SET client_encoding TO 'UTF8'; SELECT '中文測試 OK ✅';" | sed 's/^/    /'

echo
echo "✅ 情境模擬完成 (ts_ 開頭的角色與資料庫已清除)"
