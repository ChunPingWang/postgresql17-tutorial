# PostgreSQL 完整教程 (繁體中文)

> 從零開始學會 PostgreSQL,涵蓋 SQL 基礎、進階功能 (Trigger / Stored Procedure / CTE / Window Function) 與維運實務 (備份、權限、效能調校)。

本教程在 macOS (Apple Silicon) 上以 **PostgreSQL 17** + **pgAdmin 4** 製作,所有 SQL 腳本皆可直接執行,並附有 pgAdmin 截圖協助理解。

---

## 環境

| 項目 | 版本 / 路徑 |
|------|------------|
| PostgreSQL | 17.10 (Homebrew) |
| 安裝路徑 | `/opt/homebrew/opt/postgresql@17` |
| 資料目錄 | `/opt/homebrew/var/postgresql@17` |
| 預設超級使用者 | `rexwang` (本機帳號) |
| 預設資料庫 | `postgres` |
| 連線埠 | `5432` |
| GUI 工具 | pgAdmin 4 (`/Applications/pgAdmin 4.app`) |

---

## 快速開始

```bash
# 1. 啟動服務 (如未啟動)
brew services start postgresql@17

# 2. 加入 PATH (建議寫入 ~/.zshrc)
export PATH="/opt/homebrew/opt/postgresql@17/bin:$PATH"

# 3. 建立教學用資料庫
psql -d postgres -f setup/01-create-tutorial-db.sql

# 4. 載入範例資料
psql -d bookstore -f setup/02-sample-data.sql

# 5. 進入互動式介面
psql -d bookstore
```

---

## 章節導覽

### 第一部分:入門基礎

| 章節 | 主題 | 重點 |
|------|------|------|
| [01](./01-installation/) | 環境安裝與啟動 | Homebrew 安裝、`pg_ctl`、`pg_isready`、設定 PATH |
| [02](./02-pgadmin-intro/) | pgAdmin 介紹 | 連線伺服器、Query Tool、物件導覽 |
| [03](./03-database-schema/) | 資料庫與 Schema | `CREATE DATABASE`、Schema 隔離、`search_path` |
| [04](./04-data-types/) | 資料型別 | 數值、字元、日期、布林、UUID、ARRAY、JSONB |
| [05](./05-tables-constraints/) | 資料表與約束 | PK / FK / UNIQUE / CHECK / NOT NULL / DEFAULT |

### 第二部分:SQL 與查詢

| 章節 | 主題 | 重點 |
|------|------|------|
| [06](./06-crud-basic-sql/) | 基本 SQL (CRUD) | `INSERT` / `SELECT` / `UPDATE` / `DELETE` / `RETURNING` / `UPSERT` |
| [07](./07-joins-subqueries/) | JOIN 與子查詢 | INNER / LEFT / RIGHT / FULL / CROSS / LATERAL、相關子查詢 |
| [08](./08-aggregations-grouping/) | 聚合與群組 | `GROUP BY` / `HAVING` / `FILTER` / `GROUPING SETS` / `ROLLUP` / `CUBE` |
| [09](./09-indexes/) | 索引 | B-Tree / Hash / GIN / GiST / BRIN、部分索引、表達式索引 |
| [10](./10-views/) | 視圖 | View / Materialized View / `WITH CHECK OPTION` / 自動更新 |

### 第三部分:進階功能

| 章節 | 主題 | 重點 |
|------|------|------|
| [11](./11-functions-procedures/) | 函數與 Stored Procedure | PL/pgSQL、`FUNCTION` vs `PROCEDURE`、變數、控制流程 |
| [12](./12-triggers/) | 觸發器 (Trigger) | BEFORE / AFTER / INSTEAD OF、Row vs Statement、稽核 |
| [13](./13-transactions-concurrency/) | 交易與並發控制 | ACID、隔離等級、`SELECT ... FOR UPDATE`、Deadlock |
| [14](./14-cte-window-functions/) | CTE 與視窗函數 | `WITH` / `WITH RECURSIVE` / `OVER` / `PARTITION BY` |

### 第四部分:應用與維運

| 章節 | 主題 | 重點 |
|------|------|------|
| [15](./15-json-fulltext/) | JSON / 全文搜尋 | JSONB 操作子、運算符、`tsvector` / `tsquery` |
| [16](./16-roles-permissions/) | 角色與權限 | `CREATE ROLE` / `GRANT` / `REVOKE` / Row Level Security |
| [17](./17-backup-restore/) | 備份與還原 | `pg_dump` / `pg_dumpall` / `pg_restore` / PITR 概念 |
| [18](./18-performance-tuning/) | 效能調校 | `EXPLAIN` / `ANALYZE` / `VACUUM` / 統計資料 / 慢查詢 |

---

## 目錄結構

```
postgresql-tutorial/
├── README.md                 ← 本檔
├── setup/                    ← 共用初始化腳本
│   ├── 01-create-tutorial-db.sql
│   └── 02-sample-data.sql
├── 01-installation/
│   ├── README.md             ← 教學文件
│   ├── scripts/              ← 章節 SQL/Shell
│   └── screenshots/          ← 截圖
... (其餘章節相同結構)
```

---

## 範例資料庫

教程使用一個小型「書店 (bookstore)」資料庫,涵蓋:

- `categories` 書籍分類
- `authors` 作者
- `books` 書籍 (含 JSONB metadata)
- `customers` 客戶
- `orders` 訂單
- `order_items` 訂單明細
- `employees` 員工 (自我參照展示主管階層)

ER 概念:
```
authors ───< books >─── categories
                 │
                 └──< order_items >── orders >── customers
employees (self-ref via manager_id)
```

---

## 學習建議

1. **依序學習**:章節有相依性,例如索引依賴前面已建立的資料表。
2. **動手執行**:每章 `scripts/` 內 SQL 都附編號,建議依序執行。
3. **善用 pgAdmin Query Tool**:可以分段選取執行、查看 `EXPLAIN` 圖表。
4. **遇到錯誤先讀錯誤訊息**:PostgreSQL 錯誤訊息相當完整,通常會指出問題。

完成所有章節後,您將具備設計、開發、維運中型 PostgreSQL 系統的能力。
