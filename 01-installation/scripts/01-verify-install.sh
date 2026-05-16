#!/usr/bin/env bash
# =====================================================================
# 環境驗證腳本 - 確認 PostgreSQL 17 已正確安裝並可連線
# =====================================================================
set -euo pipefail

PG_BIN="/opt/homebrew/opt/postgresql@17/bin"
export PATH="${PG_BIN}:${PATH}"

echo "── 1. 檢查執行檔 ───────────────────────────"
for cmd in psql pg_isready pg_ctl postgres pg_dump createdb; do
    if command -v "$cmd" >/dev/null 2>&1; then
        printf "  ✅ %-12s → %s\n" "$cmd" "$(command -v "$cmd")"
    else
        printf "  ❌ %-12s NOT FOUND\n" "$cmd"
    fi
done

echo
echo "── 2. 版本資訊 ───────────────────────────"
psql --version

echo
echo "── 3. 服務狀態 ───────────────────────────"
if pg_isready -h localhost -p 5432; then
    echo "  ✅ PostgreSQL 已就緒"
else
    echo "  ❌ PostgreSQL 未啟動,執行 brew services start postgresql@17"
    exit 1
fi

echo
echo "── 4. 角色與資料庫清單 ──────────────────────"
psql -d postgres -c "\du"
psql -d postgres -c "\l"

echo
echo "── 5. 設定檔位置 ───────────────────────────"
psql -d postgres -tAc "SHOW config_file;"
psql -d postgres -tAc "SHOW hba_file;"
psql -d postgres -tAc "SHOW data_directory;"

echo
echo "✅ 驗證完成"
