#!/usr/bin/env bash
# =====================================================================
# 第 17 章 / 還原與驗證
# =====================================================================
set -euo pipefail
export PATH="/opt/homebrew/opt/postgresql@17/bin:$PATH"

# 以腳本所在位置推算,不依賴 repo 放在哪個目錄
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${SCRIPT_DIR}/../backup_files"
RESTORE_DB="bookstore_restore_test"

echo "── 1. 建立測試還原 DB ──────────────────────"
dropdb --if-exists "$RESTORE_DB"
createdb "$RESTORE_DB"

echo "── 2. 還原 Custom 格式備份 ──────────────────"
pg_restore -d "$RESTORE_DB" -v "${BACKUP_DIR}/bookstore.pgdump" 2>&1 | tail -20

echo "── 3. 驗證還原結果 ──────────────────────────"
psql -d "$RESTORE_DB" <<'SQL'
SET search_path TO shop, public;
SELECT 'categories' AS table, COUNT(*) FROM categories
UNION ALL SELECT 'authors',    COUNT(*) FROM authors
UNION ALL SELECT 'books',      COUNT(*) FROM books
UNION ALL SELECT 'customers',  COUNT(*) FROM customers
UNION ALL SELECT 'orders',     COUNT(*) FROM orders
UNION ALL SELECT 'order_items',COUNT(*) FROM order_items
UNION ALL SELECT 'employees',  COUNT(*) FROM employees;
SQL

echo "── 4. 清除測試 DB ──────────────────────────"
dropdb "$RESTORE_DB"
echo "✅ 備份還原驗證完成"
