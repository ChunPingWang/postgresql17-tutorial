# 第 3 章 資料庫與 Schema 基礎

> 目標:理解 PostgreSQL 的 cluster / database / schema / object 階層,並學會建立、切換、刪除這些物件。

## 3.1 階層結構

```
PostgreSQL Cluster (一個執行中的 postgres 實例)
├── Database: postgres
├── Database: bookstore
│   ├── Schema: public        ← 預設 schema
│   ├── Schema: shop          ← 我們建立的
│   │   ├── Tables, Views, Functions, Sequences, Types, ...
│   └── Schema: information_schema (系統)
├── Database: template0 (範本)
└── Database: template1 (範本)
```

**關鍵概念**:
- 一個 **cluster** 在同一 port (5432) 上運行,共享一份設定檔與 WAL。
- 跨 database 的查詢需要透過 `dblink` 或 `postgres_fdw`,通常不建議。
- **Schema** 是同一資料庫內的「命名空間」,主要用途:
  - 隔離不同業務模組 (例如 `crm`, `billing`, `audit`)
  - 多租戶 (multi-tenant) 一租戶一 schema
  - 隔離權限

## 3.2 建立資料庫

```sql
-- 基本語法
CREATE DATABASE myapp;

-- 完整語法
CREATE DATABASE myapp
    WITH
        OWNER       = rexwang
        ENCODING    = 'UTF8'
        LC_COLLATE  = 'en_US.UTF-8'
        LC_CTYPE    = 'en_US.UTF-8'
        TEMPLATE    = template0
        CONNECTION LIMIT = 100;
```

**參數說明**:
| 參數 | 用途 |
|------|------|
| `OWNER` | 擁有者 (預設為當前使用者) |
| `ENCODING` | 字元編碼,**建議永遠用 UTF8** |
| `LC_COLLATE` | 排序規則 (影響 ORDER BY) |
| `LC_CTYPE` | 字元分類 (大小寫轉換) |
| `TEMPLATE` | 範本,要改 ENCODING 需指定 `template0` |
| `CONNECTION LIMIT` | 同時連線上限,`-1` 為不限 |

> 💡 一旦建立,**`LC_COLLATE` 與 `LC_CTYPE` 不可修改**,要改只能重建資料庫。

> ⚠️ **`CREATE DATABASE` 不能在交易內執行** (錯誤 25001:`cannot run inside a transaction block`)。在 pgAdmin Query Tool 中,若按 F5 一次執行**多條語句**,pgAdmin 會把整段包成隱式交易而觸發此錯誤——請**只選取 `CREATE DATABASE` 那一行**單獨執行,並確認執行鈕旁的 **Auto commit** 是開啟的。psql 則是逐條送出語句,整段腳本照貼即可。

## 3.3 列出與刪除資料庫

```sql
-- 列出 (psql 內)
\l

-- 列出 (用 SQL)
SELECT datname FROM pg_database WHERE datistemplate = false;

-- 刪除 (注意:不可逆!)
DROP DATABASE myapp;

-- 若有人正在連線會失敗,可加 FORCE (Postgres 13+)
DROP DATABASE myapp WITH (FORCE);
```

## 3.4 切換資料庫

在 psql 內:
```
\c bookstore
你現在是使用者 "rexwang" 連線至資料庫 "bookstore"
```

從命令列直接連:
```bash
psql -d bookstore
psql -h localhost -p 5432 -U rexwang -d bookstore
```

## 3.5 Schema (重點!)

Schema 是 PostgreSQL 與某些初學者熟悉的 MySQL 最大不同處之一。**MySQL 的 "database" 約等於 PostgreSQL 的 "schema"**。

### 建立 / 刪除 schema

```sql
-- 建立
CREATE SCHEMA marketing;
CREATE SCHEMA IF NOT EXISTS audit AUTHORIZATION rexwang;

-- 列出
\dn

-- 列出 (SQL)
SELECT schema_name FROM information_schema.schemata;

-- 刪除 (空 schema)
DROP SCHEMA marketing;

-- 刪除 (含內容!)
DROP SCHEMA marketing CASCADE;
```

### 預設 schema:`public`

新資料庫預設都有一個 `public` schema。**從 PG 15 開始**,`public` 不再允許所有人寫入,只有 owner 能建立物件。

### 在物件名稱前加 schema 前綴

```sql
-- 全名:database.schema.object  (database 通常省略)
SELECT * FROM shop.books;          -- 完整指定
SELECT * FROM books;               -- 短名 → 透過 search_path 解析
```

## 3.6 search_path (找物件的路徑)

`search_path` 決定:**未指定 schema 時,PostgreSQL 從哪些 schema 找物件**。也決定:**新物件預設建在哪個 schema**。

```sql
-- 看當前 session 的 search_path
SHOW search_path;
--   search_path   
-- -----------------
--  "$user", public

-- 修改 (僅當前 session)
SET search_path TO shop, public;

-- 修改 (使用者預設值,所有未來 session 套用)
ALTER ROLE rexwang SET search_path TO shop, public;

-- 修改 (資料庫預設值)
ALTER DATABASE bookstore SET search_path TO shop, public;
```

### `$user` 是什麼?

`$user` 是個變數,等於當前使用者名稱。預設 `search_path = "$user", public` 意思是:
- 先找與使用者同名的 schema (如 `rexwang`)
- 找不到再找 `public`

這在多使用者隔離時很方便。

### 隱含的 schema:`pg_temp` 與 `pg_catalog`

`SHOW search_path` 顯示的不是全貌。實際生效的搜尋順序前面還隱含了兩個 schema:

1. `pg_temp` — 當前 session 的暫時表 schema,**排在最前面**。同名暫時表會優先於一般表被找到
2. `pg_catalog` — 系統物件 (`pg_class`、`now()`、`lower()`...),所以系統表和內建函數不用前綴就找得到

```sql
-- 列出「實際生效」的完整搜尋清單 (true = 包含隱含 schema)
SELECT current_schemas(true);
--        current_schemas
-- -----------------------------
--  {pg_catalog,shop,public}
```

### `SET LOCAL`:只在交易內生效

`SET search_path` 的效果持續到 session 結束;改用 `SET LOCAL` 則只在**當前交易**內有效,交易結束 (COMMIT 或 ROLLBACK) 自動還原。適合在 migration 腳本中臨時切換,不怕忘記改回來:

```sql
BEGIN;
SET LOCAL search_path TO audit, public;
-- ... 這裡的短名都解析到 audit schema ...
COMMIT;
-- search_path 已自動恢復原值
```

### 安全性:`SECURITY DEFINER` 函數要固定 search_path

`SECURITY DEFINER` 函數以**定義者**的權限執行。若它依賴呼叫者的 search_path 解析短名,攻擊者可以在會被優先搜到的 schema 裡建同名表或函數,劫持執行流程。慣例是在函數上直接固定:

```sql
CREATE FUNCTION transfer_funds(...) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp   -- 固定,不受呼叫者影響
AS $$ ... $$;
```

一般程式碼若跑在權限敏感的環境,也建議一律寫 `schema.object` 全名,完全不經過 search_path。PG 15 起 `public` 不再開放所有人寫入 (見 3.5 節),正是為了收緊這類風險。

### 權限是另一回事

schema 出現在 search_path 裡不代表有權使用:對某 schema 沒有 `USAGE` 權限時,它會被**靜默跳過**,不會報錯。查不到表時除了檢查 search_path,也要確認權限:

```sql
SELECT has_schema_privilege('shop', 'USAGE');
```

## 3.7 實作練習

> 💡 本練習以 **psql** 為前提:`\c` 是 psql 專屬指令,**在 pgAdmin Query Tool 中無法使用**。若用 pgAdmin,請先單獨執行 `CREATE DATABASE practice;`(見 3.2 的注意事項),再到 Object Explorer 右鍵 **Databases → Refresh**,對 `practice` 右鍵開新的 **Query Tool** 執行後續語句。

```sql
-- 1) 建立一個練習資料庫
CREATE DATABASE practice;
\c practice

-- 2) 在裡面建立兩個 schema
CREATE SCHEMA app;
CREATE SCHEMA audit;

-- 3) 在不同 schema 各建一張同名表 (展示隔離)
CREATE TABLE app.users   (id SERIAL PRIMARY KEY, name TEXT);
CREATE TABLE audit.users (id SERIAL PRIMARY KEY, name TEXT, changed_at TIMESTAMPTZ DEFAULT NOW());

-- 4) 設定 search_path 後可省略前綴
SET search_path TO app, public;
INSERT INTO users (name) VALUES ('Alice');
SELECT * FROM users;                    -- 找 app.users

-- 5) 看 schema 內所有物件
SELECT schemaname, tablename
FROM pg_tables
WHERE schemaname IN ('app','audit');

-- 6) 收尾
\c postgres
DROP DATABASE practice;
```

## 3.8 系統 schema 與物件

PostgreSQL 內建幾個特殊 schema,不能刪除:

| Schema | 用途 |
|--------|------|
| `pg_catalog` | 所有系統表 (`pg_class`, `pg_attribute`...) — 一定在 search_path 開頭 |
| `information_schema` | SQL 標準的中繼資料視圖 |
| `pg_toast` | 大欄位 (TOAST) 儲存 |
| `pg_temp_*` | 暫時表 |

例如查詢「目前 cluster 上所有資料庫名稱與大小」:
```sql
SELECT datname,
       pg_size_pretty(pg_database_size(datname)) AS size
FROM pg_database
ORDER BY pg_database_size(datname) DESC;
```

## 章節腳本

- [`scripts/01-create-and-explore.sql`](./scripts/01-create-and-explore.sql) — 建立/瀏覽資料庫與 schema
- [`scripts/02-search-path-demo.sql`](./scripts/02-search-path-demo.sql) — search_path 行為示範

---

下一章 ➡ [第 4 章:資料型別](../04-data-types/)
