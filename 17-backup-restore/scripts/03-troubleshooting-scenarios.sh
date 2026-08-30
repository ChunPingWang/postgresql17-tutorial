#!/usr/bin/env bash
# =====================================================================
# 第 17 章 / 問題排查情境模擬 (對應 README 17.11 節)
# 用法:bash 03-troubleshooting-scenarios.sh
#
# 前提:psql / pg_dump / pg_restore / pg_dumpall 在 PATH 上,且目前使用者
#      可以直接連線 (Homebrew 預設本機帳號,或容器內 -u postgres)。
#      需要 CREATEDB + CREATEROLE 權限 (超級使用者即可)。
#
# 每個情境都用自己的 ts_ 前綴資料庫 / 角色,dump 檔寫到 mktemp 目錄,
# 結束 (含中途失敗) 時全部清掉,不影響 bookstore。
# 注意:情境 A、B、D、E 會刻意出現 ERROR,那是情境的一部分。
# =====================================================================
set -uo pipefail
export PATH="/opt/homebrew/opt/postgresql@17/bin:$PATH"

PSQL="psql -X -q -v ON_ERROR_STOP=1"

drop_ts_objects() {
    for db in ts_src ts_fresh_a1 ts_fresh_a2 ts_fresh_a3 ts_live ts_scratch; do
        $PSQL -d postgres -c "DROP DATABASE IF EXISTS $db WITH (FORCE);" 2>/dev/null
    done
    $PSQL -d postgres -c "DROP ROLE IF EXISTS ts_owner; DROP ROLE IF EXISTS ts_reader;" 2>/dev/null
}
drop_ts_objects   # 上次若中斷,先清乾淨 (讓腳本可重複執行)

WORK="$(mktemp -d)"
cleanup() {
    echo
    echo "── 清理 ts_* 資料庫與角色 ──"
    drop_ts_objects
    rm -rf "$WORK"
    echo "✅ 清理完成"
}
trap cleanup EXIT

# ---------------------------------------------------------------------
# 共用來源:一個有「自訂 owner + GRANT + FK」的小資料庫
# ---------------------------------------------------------------------
$PSQL -d postgres <<'SQL'
CREATE ROLE ts_owner  NOLOGIN;
CREATE ROLE ts_reader NOLOGIN;
CREATE DATABASE ts_src OWNER ts_owner;
SQL
$PSQL -d ts_src <<'SQL'
CREATE TABLE ts_customers (id INT PRIMARY KEY, name TEXT NOT NULL);
CREATE TABLE ts_orders (
    id          INT PRIMARY KEY,
    customer_id INT NOT NULL REFERENCES ts_customers(id),
    total       NUMERIC(10,2) NOT NULL
);
INSERT INTO ts_customers SELECT g, 'customer-' || g FROM generate_series(1, 100) g;
INSERT INTO ts_orders    SELECT g, 1 + (g % 100), g * 10 FROM generate_series(1, 1000) g;
ALTER TABLE ts_customers OWNER TO ts_owner;
ALTER TABLE ts_orders    OWNER TO ts_owner;
GRANT SELECT ON ts_customers, ts_orders TO ts_reader;
SQL
pg_dump -d ts_src -F c -f "$WORK/ts_src.pgdump"
pg_dumpall --roles-only | grep -E '^(CREATE|ALTER) ROLE ts_' > "$WORK/ts_roles.sql"
echo "來源資料庫 ts_src 已建立並備份:$(du -h "$WORK/ts_src.pgdump" | cut -f1)"

# =====================================================================
echo
echo '════ 情境 A:還原到新機器,pg_restore 噴出一堆 role "…" does not exist ════'
# 症狀:把備份拿到新 cluster 還原,錯誤刷不停,但表好像有出來
# =====================================================================
# 模擬「新 cluster」:把來源 DB 和角色都砍掉,只剩 dump 檔
$PSQL -d postgres -c "DROP DATABASE ts_src WITH (FORCE);"
$PSQL -d postgres -c "DROP ROLE ts_owner; DROP ROLE ts_reader;"

echo '── A 重現:直接還原 (下面的 ERROR 是預期的) ──'
createdb ts_fresh_a1
pg_restore -d ts_fresh_a1 "$WORK/ts_src.pgdump" 2>&1 | sed 's/^/    /'
echo "    pg_restore exit code = ${PIPESTATUS[0]}"

echo '── A 排查步驟 1:資料到底有沒有進去? ──'
$PSQL -d ts_fresh_a1 -Atc "SELECT 'ts_orders rows = ' || count(*) FROM ts_orders;"
$PSQL -d ts_fresh_a1 -Atc "SELECT 'owner of ts_orders = ' || tableowner FROM pg_tables WHERE tablename = 'ts_orders';"

echo '── A 排查步驟 2:pg_restore -l 看 dump 裡到底引用了哪些角色 (最後一欄是 owner) ──'
pg_restore -l "$WORK/ts_src.pgdump" | grep -E 'TABLE |ACL ' | sed 's/^/    /'

echo '── A 修正 1:只要資料不要 owner/權限 → --no-owner --no-privileges ──'
createdb ts_fresh_a2
pg_restore -d ts_fresh_a2 --no-owner --no-privileges "$WORK/ts_src.pgdump"
echo "    exit code = $?"
$PSQL -d ts_fresh_a2 -Atc "SELECT 'ts_orders rows = ' || count(*) || ', owner = ' || (SELECT tableowner FROM pg_tables WHERE tablename='ts_orders') FROM ts_orders;"

echo '── A 修正 2:要保留 owner/權限 → 先還原角色 (pg_dumpall --roles-only) 再還原資料 ──'
$PSQL -d postgres -f "$WORK/ts_roles.sql"
createdb ts_fresh_a3
pg_restore -d ts_fresh_a3 "$WORK/ts_src.pgdump"
echo "    exit code = $?"
$PSQL -d ts_fresh_a3 -Atc "SELECT 'ts_orders rows = ' || count(*) || ', owner = ' || (SELECT tableowner FROM pg_tables WHERE tablename='ts_orders') FROM ts_orders;"

# =====================================================================
echo
echo '════ 情境 B:還原「成功」了,但表裡的資料還是舊的 ════'
# 症狀:把昨晚的備份還原回既有 DB,指令跑完了,count(*) 卻沒變
# =====================================================================
# 模擬:ts_fresh_a3 就是「既有 DB」,今天有人誤刪了 300 筆訂單
$PSQL -d ts_fresh_a3 -c "DELETE FROM ts_orders WHERE id > 700;"
$PSQL -d ts_fresh_a3 -Atc "SELECT '誤刪後 ts_orders rows = ' || count(*) FROM ts_orders;"

echo '── B 重現:直接把備份往既有 DB 還原 (下面的 ERROR 是預期的) ──'
pg_restore -d ts_fresh_a3 "$WORK/ts_src.pgdump" 2>&1 | sed 's/^/    /'
echo "    pg_restore exit code = ${PIPESTATUS[0]}"

echo '── B 排查步驟 1:對照 count(*) — 一筆都沒回來 ──'
$PSQL -d ts_fresh_a3 -Atc "SELECT '還原後 ts_orders rows = ' || count(*) FROM ts_orders;"
# 根因:表已存在 → CREATE TABLE 失敗;接著 COPY 撞到既有的主鍵 → 整段 COPY 失敗。
#       pg_restore 預設「錯誤略過、繼續往下」,最後只印一行 errors ignored,很容易被當成成功。

echo '── B 修正 1:--clean --if-exists 先 DROP 再重建 ──'
pg_restore -d ts_fresh_a3 --clean --if-exists "$WORK/ts_src.pgdump"
echo "    exit code = $?"
$PSQL -d ts_fresh_a3 -Atc "SELECT '修正後 ts_orders rows = ' || count(*) FROM ts_orders;"

echo '── B 修正 2:-1 (single transaction) 讓還原「全有或全無」,錯了就整個 rollback,不會半套 ──'
$PSQL -d ts_fresh_a3 -c "DELETE FROM ts_orders WHERE id > 700;"
pg_restore -d ts_fresh_a3 -1 "$WORK/ts_src.pgdump" 2>&1 | head -3 | sed 's/^/    /'
echo "    -1 但沒 --clean → exit code = ${PIPESTATUS[0]} (非 0,而且什麼都沒改)"
$PSQL -d ts_fresh_a3 -Atc "SELECT 'rows 仍是 ' || count(*) FROM ts_orders;"
pg_restore -d ts_fresh_a3 -1 --clean --if-exists "$WORK/ts_src.pgdump"
echo "    -1 --clean --if-exists → exit code = $?"
$PSQL -d ts_fresh_a3 -Atc "SELECT 'rows = ' || count(*) FROM ts_orders;"

# =====================================================================
echo
echo '════ 情境 C:pg_dump: aborting because of server version mismatch ════'
# 症狀:在新機器上跑備份腳本,pg_dump 直接拒絕執行
# 這個情境無法在只有一組 binary 的環境重現,這裡只示範「怎麼查」
# =====================================================================
echo '── C 排查步驟 1:client 與 server 的主版本各是多少? ──'
echo "    pg_dump --version      → $(pg_dump --version)"
echo "    SHOW server_version    → $($PSQL -d postgres -Atc 'SHOW server_version;')"
echo '── C 排查步驟 2:PATH 上的 pg_dump 是哪一個? (常見:系統自帶舊版蓋掉了新版) ──'
echo "    command -v pg_dump     → $(command -v pg_dump)"
# 規則:pg_dump 的版本必須 >= server 版本 (新 client 可以 dump 舊 server,反過來不行)。
#       修正:改 PATH 指向與 server 同版或更新的 bin,或用 /opt/homebrew/opt/postgresql@17/bin/pg_dump 全路徑。

# =====================================================================
echo
echo '════ 情境 D:只想把誤刪的幾筆資料從備份救回來,不能動到其他資料 ════'
# 症狀:生產 DB 有人刪了 3 筆訂單;直接 pg_restore -t 會撞主鍵或蓋掉今天的新資料
# =====================================================================
createdb ts_live
pg_restore -d ts_live --no-owner --no-privileges "$WORK/ts_src.pgdump"
$PSQL -d ts_live <<'SQL'
DELETE FROM ts_orders WHERE id IN (10, 20, 30);           -- 誤刪
INSERT INTO ts_orders VALUES (1001, 1, 999.00);           -- 備份之後新增的資料,不能丟
SQL
$PSQL -d ts_live -Atc "SELECT '目前 ts_live.ts_orders rows = ' || count(*) || ' (少了 3 筆,多了 1 筆新的)' FROM ts_orders;"

echo '── D 重現:pg_restore -t ts_orders --data-only 直接往生產 DB 灌 (下面的 ERROR 是預期的) ──'
pg_restore -d ts_live --data-only -t ts_orders "$WORK/ts_src.pgdump" 2>&1 | sed 's/^/    /'
$PSQL -d ts_live -Atc "SELECT '還是 ' || count(*) || ' 筆:整段 COPY 因主鍵衝突失敗,一筆都沒進來' FROM ts_orders;"
# 根因:pg_restore 的資料是整表 COPY,沒有「只補缺的」選項;--clean 又會連今天的新資料一起 DROP。

echo '── D 修正:還原到 scratch DB,再用 SQL 精準搬回 ──'
createdb ts_scratch
pg_restore -d ts_scratch --no-owner --no-privileges -t ts_orders "$WORK/ts_src.pgdump"
echo "    scratch 還原 exit code = $?"
# 只搬「生產缺少的」那幾筆:COPY 走 STDOUT/STDIN 接起來,不需要 dblink;
# 多個 -c 在同一個 session 執行,所以 TEMP TABLE 可以跨 -c 使用
psql -X -q -d ts_scratch -c "COPY (SELECT * FROM ts_orders WHERE id IN (10,20,30)) TO STDOUT" \
  | psql -X -q -d ts_live \
        -c "CREATE TEMP TABLE staging (LIKE ts_orders)" \
        -c "COPY staging FROM STDIN" \
        -c "INSERT INTO ts_orders SELECT * FROM staging ON CONFLICT (id) DO NOTHING"
$PSQL -d ts_live -Atc "SELECT '修正後 rows = ' || count(*) || ',id 1001 仍在 = ' || bool_or(id = 1001) FROM ts_orders;"

# =====================================================================
echo
echo '════ 情境 E:排程備份每天都「成功」,要用時發現檔案是 0 bytes ════'
# 症狀:cron 日誌每天印 backup done,真的要還原才發現檔案是空的
# =====================================================================
echo '── E 重現:典型的爛備份腳本 — 不檢查 exit code、stderr 丟掉 (ERROR 被吞掉是重點) ──'
(
    # 模擬 cron 環境:PATH 極簡、連到打錯字的 DB 名稱,錯誤全丟進 /dev/null
    pg_dump -d ts_livee -F c -f "$WORK/nightly.pgdump" 2>/dev/null
    echo "    backup done   ← 腳本這樣寫,永遠印 done"
)
if [ -f "$WORK/nightly.pgdump" ]; then
    echo "    實際檔案:$(stat -c %s "$WORK/nightly.pgdump" 2>/dev/null || stat -f %z "$WORK/nightly.pgdump") bytes"
else
    echo "    實際檔案:不存在"
fi

echo '── E 排查步驟 1:檔案大小 + pg_restore -l 當 smoke test (下面的 ERROR 是預期的) ──'
pg_restore -l "$WORK/nightly.pgdump" 2>&1 | sed 's/^/    /'
echo "    pg_restore -l exit code = ${PIPESTATUS[0]}"

echo '── E 排查步驟 2:重跑一次備份指令,這次看 stderr 與 exit code ──'
pg_dump -d ts_livee -F c -f "$WORK/nightly.pgdump" 2>&1 | sed 's/^/    /'
echo "    pg_dump exit code = ${PIPESTATUS[0]}"

echo '── E 修正:set -euo pipefail + 檢查 exit code + 立即用 pg_restore -l 驗證 ──'
(
    set -euo pipefail
    pg_dump -d ts_live -F c -f "$WORK/nightly.pgdump"
    pg_restore -l "$WORK/nightly.pgdump" >/dev/null       # 讀得出目錄才算備份成功
    size=$(stat -c %s "$WORK/nightly.pgdump" 2>/dev/null || stat -f %z "$WORK/nightly.pgdump")
    [ "$size" -gt 1024 ] || { echo "backup too small: $size bytes"; exit 1; }
    echo "    backup OK: $size bytes, $(pg_restore -l "$WORK/nightly.pgdump" | grep -c 'TABLE DATA') 張表有資料"
)
echo "    修正版 exit code = $?"

echo
echo '✅ 情境模擬完成'
