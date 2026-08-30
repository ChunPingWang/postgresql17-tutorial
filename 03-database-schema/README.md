# 第 3 章 資料庫與 Schema 基礎

> 目標:理解 PostgreSQL 的 cluster / database / schema / object 階層、**在動手切分之前先想清楚要用哪一層來隔離**,學會建立、切換、刪除這些物件,並在「表明明在卻找不到」這類問題出現時有系統地排查。
>
> 🧰 **前置準備**:本章範例使用 `bookstore` 資料庫 (`shop` schema 與範例資料)。尚未建立的話,先在 repo 根目錄執行 `psql -d postgres -f setup/01-create-tutorial-db.sql` 與 `psql -d bookstore -f setup/02-sample-data.sql`,詳見[第 1 章 1.8 節](../01-installation/README.md#18-建立教學用資料庫)。
>
> 📐 **本章讀法**:每一節都先講「為什麼會需要這個」,再講「怎麼做」。3.2 是動手前的決策清單,3.10 是四個可以實際重現的故障情境與排查順序 — 建議先讀 3.1~3.2 建立判斷框架,再看語法。

## 3.1 階層結構

**為什麼要先懂階層**:PostgreSQL 有三層可以「隔離東西」— cluster、database、schema — 而每一層的隔離強度、跨越成本、權限模型都不一樣。初學者最常見的錯誤是把 MySQL 的 `database` 觀念直接搬過來,一個模組開一個 database,結果發現兩個 database 之間**連 JOIN 都做不到**。先看清楚每一層是什麼,才知道該在哪一層切。

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
- 一個 **cluster** 在同一 port (5432) 上運行,共享一份設定檔與 WAL。cluster 內所有 database 共用 role (使用者)、共用記憶體 (`shared_buffers`)、一起備份 (`pg_dumpall`)、一起複寫。
- **Database** 是「連線的邊界」:一條連線只能在一個 database 內工作。跨 database 的查詢需要透過 `dblink` 或 `postgres_fdw`,慢、複雜、沒有交易保證,通常不建議。
- **Schema** 是同一資料庫內的「命名空間」— 隔離名稱與權限,但**不隔離連線**,跨 schema JOIN 就是普通 JOIN。主要用途:
  - 隔離不同業務模組 (例如 `crm`, `billing`, `audit`)
  - 多租戶 (multi-tenant) 一租戶一 schema
  - 隔離權限

## 3.2 設計前的決策條件與考量重點

**為什麼要先想再切**:database 與 schema 的劃分一旦上線就很難改 — 表搬到另一個 database 等於資料遷移,程式裡所有的名稱與連線字串都要跟著動。用五分鐘回答下面的問題,比半年後做遷移便宜得多。

### 先確認的前提

| 問題 | 為什麼重要 | 怎麼確認 |
|------|-----------|---------|
| **這些資料之間需要 JOIN 或交易嗎?** | 需要就**不能**拆成不同 database。跨 database 沒有 JOIN、沒有外鍵、沒有共同交易 | 列出主要查詢,看有沒有橫跨兩組表 |
| **需要隔離的是「名稱」、「權限」還是「連線/資源」?** | 名稱與權限用 schema 就夠;要限制連線數、獨立備份還原、獨立 collation 才需要 database | 問「誰不能看到誰」與「哪些東西要各自備份」 |
| **誰會用短名 (不帶 schema 前綴) 存取?** | 短名靠 `search_path` 解析,多 schema 同名表時會有找錯、刪錯的風險 (3.10 情境 C) | 盤點 ORM / 應用程式是否寫全名 |
| **編碼與排序規則要一樣嗎?** | `ENCODING`、`LC_COLLATE`、`LC_CTYPE` 是 database 層級,**建立後不可改**;需要不同排序規則只能分 database | 確認各模組的語言需求 |
| **未來會有多少「租戶」或「模組」?** | 幾個 schema 沒問題;幾千個 schema 會讓 catalog 膨脹、備份與 migration 變慢 | 估三年後的數量 |
| **連線的人是應用程式還是真人?** | 應用程式用固定帳號 + 業務 schema;多個真人直連時 `$user` 私有 schema 模式很好用 (3.6) | 看連線來源 |

### 決策對照:什麼情況選什麼

| 情況 | 選擇 | 理由 |
|------|------|------|
| 同一個應用的多個模組 (訂單、稽核、報表) | **同一個 database,多個 schema** | 可以 JOIN、可以外鍵、一個交易涵蓋全部;權限以 schema 為單位授與 |
| 完全獨立的系統,資料從不交會 | **不同 database** | 各自備份還原、各自 `CONNECTION LIMIT`、互不影響 |
| SaaS 多租戶,每個客戶資料隔離、結構相同 | **一租戶一 schema** + 連線後 `SET search_path` | 同一套 SQL 服務所有租戶;隔離靠 schema 權限 |
| 租戶數量非常多 (萬級) 或租戶間結構會分歧 | 改用 `tenant_id` 欄位 + Row Level Security (第 16 章) | schema 數量爆炸會拖垮 catalog 與 migration |
| 需要不同的 collation / 編碼 | **不同 database** | 這些屬性是 database 層級且不可變更 |
| migration 要做「新舊結構平行、可秒回滾」 | 新結構放新 schema (`v2`),切換只改 `search_path` 或 rename | 失敗時 DROP SCHEMA 即可,資料不用搬 |
| 多個真人各自實驗、互不干擾 | 每人一個與使用者同名的 schema (`$user` 模式) | 零設定:預設 `search_path` 就會落到自己的 schema |

### 上線與實務考量

- **`public` 不是你的 schema**:PG 15 起 `public` 預設只有 owner 能建物件;應用程式的表一律放自己的 schema,`public` 留給 extension。
- **決定 search_path 的設定層級**:寫在 `ALTER DATABASE ... SET` (所有連線一致) 或 `ALTER ROLE ... SET` (依角色不同);不要依賴每條連線各自 `SET`,忘了設就會出現 3.10 情境 A/B。
- **程式碼寫全名還是短名**:短名方便、可搬移 (換租戶只改 search_path);全名安全 (不受 search_path 影響)。安全敏感的地方 (`SECURITY DEFINER` 函數、migration 腳本) 一律全名 (3.6)。
- **`CREATE DATABASE` / `DROP DATABASE` 不能在交易內**,且 DROP 需要沒人連著 — 自動化腳本要考慮這兩點 (3.10 情境 D)。
- **權限與 search_path 是兩件事**:schema 在 search_path 裡但沒 `USAGE`,會被靜默跳過,錯誤訊息長得跟「表不存在」一模一樣 (3.10 情境 A-2)。

## 3.3 建立資料庫

**為什麼要在意這些參數**:`ENCODING`、`LC_COLLATE`、`LC_CTYPE` 一旦建立就**不能改**,要改只能建新 database 再搬資料。用預設值建了一個 `SQL_ASCII` 或 `C` collation 的資料庫,等到上線後發現中文排序不對、`LOWER()` 不處理非 ASCII 字元,代價就是一次完整遷移。所以建 database 時把這幾個參數**明確寫出來**。

```sql
-- 基本語法 (參數全部繼承 template1)
CREATE DATABASE myapp;

-- 完整語法 (建議:明確指定,不要靠預設)
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

> ⚠️ **`CREATE DATABASE` 不能在交易內執行** (錯誤 25001:`cannot run inside a transaction block`)。在 pgAdmin Query Tool 中,若按 F5 一次執行**多條語句**,pgAdmin 會把整段包成隱式交易而觸發此錯誤——請**只選取 `CREATE DATABASE` 那一行**單獨執行,並確認執行鈕旁的 **Auto commit** 是開啟的。psql 則是逐條送出語句,整段腳本照貼即可。(3.10 情境 D-2 可重現)

## 3.4 列出與刪除資料庫

**為什麼 DROP 會失敗**:`DROP DATABASE` 要求**沒有任何連線**掛在目標資料庫上 — 它要刪掉整個目錄,不能有人正在讀寫。最常見的「隱形連線」是 pgAdmin 的 Object Explorer (展開過就連著)、應用程式的連線池、另一個忘了關的 psql。

```sql
-- 列出 (psql 內)
\l

-- 列出 (用 SQL)
SELECT datname FROM pg_database WHERE datistemplate = false;

-- 刪除 (注意:不可逆!)
DROP DATABASE myapp;

-- 若有人正在連線會失敗,可加 FORCE (Postgres 13+):強制踢掉所有連線再刪
DROP DATABASE myapp WITH (FORCE);
```

想先知道是誰連著 (再決定要不要 FORCE),查 `pg_stat_activity` — 3.10 情境 D 有完整流程。

## 3.5 切換資料庫

**為什麼要「切換」而不是「跨」**:一條連線只屬於一個 database (3.1)。要操作另一個 database,不是換 schema、也不是寫全名,而是**重新建立連線**。psql 的 `\c` 做的就是斷線再連。

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

> `\c` 是 psql 指令,不是 SQL;pgAdmin 裡要換 database 是對目標資料庫另開一個 Query Tool。

## 3.6 Schema (重點!)

**為什麼 PostgreSQL 多了這一層**:MySQL 的 "database" 約等於 PostgreSQL 的 "schema" — 它們都是「名稱的分組」,可以互相 JOIN。PostgreSQL 把「連線邊界」(database) 和「名稱分組」(schema) 拆開,好處是:同一條連線、同一個交易,可以同時操作 `shop.orders` 與 `audit.orders` — 這在 MySQL 需要跨 database,在 PostgreSQL 只是兩張表。

### 四大使用場景

| 場景 | 做法 | 好處 |
|------|------|------|
| **模組化命名空間** (最常見) | 依業務領域分組:`shop`、`audit`、`reporting` (本教程 bookstore 用的就是 `shop`) | 同名不衝突 (`app.users` 與 `audit.users` 並存,見 3.8 練習);schema 之間 JOIN 就是普通 JOIN——若拆成多個 database 就得靠 FDW,這是 schema 的關鍵優勢 |
| **權限邊界** | `GRANT USAGE ON SCHEMA reporting TO analyst;` 整個 schema 一次授權 | 分析師只看得到 `reporting`,碰不到 `shop` 原始表;PG 15 收緊 `public` 就是推這個模式 |
| **多租戶 (multi-tenancy)** | 每個客戶一個 schema (`tenant_a.orders`、`tenant_b.orders`),連線後 `SET search_path TO tenant_a` | 表結構相同、資料隔離,同一套 SQL 服務不同租戶——search_path 短名解析最典型的生產應用 |
| **版本 / 環境隔離** | migration 時建 `v2` schema 平行準備新結構 | 切換只改 search_path 或 rename schema,失敗可秒回滾 |

### 建立 / 刪除 schema

**為什麼要分 `DROP SCHEMA` 與 `CASCADE`**:預設的 `DROP SCHEMA` 只刪空的 schema,是一道保險 — 避免一行指令帶走整個模組的所有表。`CASCADE` 會把裡面所有物件一起刪,而且**其他 schema 依賴這些物件的東西 (view、外鍵) 也會一起消失**。用之前先 `\dn+` 或查 `pg_tables` 看裡面有什麼。

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

新資料庫預設都有一個 `public` schema。**從 PG 15 開始**,`public` 不再允許所有人寫入,只有 owner 能建立物件 — 原因是以前任何人都能在 `public` 建同名函數或表,搭配 search_path 就能劫持別人的查詢 (見 3.7 安全性一節)。應用程式的表請放自己的 schema。

### 在物件名稱前加 schema 前綴

**為什麼有兩種寫法**:全名 (`shop.books`) 不依賴任何設定,永遠指向同一張表;短名 (`books`) 靠 `search_path` 解析,方便、可搬移 (多租戶換 schema 只要改 search_path),但也是本章所有排查情境的來源。

```sql
-- 全名:database.schema.object  (database 通常省略)
SELECT * FROM shop.books;          -- 完整指定
SELECT * FROM books;               -- 短名 → 透過 search_path 解析
```

## 3.7 search_path (找物件的路徑)

**為什麼它這麼重要**:只要你寫過一次不帶 schema 前綴的名稱 — 表、函數、型別、甚至運算子 — PostgreSQL 就是靠 `search_path` 決定你指的是哪一個。它決定兩件事:**未指定 schema 時從哪些 schema 找物件**、**新物件預設建在哪個 schema**。「表明明在卻找不到」、「表建到別的地方去了」、「查到另一張同名表」,根源全都在這裡 (3.10 情境 A、B、C)。

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

### 查詢已設定的 search_path

**為什麼要會查**:search_path 可以設在三個層級 (session / role / database),排查時第一個問題永遠是「現在生效的值是哪裡來的」。DATABASE / ROLE 層級的持久設定存在系統表 **`pg_db_role_setting`**:

```sql
SELECT COALESCE(d.datname, '(所有資料庫)') AS database,
       COALESCE(r.rolname, '(所有角色)')   AS role,
       s.setconfig
FROM pg_db_role_setting s
LEFT JOIN pg_database d ON d.oid = s.setdatabase
LEFT JOIN pg_roles    r ON r.oid = s.setrole;
-- setconfig 會顯示如 {search_path=shop, public}
```

**查詢中 `COALESCE` 的作用**:`COALESCE(a, b)` 回傳第一個非 NULL 的參數(詳見[第 6 章 6.8 節](../06-crud-basic-sql/))。`pg_db_role_setting` 用 `0` 表示「不限定」——例如 `ALTER ROLE ... SET` 不限資料庫,其 `setdatabase = 0`,LEFT JOIN 配不到任何 `pg_database` 列而補 NULL。COALESCE 把這些 NULL 換成 `(所有資料庫)` / `(所有角色)` 標籤,讓「配不到」和「適用於全部」在結果中可以區分。

> 💡 **查詢結果為空是正常的**:這張表只存 `ALTER DATABASE/ROLE ... SET` 寫入的持久設定,沒設定過就是空的。想看到資料,先執行 `ALTER DATABASE bookstore SET search_path TO shop, public;` 再查一次(看完記得 `RESET` 還原)。可與下方 `pg_settings` 查詢交叉驗證:表為空時 `source` 應顯示 `default` 或 `session`,而不會是 `database` / `user`。另外,示範腳本 `03-search-path-query.sql` 結尾會 RESET 清理,跑完後此表同樣是空的——刻意設計,不留副作用。

psql 裡一行看完:`\drds`

想知道「當前生效的值是從哪一層來的」:

```sql
SELECT name, setting, source
FROM pg_settings
WHERE name = 'search_path';
-- source: default / database / user / session
```

排查「為什麼我的表建到別的 schema」時最好用。還原設定:

```sql
ALTER DATABASE bookstore RESET search_path;
ALTER ROLE rexwang RESET search_path;
```

### RESET 之後會發生什麼?

`RESET` 只是**把 `pg_db_role_setting` 裡那筆持久設定刪掉**,讓下一個層級的預設值浮上來。取值優先序:session 的 `SET` > `ALTER ROLE IN DATABASE` > `ALTER ROLE` > `ALTER DATABASE` > `postgresql.conf` > 內建預設 `"$user", public`。兩層都 RESET 後,新 session 就回到 `"$user", public`——短名 `books` 查不到了,要寫 `shop.books`;新表也改建在 `public`。

三個常見誤解:

- **schema 和資料原封不動**:RESET 只改名稱解析的預設路徑,`shop.books` 還在,寫全名照常運作
- **建錯位置的表不會搬回去**:search_path 是 `shop, public` 期間建的表已實體落在 `shop`,要搬得用 `ALTER TABLE shop.t1 SET SCHEMA public;`
- **當前 session 不會立即變**:DATABASE/ROLE 層設定只在**連線建立時**讀取,RESET 後同一 session 的 `SHOW search_path` 不變,要重連才看得到效果 (與 `ALTER ... SET` 的生效時機是同一規則)

### `$user` 是什麼?場景與目的

`$user` 是個變數,解析時展開成當前使用者名稱。預設 `search_path = "$user", public` 意思是:
- 先找與使用者同名的 schema (如 `rexwang`)
- 找不到再找 `public`

這是為了支援 SQL 標準的老模式:**每個使用者一個私有工作區** (per-user schema)。DBA 只要做一件事:

```sql
CREATE SCHEMA alice AUTHORIZATION alice;
CREATE SCHEMA bob   AUTHORIZATION bob;
```

之後 alice 連進來,`CREATE TABLE experiment (...)` 自動落在 `alice` schema,她的短名查詢也解析到自己的表——**零設定、零前綴,每人一個互不干擾的沙盒**,bob 建同名表完全不衝突。目的有三層:

1. **隔離**:多人共用資料庫時,各自的實驗物件不互相污染、不弄髒 `public`
2. **免設定**:不需要每人各自 `SET search_path`,預設值天生指向自己的 schema
3. **共享仍可行**:路徑第二順位是 `public`——私有的優先、共享的兜底

典型場景:教學環境 (一班學生共用一個 DB)、分析團隊的 scratch 區、多人直連的開發資料庫。

**為什麼多數人無感**:同名 schema 預設不存在,`$user` 展開後找不到就被靜默跳過,實際落到 `public`。這個模式是**選擇加入**的——DBA 建了同名 schema 就自動生效。反過來也有個反直覺行為:哪天有人替你建了同名 schema,你的新表落點會**默默改變**,可用 `SELECT current_schema();` 隨時確認 (3.10 情境 B-2 可重現)。

**現代實務定位**:應用程式後端通常不用此模式 (app 用固定服務帳號連線,傾向 `shop`、`audit` 這類業務 schema);`$user` 模式主要活在「多個真人直連資料庫」的場景。本教程 bookstore 用 `shop`,走的就是應用程式路線。

### search_path 影響哪些功能?

search_path 是 PostgreSQL 所有「**不帶 schema 前綴名稱**」的統一解析規則,範圍比多數人以為的廣:

| 功能 | 說明 |
|------|------|
| **資料表 / view / sequence 查詢** | `SELECT`、`INSERT`、`UPDATE`、`DELETE` 中的短名解析 |
| **建立新物件** | `CREATE TABLE` 等未指定 schema 時,建在第一個實際存在的 schema |
| **函數呼叫** | `SELECT my_func(1)` 依 search_path 找函數;內建函數能直接用是因為隱含的 `pg_catalog` 排最前 |
| **運算子** | 連 `=`、`+`、`\|\|` 都是依 search_path 解析的物件,可被自訂 schema 的同名運算子遮蔽 |
| **資料型別** | `CREATE TABLE t (col my_enum)` 的型別名、`'abc'::my_type` 的轉型 |
| **DROP / ALTER 等 DDL** | `DROP TABLE products` 刪的是 search_path 找到的**第一個** `products`——多 schema 同名表時有刪錯的風險 (3.10 情境 C-2) |
| **名稱顯示** | 反向也適用:`::regclass`、`\d`、錯誤訊息中,物件可見時顯示短名 (`books`),不可見才顯示全名 (`shop.books`) |

一句話總結:讀、寫、建、刪、函數、運算子、型別全部適用——`CREATE TABLE` 的落點只是其中「建」的那個面向。

### 隱含的 schema:`pg_temp` 與 `pg_catalog`

**為什麼 `SHOW search_path` 不夠**:它顯示的只是你設定的值,實際生效的搜尋順序前面還隱含了兩個 schema:

1. `pg_temp` — 當前 session 的暫時表 schema,**排在最前面**。同名暫時表會優先於一般表被找到 — 而且 `SHOW search_path` 完全看不出來 (3.10 情境 C-2)
2. `pg_catalog` — 系統物件 (`pg_class`、`now()`、`lower()`...),所以系統表和內建函數不用前綴就找得到

```sql
-- 列出「實際生效」的完整搜尋清單 (true = 包含隱含 schema)
SELECT current_schemas(true);
--        current_schemas
-- -----------------------------
--  {pg_catalog,shop,public}
```

排查名稱解析問題時,**用 `current_schemas(true)` 而不是 `SHOW search_path`** — 前者才是 PostgreSQL 真正走的順序,也會反映「被跳過的 schema」(不存在、或沒權限)。

### `SET LOCAL`:只在交易內生效

**為什麼需要**:`SET search_path` 的效果持續到 session 結束;連線池環境下,這條連線會被下一個請求重用,忘了改回來就會讓別人的查詢跑到錯的 schema。`SET LOCAL` 只在**當前交易**內有效,交易結束 (COMMIT 或 ROLLBACK) 自動還原。適合在 migration 腳本中臨時切換,不怕忘記改回來:

```sql
BEGIN;
SET LOCAL search_path TO audit, public;
-- ... 這裡的短名都解析到 audit schema ...
COMMIT;
-- search_path 已自動恢復原值
```

### 安全性:`SECURITY DEFINER` 函數要固定 search_path

**為什麼是安全問題**:`SECURITY DEFINER` 函數以**定義者**的權限執行。若它依賴呼叫者的 search_path 解析短名,攻擊者可以在會被優先搜到的 schema 裡建同名表或函數,劫持執行流程 — 用你的權限跑他的程式碼。慣例是在函數上直接固定:

```sql
CREATE FUNCTION transfer_funds(...) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp   -- 固定,不受呼叫者影響
AS $$ ... $$;
```

一般程式碼若跑在權限敏感的環境,也建議一律寫 `schema.object` 全名,完全不經過 search_path。PG 15 起 `public` 不再開放所有人寫入 (見 3.6 節),正是為了收緊這類風險。

### 權限是另一回事

**為什麼會被誤判**:schema 出現在 search_path 裡不代表有權使用:對某 schema 沒有 `USAGE` 權限時,它會被**靜默跳過**,不會報錯 — 你看到的錯誤訊息是 `relation "books" does not exist`,跟 search_path 設錯時一模一樣。查不到表時除了檢查 search_path,也要確認權限 (3.10 情境 A-2):

```sql
SELECT has_schema_privilege('shop', 'USAGE');
```

## 3.8 實作練習

> 💡 本練習以 **psql** 為前提:`\c` 是 psql 專屬指令,**在 pgAdmin Query Tool 中無法使用**。若用 pgAdmin,請先單獨執行 `CREATE DATABASE practice;`(見 3.3 的注意事項),再到 Object Explorer 右鍵 **Databases → Refresh**,對 `practice` 右鍵開新的 **Query Tool** 執行後續語句。

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

## 3.9 系統 schema 與物件

**為什麼要認識它們**:排查時你查的 `pg_tables`、`pg_stat_activity`、`pg_namespace` 全都住在 `pg_catalog`;而 `pg_temp_*` 是 3.10 情境 C-2 的主角。這幾個 schema 不能刪除:

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

### `pg_database_size` 與 `pg_size_pretty`

這兩個函數是搭配使用的:內層算大小、外層做格式化。

**`pg_database_size(name)`** 回傳資料庫的實際磁碟占用 (`bigint`,單位 bytes)。計算範圍是該資料庫的**全部**空間——資料表、索引、TOAST 等,是檔案系統上的真實占用,不是估計值。需要對目標資料庫的 `CONNECT` 權限。

同家族的常用函數:

| 函數 | 量什麼 |
|------|--------|
| `pg_table_size('shop.books')` | 單一表 (含 TOAST,不含索引) |
| `pg_indexes_size('shop.books')` | 該表所有索引 |
| `pg_total_relation_size('shop.books')` | 表 + 索引 + TOAST,最常用 |

**`pg_size_pretty(bigint)`** 把 bytes 換算成人類可讀的文字,如 `8529 kB`、`156 MB` (1024 進位)。純粹是顯示美化,不改變數值。

> ⚠️ 注意範例中 `ORDER BY pg_database_size(datname)` 是**重算原始數字**,而不是 `ORDER BY size`——`size` 已被轉成**文字**,按它排序會變成字串比較 (`"8 kB"` 排在 `"7 MB"` 後面),結果完全錯誤。慣例:顯示用 pretty 版本,排序用原始 bigint。

## 3.10 問題排查:情境模擬與排查順序

**為什麼要練這個**:本章的問題有個共同特徵 — 錯誤訊息**會誤導**。`relation "books" does not exist` 可能是 search_path、可能是權限、也可能表真的建到別處去了;查詢「沒報錯但回傳錯的資料」更是連訊息都沒有。能不能有系統地縮小範圍,比背再多語法都重要。本節先給一套通用排查順序,再用四個可以在本機重現的情境走一遍。

> 🧪 所有情境都在 [`scripts/04-troubleshooting-scenarios.sql`](./scripts/04-troubleshooting-scenarios.sql) 裡,用自己的 demo 物件 (schema / role / database),跑完自動清掉。建議一段一段執行,對照下面的說明。情境 D 需要超級使用者,且會刻意出現 2 個 ERROR。

### 通用排查順序:「找不到物件 / 找到錯的物件」

順序的邏輯是**先確認事實再猜原因、先便宜後昂貴**:

```
1. 物件到底存不存在?在哪個 schema?
   → SELECT schemaname, tablename FROM pg_tables WHERE tablename = '...';
     (函數用 pg_proc、型別用 pg_type;或 \dt *.表名)
2. 我現在「實際」從哪些 schema 找?
   → SELECT current_schemas(true);   ← 不是 SHOW search_path,後者看不到被跳過的 schema
3. 設定的 search_path 是哪一層來的?
   → SELECT setting, source FROM pg_settings WHERE name = 'search_path';  (\drds 看持久設定)
4. schema 在 search_path 裡卻不在 current_schemas(true) 裡?
   → 不存在 (typo / "$user" 同名 schema 不存在) 或沒有 USAGE 權限
     SELECT has_schema_privilege('schema', 'USAGE');
5. 找到了,但是對的那一個嗎?
   → SELECT n.nspname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.oid = '短名'::regclass;   ← 同名表遮蔽、暫時表遮蔽
6. 才動手修
   → 寫全名 > 把 search_path 設在 DATABASE/ROLE 層 > GRANT USAGE > ALTER TABLE SET SCHEMA 搬表
7. 驗證:同一條 SQL 再跑一次;新連線 (不是同一 session) 也要確認
```

### 情境 A:`relation "books" does not exist` — 但表明明在

**症狀**:同事的 SQL 在他機器上能跑,你這裡一執行就報 `relation "books" does not exist`;可是 pgAdmin 裡明明看得到 `shop.books`。

**排查順序與線索 (A-1)**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | `pg_tables` 確認表在哪 | `shop \| books` — 表在,在 `shop` |
| 2 | `SHOW search_path` | `"$user", public` — 沒有 `shop` |
| 3 | `current_schemas(true)` | `{pg_catalog,public}` — 實際只從 `public` 找 |

**根因**:錯誤訊息的「does not exist」是「**在我搜尋的範圍內**不存在」。同事的 role 或 database 設了 `search_path = shop, public`,你的沒有。

**修正**:寫全名 `shop.books`;或 `SET search_path TO shop, public` (長期解法是 `ALTER ROLE/DATABASE ... SET`,3.7)。

**驗證**:`current_schemas(true)` 變成 `{pg_catalog,shop,public}`,短名查到 8 本書。

**同樣的錯誤訊息,另一個根因 (A-2):對 schema 沒有 `USAGE` 權限**

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | 短名與全名各試一次 | 短名 → `relation "books" does not exist`;全名 → `permission denied for schema shop` — **兩種訊息不一致,就是權限問題的訊號** |
| 2 | `SHOW search_path` vs `current_schemas(true)` | search_path 有 `shop, public`,但生效清單只有 `{pg_catalog,public}` — `shop` 被**靜默跳過** |
| 3 | 以 DBA 身份替該 role 查權限 | `has_schema_privilege('ch03_reader','shop','USAGE')` → `f` |

**根因**:沒有 `USAGE` 的 schema 在名稱解析時直接跳過、不報權限錯誤。這是最容易被誤判成 search_path 問題的情況 — search_path 明明是對的。

**修正**:`GRANT USAGE ON SCHEMA shop TO ch03_reader; GRANT SELECT ON shop.books TO ch03_reader;`

**驗證**:同一個 role、同一個 search_path,`current_schemas(true)` 出現 `shop`,短名查到 8 本書。

### 情境 B:表建好了,卻建到別的 schema

**症狀**:migration 跑完沒有任何錯誤,程式卻報 `relation "shop.orders_archive" does not exist`。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | `pg_tables WHERE tablename = 'orders_archive'` | `public \| orders_archive` — 表在,但在 `public` |
| 2 | 回到 migration 當時的 session 設定:`SHOW search_path` | `"$user", public` — migration 忘了設 search_path |
| 3 | `SELECT current_user, current_schema()` | `postgres \| public` — 落點是 `public`,不是 `"$user"` |
| 4 | `$user` 同名 schema 存在嗎? | `user_schema_exists = f` |

**根因**:`CREATE TABLE` 未指定 schema 時,建在 search_path 中「**第一個實際存在**」的 schema。`"$user"` 展開後的同名 schema 不存在 → 跳過 → 落到 `public`。沒有報錯,因為 PostgreSQL 認為這完全正常。

**修正**:`ALTER TABLE public.orders_archive SET SCHEMA shop;` — 資料一起搬,不用重建。長期:migration 腳本第一行寫 `SET search_path`,或表名一律寫全名。

**驗證**:`pg_tables` 顯示 `shop | orders_archive`。

**反向陷阱 (B-2)**:哪天有人替你建了與使用者同名的 schema (`CREATE SCHEMA postgres`),你的 `current_schema()` 會**默默**從 `public` 變成 `postgres`,之後建的表全部落在那裡。腳本會重現這件事:建同名 schema → `current_schema()` 變了 → 新表 `silently_moved` 落在使用者同名 schema。習慣在 DDL 前 `SELECT current_schema();` 確認落點。

### 情境 C:查詢回傳「錯的資料」— 同名物件遮蔽

**症狀**:`SELECT count(*) FROM items` 應該有 100 列,只回來 3 列;沒有任何錯誤。更糟的是 `DROP TABLE items` 之後,要刪的那張表還在。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | 短名到底解析成哪一張?`pg_class JOIN pg_namespace WHERE oid = 'items'::regclass` | `resolved_schema = demo_b` — 但你以為在查 `demo_a` |
| 2 | 有幾個同名表? | `demo_a.items`、`demo_b.items` 兩張 |
| 3 | `SHOW search_path` | `demo_b, demo_a, public` — `demo_b` 排前面,先找到的贏 |

**根因**:search_path 的**順序**決定同名物件誰被選中。`'items'::regclass` 顯示的還是短名 `items`,看不出來;要 JOIN `pg_namespace` 才看得到真正的 schema。

**更隱蔽的變體 (C-2):暫時表**。`CREATE TEMP TABLE items (...)` 之後,`SHOW search_path` 完全沒變,但 `current_schemas(true)` 變成 `{pg_temp_10,pg_catalog,demo_b,demo_a,public}` — `pg_temp` 永遠排最前。此時 `SELECT count(*) FROM items` 回 0 列 (查到暫時表);`DROP TABLE items` 刪掉的也是暫時表,`demo_a.items`、`demo_b.items` 兩張都還在。

**修正**:多 schema 有同名表時一律寫全名;**DDL (DROP / ALTER / TRUNCATE) 更要寫全名** — 查錯只是結果不對,刪錯是資料不見。

**驗證**:`demo_a.items` 100 列、`demo_b.items` 3 列,各查各的。

### 情境 D:`DROP DATABASE` 失敗 — `is being accessed by other users`

**症狀**:要重建測試資料庫,`DROP DATABASE ch03_drop_demo` 報 `database "ch03_drop_demo" is being accessed by other users`,但你「明明沒開別的連線」。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | `pg_stat_activity WHERE datname = 'ch03_drop_demo'` | 一條 `idle` 的連線,`backend_start` 是幾分鐘前 |
| 2 | 看 `usename` / `application_name` / `client_addr` 判斷來源 | 腳本用 `dblink` 模擬;現實中通常是 pgAdmin 的 Object Explorer、應用程式連線池、忘記關的 psql |

**根因**:`DROP DATABASE` 要刪掉整個資料目錄,不允許任何 session 還連著。「idle」的連線也算。

**修正 (擇一)**:逐一 `SELECT pg_terminate_backend(pid)` (知道是誰、想留下其他連線時);或 `DROP DATABASE ... WITH (FORCE)` (PG 13+,一次踢掉全部再刪 — `setup/01-create-tutorial-db.sql` 用的就是它)。

**驗證**:`pg_database` 查不到該資料庫,`pg_stat_activity` 沒有殘留 session。

**同一家族 (D-2):`CREATE DATABASE cannot run inside a transaction block`**。`BEGIN; CREATE DATABASE x;` 直接報錯 — pgAdmin 一次執行多條語句 (隱式包成交易) 或 `psql -1` 時最常見。`CREATE / DROP DATABASE` 要單獨執行,不能包在交易裡。

## 章節腳本

- [`scripts/01-create-and-explore.sql`](./scripts/01-create-and-explore.sql) — 建立/瀏覽資料庫與 schema
- [`scripts/02-search-path-demo.sql`](./scripts/02-search-path-demo.sql) — search_path 行為示範
- [`scripts/03-search-path-query.sql`](./scripts/03-search-path-query.sql) — 查詢各層級 search_path 設定
- [`scripts/04-troubleshooting-scenarios.sql`](./scripts/04-troubleshooting-scenarios.sql) — 3.10 四個排查情境 (可重現)

---

下一章 ➡ [第 4 章:資料型別](../04-data-types/)
