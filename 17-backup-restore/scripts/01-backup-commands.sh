#!/usr/bin/env bash
# =====================================================================
# 第 17 章 / 備份指令示範
# =====================================================================
set -euo pipefail
export PATH="/opt/homebrew/opt/postgresql@17/bin:$PATH"

BACKUP_DIR="${HOME}/workspace/postgresql-tutorial/17-backup-restore/backup_files"
mkdir -p "$BACKUP_DIR"

echo "── 1. Custom 格式備份 ──────────────────────"
pg_dump -d bookstore -F c -Z 5 -f "${BACKUP_DIR}/bookstore.pgdump"
ls -lh "${BACKUP_DIR}/bookstore.pgdump"

echo "── 2. 純 SQL 格式備份 ──────────────────────"
pg_dump -d bookstore -f "${BACKUP_DIR}/bookstore.sql"
wc -l "${BACKUP_DIR}/bookstore.sql"

echo "── 3. 只備份 schema (不含資料) ──────────────"
pg_dump -d bookstore -s -F c -f "${BACKUP_DIR}/bookstore_schema_only.pgdump"
ls -lh "${BACKUP_DIR}/bookstore_schema_only.pgdump"

echo "── 4. 只備份特定表 ──────────────────────────"
pg_dump -d bookstore -t shop.books -t shop.authors -F c \
    -f "${BACKUP_DIR}/books_authors.pgdump"
ls -lh "${BACKUP_DIR}/books_authors.pgdump"

echo "── 5. 列出備份內容 ──────────────────────────"
pg_restore -l "${BACKUP_DIR}/bookstore.pgdump" | head -30

echo "── 6. pg_dumpall (roles + 所有 DB) ──────────"
pg_dumpall -f "${BACKUP_DIR}/cluster_backup.sql"
ls -lh "${BACKUP_DIR}/cluster_backup.sql"

echo "✅ 所有備份完成,儲存於: ${BACKUP_DIR}"
ls -lh "${BACKUP_DIR}/"
