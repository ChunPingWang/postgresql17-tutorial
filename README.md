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
| [01](./01-installation/) | 環境安裝與啟動 | 安裝方式決策、Homebrew 安裝、`pg_ctl`、`pg_isready`、連線/認證/編碼排查 |
| [02](./02-pgadmin-intro/) | pgAdmin 介紹 | GUI vs psql 決策、連線伺服器、Query Tool、物件導覽、連線與交易狀態排查 |
| [03](./03-database-schema/) | 資料庫與 Schema | DB vs Schema vs RLS 決策、`CREATE DATABASE`、Schema 隔離、`search_path`、「找不到表」排查 |
| [04](./04-data-types/) | 資料型別 | 型別選擇決策、數值、字元、日期、布林、UUID、ARRAY、JSONB、浮點/時區/轉型排查 |
| [05](./05-tables-constraints/) | 資料表與約束 | 約束設計決策、PK / FK / UNIQUE / CHECK / NOT NULL / DEFAULT、FK 違反/CASCADE/NOT VALID 排查 |

### 第二部分:SQL 與查詢

| 章節 | 主題 | 重點 |
|------|------|------|
| [06](./06-crud-basic-sql/) | 基本 SQL (CRUD) | 寫入策略決策、`INSERT` / `SELECT` / `UPDATE` / `DELETE` / `RETURNING` / `UPSERT`、漏 WHERE/ON CONFLICT/鎖等待排查 |
| [07](./07-joins-subqueries/) | JOIN 與子查詢 | JOIN/子查詢選擇決策、INNER / LEFT / RIGHT / FULL / CROSS / LATERAL、列數膨脹/NOT IN NULL/相關子查詢效能排查 |
| [08](./08-aggregations-grouping/) | 聚合與群組 | 聚合方式決策、`GROUP BY` / `HAVING` / `FILTER` / `GROUPING SETS` / `ROLLUP` / `CUBE`、NULL/膨脹/work_mem 排查 |
| [09](./09-indexes/) | 索引 | B-Tree / Hash / GIN / GiST / BRIN、部分索引、表達式索引、建索引前的決策條件、排查情境模擬 |
| [10](./10-views/) | 視圖 | View vs MV 決策、View / Materialized View / `WITH CHECK OPTION` / 自動更新、依賴鎖定/過期 MV 排查 |

### 第三部分:進階功能

| 章節 | 主題 | 重點 |
|------|------|------|
| [11](./11-functions-procedures/) | 函數與 Stored Procedure | 邏輯放哪裡決策、PL/pgSQL、`FUNCTION` vs `PROCEDURE`、volatility、SECURITY DEFINER 排查 |
| [12](./12-triggers/) | 觸發器 (Trigger) | Trigger vs 其他機制決策、BEFORE / AFTER / INSTEAD OF、Row vs Statement、稽核、吞資料/遞迴/效能排查 |
| [13](./13-transactions-concurrency/) | 交易與並發控制 | 隔離等級/鎖策略決策、ACID、`SELECT ... FOR UPDATE`、鎖等待/Deadlock/Lost Update/SKIP LOCKED 排查 |
| [14](./14-cte-window-functions/) | CTE 與視窗函數 | CTE/視窗選擇決策、`WITH` / `WITH RECURSIVE` / `OVER` / `PARTITION BY`、遞迴環/Frame/優化屏障排查 |

### 第四部分:應用與維運

| 章節 | 主題 | 重點 |
|------|------|------|
| [15](./15-json-fulltext/) | JSON / 全文搜尋 | JSONB vs 正規化決策、JSONB 操作子、`tsvector` / `tsquery`、GIN 沒用到/config 不符/中文排查 |
| [16](./16-roles-permissions/) | 角色與權限 | 權限模型決策、`CREATE ROLE` / `GRANT` / `REVOKE` / Row Level Security、permission denied/RLS 失效排查 |
| [17](./17-backup-restore/) | 備份與還原 | RPO/RTO 與備份策略決策、`pg_dump` / `pg_dumpall` / `pg_restore` / PITR 概念、還原失敗排查 |
| [18](./18-performance-tuning/) | 效能調校 | 調校順序決策、`EXPLAIN` / `ANALYZE` / `VACUUM` / 統計資料 / 慢查詢 / OS 與容器調校、慢查詢/bloat/work_mem/連線數排查 |

---

## 目錄結構

```
postgresql17-tutorial/
├── README.md                 ← 本檔
├── setup/                    ← 共用初始化腳本
│   ├── 01-create-tutorial-db.sql
│   └── 02-sample-data.sql
├── 09-indexes/
│   ├── README.md             ← 教學文件 (每節 Why → How;含「設計前的決策條件」與「問題排查情境」)
│   ├── scripts/              ← 章節 SQL/Shell
│   │   ├── 01-create-indexes.sql
│   │   ├── 02-explain-analyze.sql
│   │   └── 03-troubleshooting-scenarios.sql  ← 可重現的故障情境 (每章都有一支)
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

## 每章的結構

每一章的 README 都照同一個順序寫:

1. **為什麼需要這個** — 沒有它會遇到什麼問題,再講語法 (每個小節都是先 Why 再 How)。
2. **設計前的決策條件與考量重點** (第 N.2 節) — 動手前要先確認的前提、「情況 → 選擇 → 理由」對照表、上線時的考量。
3. **主題內容** — 語法、範例、截圖。
4. **問題排查:情境模擬與排查順序** (最後一節) — 一套「先便宜後昂貴」的通用排查順序,加上 3~5 個**可以在本機實際重現**的故障情境;每個情境都有症狀 → 排查步驟與線索 → 根因 → 修正 → 驗證,對應 `scripts/*-troubleshooting-scenarios.sql` (或 `.sh`),文件裡引用的數字與執行計畫都是實際跑出來的。

## 學習建議

1. **依序學習**:章節有相依性,例如索引依賴前面已建立的資料表。
2. **動手執行**:每章 `scripts/` 內 SQL 都附編號,建議依序執行。
3. **善用 pgAdmin Query Tool**:可以分段選取執行、查看 `EXPLAIN` 圖表。
4. **遇到錯誤先讀錯誤訊息**:PostgreSQL 錯誤訊息相當完整,通常會指出問題。
5. **把排查情境當練習題**:先只看「症狀」,自己用該章的通用排查順序找根因,再對答案;情境腳本裡標註「預期的 ERROR」的失敗是情境的一部分,不是腳本壞掉。

完成所有章節後,您將具備設計、開發、維運中型 PostgreSQL 系統的能力。
