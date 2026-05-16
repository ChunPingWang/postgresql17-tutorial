# 第 17 章 備份與還原

> 目標:能用 `pg_dump` / `pg_restore` 執行完整備份與還原,了解不同備份格式的使用時機。

## 17.1 備份工具概覽

| 工具 | 範圍 | 格式 | 用途 |
|------|------|------|------|
| `pg_dump` | 單一資料庫 | SQL / custom / dir / tar | 主要備份工具 |
| `pg_dumpall` | 整個 cluster | SQL | 含 roles、tablespaces |
| `pg_restore` | 搭配 custom/dir/tar 格式 | — | 還原 pg_dump 備份 |
| `pg_basebackup` | 整個資料目錄 | 二進位 | 物理備份 / 複寫 |
| PITR | WAL archiving | — | 點時間還原 |

## 17.2 pg_dump — 邏輯備份

```bash
# 純 SQL 格式 (可直接 psql 還原)
pg_dump -d bookstore -f bookstore_backup.sql

# Custom 格式 (推薦:壓縮、可選擇性還原、支援 -j 平行)
pg_dump -d bookstore -F c -f bookstore.pgdump

# Directory 格式 (多 worker 平行備份大表)
pg_dump -d bookstore -F d -j 4 -f backup_dir/

# 只備份資料 (不含 schema)
pg_dump -d bookstore -a -F c -f bookstore_data.pgdump

# 只備份 schema (不含資料)
pg_dump -d bookstore -s -F c -f bookstore_schema.pgdump

# 只備份特定表
pg_dump -d bookstore -t shop.books -t shop.authors -F c -f books_only.pgdump

# 只備份特定 schema
pg_dump -d bookstore -n shop -F c -f shop_schema.pgdump
```

### 常用選項

| 選項 | 說明 |
|------|------|
| `-F c` | Custom 格式 (推薦) |
| `-F d` | Directory 格式 |
| `-F t` | tar 格式 |
| `-Z 5` | 壓縮等級 0-9 |
| `-j N` | 平行 dump worker |
| `--no-owner` | 不含 OWNER 資訊 |
| `--no-privileges` | 不含 GRANT 語句 |
| `-T table` | 排除某表 |

## 17.3 pg_restore — 還原

```bash
# 建立目標資料庫 (如果不存在)
createdb bookstore_restore

# 還原 (Custom 格式)
pg_restore -d bookstore_restore -F c bookstore.pgdump

# 還原 + verbose
pg_restore -d bookstore_restore -v bookstore.pgdump

# 只還原特定表
pg_restore -d bookstore_restore -t books bookstore.pgdump

# 平行還原 (Directory 格式必備)
pg_restore -d bookstore_restore -j 4 backup_dir/

# 先 DROP 再重建 (如果表已存在)
pg_restore -d bookstore_restore --clean --if-exists bookstore.pgdump

# 列出備份內容 (不還原)
pg_restore -l bookstore.pgdump
```

## 17.4 pg_dumpall — 備份整個 Cluster

```bash
# 包含所有 DB + roles + tablespaces
pg_dumpall -f cluster_backup.sql

# 只備份 roles (沒有 DB 資料)
pg_dumpall --roles-only -f roles.sql

# 還原整個 cluster
psql -f cluster_backup.sql postgres
```

## 17.5 psql 還原 SQL 格式

```bash
# 還原純 SQL 格式
psql -d bookstore_restore -f bookstore_backup.sql

# 遇到錯誤仍繼續
psql -d bookstore_restore -f bookstore_backup.sql -v ON_ERROR_STOP=0
```

## 17.6 pg_basebackup — 物理備份

```bash
# 整個 data directory 的二進位複製
pg_basebackup -h localhost -U rexwang \
    -D /tmp/pg_basebackup \
    -P -X stream -Z gzip

# 搭配 WAL archiving 實現 PITR (Point-In-Time Recovery)
```

## 17.7 PITR 概念

1. 啟用 WAL archiving (`archive_mode = on`, `archive_command`)
2. 定期 `pg_basebackup`
3. 還原時:還原 base backup + 套用 WAL 到目標時間點

設定於 `postgresql.conf`:
```ini
wal_level = replica
archive_mode = on
archive_command = 'cp %p /mnt/wal_archive/%f'
```

## 17.8 備份策略建議

| 類型 | 頻率 | 保留 | 工具 |
|------|------|------|------|
| Full 邏輯備份 | 每日 | 30 天 | pg_dump -F c |
| Cluster 備份 | 每週 | 12 週 | pg_dumpall |
| 物理基礎備份 | 每日 | 7 天 | pg_basebackup |
| WAL 歸檔 | 即時 | 7 天 | archive_command |

**3-2-1 原則**:3 份備份、2 種媒介、1 份異地。

## 17.9 驗證備份

```bash
# 建立測試環境還原驗證
pg_restore -l bookstore.pgdump | head -20     # 列出內容
createdb bookstore_verify
pg_restore -d bookstore_verify bookstore.pgdump
psql -d bookstore_verify -c "SELECT COUNT(*) FROM shop.books;"
dropdb bookstore_verify
```

## 章節腳本

- [`scripts/01-backup-commands.sh`](./scripts/01-backup-commands.sh)
- [`scripts/02-restore-verify.sh`](./scripts/02-restore-verify.sh)

---

下一章 ➡ [第 18 章:效能調校](../18-performance-tuning/)
