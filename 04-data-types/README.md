# 第 4 章 資料型別

> 目標:認識 PostgreSQL 各類資料型別,**在建表前就知道每種型別是為了解決什麼問題**、選錯會付出什麼代價,以及型別出問題時怎麼有系統地排查。
>
> 🧰 **前置準備**:本章範例使用 `bookstore` 資料庫 (`shop` schema 與範例資料)。尚未建立的話,先在 repo 根目錄執行 `psql -d postgres -f setup/01-create-tutorial-db.sql` 與 `psql -d bookstore -f setup/02-sample-data.sql`,詳見[第 1 章 1.8 節](../01-installation/README.md#18-建立教學用資料庫)。
>
> 📐 **本章讀法**:每一節都先講「為什麼會需要這個型別 / 選錯會怎樣」,再講「怎麼用」。4.2 是建表前的決策清單,4.15 是四個可以實際重現的故障情境與排查順序 — 建議先讀 4.1~4.2 建立判斷框架,再看各型別的細節。

## 4.1 型別分類總覽

**為什麼型別這麼重要**:型別是資料庫對一個欄位「最早、最便宜、最不會被繞過」的約束。選對型別,錯誤資料在 INSERT 那一刻就被擋下 (`'abc'` 進不了 `INTEGER`);選錯型別,問題會潛伏到報表對不上帳、時間差 8 小時、查詢走不了索引才爆出來 — 而且那時資料已經幾百萬筆,改型別要停機重寫整張表。

**為什麼 PostgreSQL 有這麼多型別**:因為「一個值」的語意差很多。金額要的是精確到分;時間要的是「同一個瞬間」而不是牆上的數字;標籤是一組值而不是一個值;預約要的是「時段不重疊」。每一類型別都是為某種語意量身做的,本章涵蓋日常會用到的 95%。

| 大類 | 代表型別 | 解決什麼問題 |
|------|---------|-------------|
| 數值 | `SMALLINT`, `INTEGER`, `BIGINT`, `NUMERIC`, `REAL`, `DOUBLE PRECISION` | 整數範圍與精確/近似小數的取捨 |
| 序號 | `SERIAL`, `BIGSERIAL`, **`IDENTITY` (推薦)** | 自動產生不重複的主鍵 |
| 字串 | `CHAR(n)`, `VARCHAR(n)`, `TEXT` | 有無長度上限 |
| 日期時間 | `DATE`, `TIME`, `TIMESTAMP`, `TIMESTAMPTZ`, `INTERVAL` | 「哪一個瞬間」vs「牆上的數字」 |
| 布林 | `BOOLEAN` | 是/否/未知 三值 |
| UUID | `UUID` | 跨系統也不會撞的識別碼 |
| 二進位 | `BYTEA` | 原始位元組 (圖片、加密資料) |
| 列舉 | `ENUM` (自訂) | 固定的一小組狀態值 |
| 陣列 | `INT[]`, `TEXT[]`, ... | 一個欄位放一組值 |
| 範圍 | `INT4RANGE`, `TSRANGE`, ... | 區間與「不重疊」約束 |
| JSON | `JSON`, **`JSONB` (推薦)** | 結構不固定的半結構化資料 |
| 幾何 | `POINT`, `LINE`, `POLYGON` | 空間資料 |
| 網路 | `INET`, `CIDR`, `MACADDR` | IP / 網段,可做包含判斷 |

## 4.2 設計前的決策條件與考量重點

**為什麼要先想再建**:改型別是資料庫裡最昂貴的變更之一 — 多數 `ALTER COLUMN TYPE` 要**重寫整張表並鎖住它**,幾千萬筆就是幾十分鐘停機;而且 App 程式碼、ORM 對應、既有索引都要跟著改。建表時多花五分鐘回答下面的問題,比上線後改便宜一百倍。

### 先確認的前提

| 問題 | 為什麼重要 | 怎麼確認 |
|------|-----------|---------|
| **這個值需要精確,還是近似就好?** | 金額、數量、比率用浮點數會累積誤差 (4.15 情境 A);科學量測、座標用 `NUMERIC` 又慢又占空間 | 問業務:「差 0.01 可以接受嗎?」— 不行就 `NUMERIC` |
| **這個時間是「某個瞬間」還是「牆上的日期時間」?** | 訂單成立、登入、付款是瞬間 → `TIMESTAMPTZ`;「每天 09:00 提醒」「生日」是牆上數字 → `TIME` / `DATE`。混用會在時區改變時全部錯位 (情境 B) | 問:「使用者在東京看到的應該跟在台北看到的一樣嗎?」 |
| **值的範圍會長到多大?** | `INTEGER` 上限 21 億,流水號、事件表幾年就用完,溢位時整個寫入停擺;但全部用 `BIGINT` 又浪費空間與索引 | 估「每天幾筆 × 十年」;主鍵預設 `BIGINT` 是安全的 |
| **長度限制是業務規則,還是隨手寫的?** | `VARCHAR(50)` 不是效能設定,是「超過就拒絕」的約束;沒有業務依據的上限只會在上線後炸 (情境 D-1) | 找得到規格 (身分證 10 碼、ISO 貨幣碼 3 碼) 才用 `VARCHAR(n)`,否則 `TEXT` |
| **這組值會變嗎?變的頻率?** | `ENUM` 加值容易、**刪值不可能** (情境 D-2),改名要 DDL;會由業務人員維護的清單應該用查表 (lookup table) | 問:「這個清單一年會改幾次?誰改?」 |
| **這個欄位要拿來搜尋/JOIN 嗎?** | 型別決定索引能不能用:數字存成字串、再用整數去比,索引就廢了 (情境 C);JSONB 裡的值要查得快需要 GIN | 收集實際 SQL,看 WHERE / JOIN 用到哪些欄位 |
| **主鍵會跨系統、跨資料庫合併嗎?** | 自增 ID 在分庫、多地寫入、離線產生時會撞;UUID 不會撞但 16 bytes、隨機寫入讓 B-Tree 索引膨脹 | 單一資料庫 → `IDENTITY`;分散式產生 → `UUID` |

### 決策對照:什麼情況選什麼

| 情況 | 選擇 | 理由 |
|------|------|------|
| 金額、稅、匯率、任何要「對得上帳」的數字 | `NUMERIC(p, s)` | 十進位精確,加總不飄;代價是比浮點慢、大,但財務資料承受不起誤差 |
| 感測器讀數、座標、統計權重,允許近似 | `DOUBLE PRECISION` | 8 bytes、CPU 原生運算快;`REAL` 只有 6 位有效數字,少用 |
| 計數、外鍵、狀態碼 | `INTEGER` | 4 bytes 是最平衡的預設 |
| 流水號主鍵、事件表、任何「會一直長」的欄位 | `BIGINT` / `BIGSERIAL` / `BIGINT IDENTITY` | 21 億看起來很多,高流量幾年就到;溢位是停機事故 |
| 單一資料庫產生的主鍵 | `INTEGER/BIGINT GENERATED ALWAYS AS IDENTITY` | SQL 標準、不能被手動塞值撞號;`SERIAL` 只是舊糖衣 |
| 跨系統、離線、分庫產生的主鍵 | `UUID DEFAULT gen_random_uuid()` | 不用協調也不會撞;要注意索引隨機寫入的代價 |
| 「某個瞬間」(建立時間、付款時間、登入時間) | `TIMESTAMPTZ` | 內部存 UTC,任何時區讀都是同一瞬間 |
| 「牆上的日期/時間」(生日、營業時間、排程) | `DATE` / `TIME` | 這些本來就沒有「瞬間」的概念,套時區反而錯 |
| 沒有業務上限的文字 (姓名、地址、備註) | `TEXT` | PostgreSQL 的 `TEXT` 與 `VARCHAR` 效能相同,`n` 只是多一條會炸的約束 |
| 有明確規格的碼 (ISO 貨幣 3 碼、國家 2 碼) | `VARCHAR(n)` 或 `CHAR(n)` + `CHECK` | 上限是規格的一部分,讓資料庫替你擋 |
| 固定的一小組狀態,由開發者維護 | `ENUM` | 4 bytes、可排序、拼錯就報錯;但刪值要重建型別 |
| 會由業務人員增減、要帶說明/排序/停用的清單 | 查表 + 外鍵 | 加值是 INSERT 不是 DDL;可以軟刪除、加欄位 |
| 一個欄位放「一組同型別的值」且不需要單獨 JOIN | `ARRAY` | 讀寫都是一列,GIN 可索引 `@>`;但陣列元素無法有外鍵 |
| 結構不固定、每筆欄位不同、來自外部 API | `JSONB` | 不用為每個新欄位改 schema,GIN 可索引;但沒有型別檢查,別把核心欄位藏進去 |
| 時段、區間,要保證「不重疊」 | `TSTZRANGE` / `DATERANGE` + `EXCLUDE` | 資料庫層保證預約不撞期,App 不用自己鎖 |

### 上線 / 實務考量

- **改型別的成本要提前知道**:多數 `ALTER COLUMN TYPE` 會重寫整張表並取得 `ACCESS EXCLUSIVE` 鎖。例外是「放寬」— `VARCHAR(30) → VARCHAR(100)` 或 `→ TEXT` 只改 catalog,瞬間完成 (4.15 情境 D-1);`INTEGER → BIGINT` 則要重寫,大表要排維護窗口。
- **時區設定要固定**:`TIMESTAMPTZ` 讀出來的顯示值跟著 session `timezone` 走;App 連線池、psql、pgAdmin 各自的時區設定不一致,同一筆資料就會「看起來不同」。建議伺服器與連線都明確設定 (`ALTER DATABASE ... SET timezone`),不要依賴預設。
- **浮點欄位的既有資料要 ROUND 再轉**:`DOUBLE PRECISION → NUMERIC` 時,舊值帶著誤差 (`19.990000000000002`),`USING ROUND(col::numeric, 2)` 才能得到乾淨的數字。
- **ENUM 的改動是 DDL**:加值 (`ADD VALUE`) 在交易內執行後,同一交易不能立刻使用新值;改名要協調所有 App 版本;刪值不存在。清單會變就別用 ENUM。
- **JSONB 不是免驗證的藉口**:進 JSONB 的欄位沒有型別、沒有 NOT NULL、沒有外鍵。會拿來 WHERE / JOIN / 統計的欄位,拉出來做正規欄位。
- **NULL 的語意要在建表時決定**:「沒填」跟「填了空字串」是兩回事;不允許未知就 `NOT NULL` + `DEFAULT`,別等到 `COUNT` 對不上才發現 (4.14)。

## 4.3 數值

**為什麼分這麼多種**:整數型別的差別只在「能存多大 vs 占多少空間」;小數型別的差別是本質性的 — `NUMERIC` 是十進位、精確,`REAL`/`DOUBLE PRECISION` 是二進位浮點、近似。0.1 在二進位裡跟 1/3 在十進位裡一樣是無限循環小數,存進去就已經不是 0.1 了。

```sql
SMALLINT          -- 2 bytes, ±32K
INTEGER (INT)     -- 4 bytes, ±2.1B
BIGINT            -- 8 bytes, ±9.2 × 10^18
NUMERIC(p, s)     -- 任意精度,推薦用於「金額」
REAL              -- 4 bytes 浮點 (~6 位有效)
DOUBLE PRECISION  -- 8 bytes 浮點 (~15 位)
```

**重點守則**:
- **金額永遠用 `NUMERIC`**:`NUMERIC(10,2)` 表 10 位數,小數 2 位 (最大 99,999,999.99)。一筆的誤差看不出來,20 萬筆加總就差得出來 (4.15 情境 A)。
- **避免 `REAL`/`DOUBLE` 做財務計算**:浮點誤差會讓 0.1+0.2 ≠ 0.3。
- **`INTEGER` 是大多數欄位的合理預設**,除非你確定數量會超過 21 億 — 主鍵與事件表請直接用 `BIGINT`,溢位是停機事故。

```sql
-- 範例
CREATE TABLE products (
    id    INTEGER,
    price NUMERIC(10,2)
);
INSERT INTO products VALUES (1, 9.99), (2, 1234567.89);
```

> 💡 **沒指定 schema,表會建在哪?** 建在 `search_path` 中**第一個實際存在的 schema**(見第 3 章 3.7 節)。預設 `"$user", public` 下,與使用者同名的 schema 通常不存在而被跳過,所以本章的練習表都落在 **`public`**——與教程主要資料所在的 `shop` schema 互不干擾。可用 `SELECT current_schema();` 事先確認落點。注意:若你執行過第 3 章的 `ALTER ROLE ... SET search_path TO shop, public;` 範例,新 session 的落點會變成 `shop`,可用 `SHOW search_path;` 檢查、`ALTER ROLE rexwang RESET search_path;` 還原。

## 4.4 序號:SERIAL vs IDENTITY

**為什麼需要自動序號**:主鍵要唯一,靠 App 自己算「上一筆 +1」在並發時必撞;資料庫用 sequence 發號才是原子的。

**為什麼推薦 `IDENTITY` 而不是 `SERIAL`**:`SERIAL` 其實是 `INTEGER DEFAULT nextval('...')` 加一條隱藏的 sequence 的糖衣 — 任何人都可以手動 `INSERT ... (id) VALUES (100)`,之後 sequence 發到 100 就撞 `duplicate key`。這是匯入資料、還原備份後最常見的事故。`IDENTITY` 是 SQL 標準,而且 `GENERATED ALWAYS` 預設拒絕手動指定。

```sql
-- 舊式 (仍可用)
CREATE TABLE t (id SERIAL PRIMARY KEY);

-- 新式 (PG 10+,推薦)
CREATE TABLE t (
    id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY
);

-- 或允許手動覆蓋
CREATE TABLE t (
    id INTEGER GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY
);
```

`GENERATED ALWAYS` 比 `SERIAL` 安全:除非用 `OVERRIDING SYSTEM VALUE`,否則不能手動指定 id,避免日後 sequence 撞號。

## 4.5 字串

**為什麼三種看起來一樣的型別要分**:在很多資料庫裡 `VARCHAR(n)` 比 `TEXT` 快、`CHAR(n)` 更快,所以大家習慣寫 `VARCHAR(255)`。PostgreSQL **不是**這樣:三者底層儲存完全相同,`n` 只是一條「超過就拒絕」的檢查。所以問題變成:這個上限是業務規則嗎?不是的話,它只是一顆等著上線後爆的雷 (4.15 情境 D-1)。

```sql
CHAR(n)     -- 定長,不足補空白 (極少使用)
VARCHAR(n)  -- 變長,有長度上限
TEXT        -- 變長,無上限
```

**重要**:
- `VARCHAR(n)` 與 `TEXT` 在 PostgreSQL **效能無差異**,長度限制只是檢查約束。
- 沒有明確業務上限就直接用 `TEXT`,要限制長度就用 `VARCHAR(n)` 或加 `CHECK (length(col) <= n)` — 後者改上限不用改型別。
- 字串以 UTF-8 儲存,`length()` 算「字元數」,`octet_length()` 算「位元組數」。中文一個字 3 bytes,算「幾個字」跟算「幾 bytes」會差三倍,對接外部系統的長度限制時要問清楚是哪一種。

```sql
SELECT
    length('你好 Hello'),       -- 8 (字元)
    octet_length('你好 Hello'); -- 12 (UTF-8 bytes)
```

## 4.6 日期與時間

**為什麼這是最容易踩坑的型別**:「2026-03-01 09:30」這串數字本身沒有意義,除非知道它是哪裡的 09:30。`TIMESTAMP` (無時區) 只存這串數字;`TIMESTAMPTZ` 存的是「那個瞬間」(內部轉成 UTC)。只要 App、資料庫、使用者三方時區永遠一致,兩者看起來沒差 — 直到伺服器搬到 UTC 機房、或使用者從東京登入,所有舊資料就一起錯位 (4.15 情境 B)。

```sql
DATE                     -- 年月日,4 bytes
TIME                     -- 時分秒
TIMESTAMP                -- 日期 + 時間,**無時區**
TIMESTAMP WITH TIME ZONE -- 簡寫 TIMESTAMPTZ,**有時區** (推薦)
INTERVAL                 -- 時間區間 (1 day 2 hours)
```

**為什麼推薦 `TIMESTAMPTZ`?**
- 儲存時自動轉成 UTC
- 讀取時根據 session `timezone` 顯示
- 不管你的客戶端在哪個時區,**同一個瞬間永遠是同一個值**

**什麼時候反而該用無時區的型別**:值本來就是「牆上的數字」而不是瞬間 — 生日 (`DATE`)、每天 09:00 的排程 (`TIME`)、「當地時間 12/31 23:59 截止」。這些套上時區反而會因夏令時間或搬機房而跑掉。

```sql
SHOW timezone;            -- 顯示當前 session 時區
SET timezone = 'Asia/Taipei';
SET timezone = 'UTC';

-- 比較行為
CREATE TEMP TABLE tdemo (
    ts   TIMESTAMP,
    tstz TIMESTAMPTZ
);
INSERT INTO tdemo VALUES ('2026-01-01 12:00', '2026-01-01 12:00+08');
SELECT * FROM tdemo;
SET timezone = 'UTC';
SELECT * FROM tdemo;     -- tstz 會顯示為 04:00 UTC
```

### 常用日期函數

**為什麼要用內建函數而不是自己算**:閏年、月底、夏令時間、時區偏移全都是坑;`DATE_TRUNC` 與 `INTERVAL` 運算會幫你處理。

```sql
NOW()                            -- 當前 timestamptz
CURRENT_DATE                      -- 當前日期
CURRENT_TIMESTAMP                 -- 同 NOW()
AGE(timestamp1, timestamp2)       -- 兩時間差距 (1 year 2 mons ...)
EXTRACT(YEAR FROM ts)             -- 取年/月/day/hour/dow...
DATE_TRUNC('month', ts)           -- 截斷到月 (常用於統計)
ts + INTERVAL '1 day 2 hours'    -- 時間運算
ts::DATE                         -- 強制轉型為 DATE
```

> ⚠️ `timestamptz::date` 的結果依 session 時區而定 (UTC 的 3/1 23:00 在台北已經是 3/2)。報表按「哪一天」統計前,先 `SET timezone` 到業務所在時區;也因為這個依賴,`created_at::date` 無法建表達式索引 (第 9 章 9.11 情境 A)。

## 4.7 布林

**為什麼不用 `INT` 存 0/1 或 `CHAR(1)` 存 'Y'/'N'**:`BOOLEAN` 只允許三個值 (真/假/未知),`'Y'`、`'y'`、`'yes'`、`2` 這類髒資料進不來;查詢條件也可以直接寫 `WHERE is_active`,不用記哪個數字代表什麼。

```sql
BOOLEAN  -- TRUE / FALSE / NULL
-- 接受字面值:'t', 'f', 'yes', 'no', '1', '0', 'on', 'off'
```

## 4.8 UUID

**為什麼需要**:自增 ID 只在「單一資料庫發號」時安全。手機離線建立資料、多個服務各自產生、分庫後要合併 — 都會撞號。UUID 是 128 bits 的隨機數,不用任何協調也幾乎不可能重複,**分散式系統下比自增 ID 更合適**。

**代價**:16 bytes (自增 ID 是 4~8),而且值是隨機的 — 每次 INSERT 落在 B-Tree 索引的隨機位置,索引膨脹得比順序 ID 快。單一資料庫、寫入量大的表,`BIGINT IDENTITY` 仍是更好的預設。

```sql
CREATE EXTENSION IF NOT EXISTS "pgcrypto";  -- 提供 gen_random_uuid()

CREATE TABLE events (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    payload TEXT
);
```

## 4.9 ENUM (列舉)

**為什麼需要**:狀態欄位存 `TEXT`,遲早會出現 `'Paid'`、`'paid '`、`'payed'` 三種寫法;存 `INT` 則沒人記得 3 代表什麼。`ENUM` 只接受宣告過的值、只占 4 bytes、可以依宣告順序排序。

**代價** (決定用不用之前一定要知道):值的集合是型別定義的一部分 — 加值要 DDL,**刪值沒有語法** (4.15 情境 D-2),改順序要重建型別。適合「由開發者維護、幾乎不變」的小集合 (訂單狀態);會由業務人員增減的清單 (商品分類) 應該用查表。

```sql
CREATE TYPE mood AS ENUM ('sad', 'ok', 'happy');

CREATE TABLE person (
    name TEXT,
    current_mood mood
);

INSERT INTO person VALUES ('Alice', 'happy');
SELECT * FROM person WHERE current_mood > 'sad';  -- 可比較,依宣告順序
```

> 我們的 `shop.order_status` 就是 ENUM。

## 4.10 陣列

**為什麼需要**:一篇文章有多個標籤。正規化作法是另開 `article_tags` 表再 JOIN;但如果標籤只是「跟著文章讀寫」、不需要單獨查「這個標籤有哪些文章」以外的關聯,陣列讓它們留在同一列,讀寫都少一次 JOIN。

**什麼時候不該用**:元素需要外鍵約束、需要單獨更新某個元素、需要以元素為主體做統計 — 這些都是關聯表的強項,陣列做起來又醜又慢。

```sql
CREATE TABLE tags_demo (
    id    SERIAL PRIMARY KEY,
    title TEXT,
    tags  TEXT[]            -- 字串陣列
);
INSERT INTO tags_demo VALUES
    (DEFAULT, 'PG', ARRAY['db','open-source']),
    (DEFAULT, 'Rust', '{"lang","systems"}');  -- 字面值寫法

-- 查詢
SELECT * FROM tags_demo WHERE 'db' = ANY(tags);
SELECT * FROM tags_demo WHERE tags @> ARRAY['open-source'];   -- 可用 GIN 索引

-- 元素存取 (1-based)
SELECT title, tags[1] AS first_tag FROM tags_demo;
```

## 4.11 JSON / JSONB

**為什麼需要**:外部 API 回傳的資料、每種商品規格不同的屬性 (書有頁數、衣服有尺寸)、使用者自訂欄位 — 這些「每筆結構都不一樣」的資料若硬要正規化,不是一張稀疏到全是 NULL 的寬表,就是一張難查的 key-value 表。JSONB 讓一個欄位裝下整份文件,又能用操作子查進去。

**為什麼是 `JSONB` 不是 `JSON`**:`JSON` 只是通過語法檢查的文字,每次查都要重新解析;`JSONB` 解析後以二進位存,查詢快、可建 GIN 索引、key 會去重。只有需要「保留原始文字格式」(例如稽核原始請求) 才用 `JSON`。

**什麼時候不該用**:會拿來 WHERE / JOIN / 加總 / 需要 NOT NULL 或外鍵的欄位。JSONB 裡沒有型別檢查,`"age": "thirty"` 也進得去。核心欄位做正規欄位,JSONB 放真正不固定的部分。

```sql
JSON   -- 純文字儲存,保留輸入順序與空白
JSONB  -- 二進位儲存,**支援索引,實務上首選**
```

```sql
CREATE TABLE docs (
    id   SERIAL PRIMARY KEY,
    data JSONB
);

INSERT INTO docs (data) VALUES
    ('{"name":"Alice","age":30,"tags":["admin","vip"]}'),
    ('{"name":"Bob","age":25,"tags":["user"]}');

-- 操作子
SELECT data->'name' AS name_json,       -- 取 JSON 元素 (回 JSON)
       data->>'name' AS name_text,      -- 取 JSON 元素 (回 TEXT)
       data#>'{tags,0}' AS first_tag,   -- 路徑取值
       data ? 'age' AS has_age,         -- 是否有 key
       data @> '{"age":30}'             -- 是否包含子文件
FROM docs;
```

更多 JSON 應用見 [第 15 章](../15-json-fulltext/)。

## 4.12 範圍型別

**為什麼需要**:「房間 101 在 3/1 14:00 到 3/3 11:00 被訂走」用兩個欄位 `start_at`、`end_at` 存,要保證不撞期得靠 App 先 SELECT 再 INSERT — 兩個人同時訂就雙重預約。範圍型別把「區間」當成一個值,配合 `EXCLUDE` 約束,**資料庫層**保證不重疊,並發也擋得住。

```sql
INT4RANGE          -- 整數範圍
NUMRANGE           -- 數字範圍
TSRANGE / TSTZRANGE-- 時間範圍 (常用於預約系統!)
DATERANGE          -- 日期範圍
```

```sql
-- 飯店預約範例
CREATE TABLE reservation (
    id     SERIAL PRIMARY KEY,
    room   INT,
    period TSTZRANGE NOT NULL,
    -- 確保同一房間不重疊
    EXCLUDE USING gist (room WITH =, period WITH &&)
);
```

## 4.13 強制轉型 (Casting)

**為什麼需要明確轉型**:PostgreSQL 對型別很嚴格 — `TEXT` 欄位不能直接跟 `INTEGER` 比較,會報 `operator does not exist: text = integer` (4.15 情境 C)。這是刻意的:隱含轉型會讓「`'10' < '9'` 是字串比較還是數字比較」這種歧義悄悄產生錯誤結果。

**轉哪一邊很重要**:永遠把「參數/字面值」轉成欄位的型別,不要把欄位轉成參數的型別 — 對欄位做轉型等於對欄位套函數,索引會失效。

```sql
SELECT '2026-01-01'::date;         -- 字面值轉 DATE
SELECT CAST('123' AS INTEGER);     -- 標準 SQL 寫法
SELECT NULL::text;                  -- NULL 也要明確型別

-- 在欄位上
SELECT id, price::INTEGER FROM shop.books;
```

## 4.14 NULL 的特殊性

**為什麼 NULL 需要單獨一節**:NULL 不是「空」也不是 0,而是「未知」。三值邏輯讓 `WHERE col <> 'x'` 默默漏掉所有 NULL 的列、`COUNT(col)` 跟 `COUNT(*)` 對不上、`NOT IN (含 NULL 的子查詢)` 永遠回空 — 這些都不報錯,只給你錯的數字。

- `NULL` 不是值,而是「未知」
- `NULL = NULL` 結果是 `NULL` (不是 TRUE),用 `IS NULL` / `IS NOT NULL`
- 聚合函數 (`SUM`, `AVG`, `COUNT(col)`) 忽略 NULL
- `COUNT(*)` 會把 NULL 也算進去

```sql
SELECT NULL = NULL;      -- NULL
SELECT NULL IS NULL;     -- t
SELECT COALESCE(NULL, NULL, 'default');  -- 'default'
SELECT NULLIF(0, 0);     -- NULL  (常用於避免除 0)
```

**設計時的對策**:不允許未知的欄位就 `NOT NULL` + `DEFAULT`,讓「沒填」在 INSERT 時就被擋下,而不是等報表對不上才發現。

## 4.15 問題排查:情境模擬與排查順序

**為什麼要練這個**:型別選錯的問題有個共同點 — **資料早就寫進去了**。報錯的那一刻 (`value too long`、`operator does not exist`) 只是冰山一角;更多的是不報錯、只給錯數字的情況 (金額差幾分、時間差 8 小時)。排查的重點是先確認「型別是什麼、資料實際長什麼樣」,再決定要改查詢還是改型別 — 後者代價高得多。

> 🧪 所有情境都在 [`scripts/04-troubleshooting-scenarios.sql`](./scripts/04-troubleshooting-scenarios.sql) 裡,用自己的 demo 表 (落在 `public`),跑完自動清掉。預期的錯誤都包在 `DO … EXCEPTION` 裡以 NOTICE 顯示,腳本不會中斷。建議一段一段執行,對照下面的說明。

### 通用排查順序:「數字不對 / 型別報錯」

順序的邏輯是**先看事實 (型別、資料、環境),再看邏輯,最後才改 schema**:

```
1. 錯誤訊息裡的 SQLSTATE 是什麼?
   → 22001 太長、22003 數值溢位、42883 型別不符 (operator does not exist)、
     22P02 無法解析 (invalid input syntax) — 錯誤碼直接指向型別問題
2. 欄位的實際型別是什麼?(不要相信文件或記憶)
   → \d 表名;information_schema.columns 的 data_type / character_maximum_length / numeric_scale
3. 資料實際長什麼樣?
   → max(length(col))、min/max(col)、有沒有非預期格式 (col !~ '^[0-9]+$')
4. 環境參數是什麼?
   → SHOW timezone、SHOW DateStyle、client_encoding — 時間/字串問題常是環境不一致
5. 用最小例子重現
   → SELECT 0.1::float8 + 0.2;SELECT '09:30'::timestamp AT TIME ZONE ...;一行就能證明根因
6. 決定修哪一層:查詢 (改參數型別) > 顯示 (SET timezone / ROUND) > schema (ALTER TYPE)
   → 改 schema 前先評估:會不會重寫表?鎖多久?既有資料要不要轉換 (USING)?
7. 驗證:同一條查詢、同一份資料再跑一次,數字對上、計畫正確、錯誤不再出現
```

### 情境 A:月結報表金額跟財務系統對不上,差了幾分錢

**症狀**:每一筆訂單金額看起來都正確,但 20 萬筆 `SUM(amount)` 出來是 `1559341.0299997393`,財務系統是 `1559341.03`。差額很小,但財務對帳「差一分也不能過」。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | `information_schema.columns` 看 `amount` 的型別 | `double precision` — 二進位浮點 |
| 2 | 同樣資料用 `NUMERIC(12,2)` 再 SUM 一次對照 | float `1559341.0299997393` vs numeric `1559341.03` |
| 3 | 最小重現:`SELECT 0.1::float8 + 0.2::float8` | `0.30000000000000004`,`= 0.3` 是 **false** |

**根因**:`DOUBLE PRECISION` 是二進位浮點數,0.1、19.99 這類十進位小數無法精確表示,每筆都帶著 10⁻¹⁶ 等級的誤差;單筆顯示時被四捨五入掩蓋,20 萬筆累加後就變成看得見的差額。

**修正**:

```sql
ALTER TABLE ledger_float
    ALTER COLUMN amount TYPE NUMERIC(12,2) USING ROUND(amount::numeric, 2);
```

`USING ROUND(...)` 很重要 — 既有的 float 值本身就帶著誤差,直接轉會得到 `19.990000000000002`。

**驗證**:改型後 `SUM` 為 `1559341.03`,與對照組相等 (`equal = t`)。

### 情境 B:伺服器搬到 UTC 之後,所有訂單時間都「提早了 8 小時」

**症狀**:App 從台北機房搬到雲端 (UTC)。搬家前的訂單顯示 `09:30`,新訂單同一時刻卻顯示 `01:30`;報表「按日統計」的數字全部錯位。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | 同一列在兩個時區讀 | `TIMESTAMP` 欄位在台北和 UTC 都顯示 `09:30:00` (數字沒變);`TIMESTAMPTZ` 對照欄在 UTC 正確顯示 `01:30:00+00` |
| 2 | 確認欄位型別與 `SHOW timezone` | `ordered_at` 是 `timestamp without time zone`;session 是 `UTC` |
| 3 | 把 `TIMESTAMP` 轉成瞬間跟對照欄相減 | `drift = 08:00:00` |

**根因**:`TIMESTAMP` (無時區) 只存「牆上的數字」,不記錄那是哪裡的 09:30。寫入時靠「大家都在台北」這個隱含約定;環境時區一改,約定就破了,舊資料被當成 UTC 09:30 (實際是 UTC 01:30)。

**修正**:改成 `TIMESTAMPTZ`,並用 `AT TIME ZONE` 明確告訴 PostgreSQL 舊數字是台北時間:

```sql
ALTER TABLE orders_ts
    ALTER COLUMN ordered_at TYPE TIMESTAMPTZ
    USING ordered_at AT TIME ZONE 'Asia/Taipei';
```

**驗證**:UTC 下 `ordered_at = ordered_tz` 為 `t`;切回 `Asia/Taipei` 兩欄都顯示 `09:30:00+08`。

**延伸思考**:這個 `ALTER` 會重寫整張表;而且「舊資料全是台北時間」這個假設要先確認 — 若中間換過機房,不同時期的列要用不同的 `AT TIME ZONE`。

### 情境 C:同一個查詢有時報錯、有時慢 — 型別不符與隱含轉型

**症狀**:`customer_code` 有索引。App v1 查詢直接報錯 `operator does not exist: text = integer`;App v2「修好了」不報錯,但 10 萬列的表每次查要掃全表。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | 看 v1 的錯誤碼 | `42883` — 沒有 `text = integer` 這個運算子;參數是整數,欄位是文字 |
| 2 | `EXPLAIN (ANALYZE, BUFFERS)` v2 的查詢 `WHERE customer_code::int = 42` | `Seq Scan` + `Filter: ((customer_code)::integer = 42)` + `Rows Removed by Filter: 99999` |
| 3 | 確認欄位型別 | `text`,存的是 `'000042'` 這種補零字串 |

**根因**:欄位是 `TEXT`,App 傳的是 `INTEGER`。PostgreSQL 不會偷偷把 text 轉成 int (v1 報錯是對的);v2 把**欄位**轉型去遷就參數,等於對欄位套函數 — 索引存的是原值,用不上。正確做法永遠是**把參數轉成欄位的型別**。

**修正**:參數改成欄位的型別與格式:

```sql
SELECT * FROM customers_code WHERE customer_code = lpad('42', 6, '0');
```

**驗證**:計畫變成 `Index Scan using idx_customers_code`,`Index Cond: (customer_code = '000042'::text)`,4.4ms → 0.02ms。長期若要改成整數型別,先確認 `customer_code !~ '^[0-9]+$'` 的列數是 0。

### 情境 D:上線後偶發 value too long / 想刪掉 ENUM 的值卻刪不掉

**症狀 D-1**:註冊功能偶爾失敗,log 只有 `value too long for type character varying(30)`。

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | 錯誤碼 `22001` → 找出有長度限制的欄位 | `name character varying (30)` |
| 2 | 問「30 是業務規則還是隨手寫的?」看既有資料實際長度 | `max_len = 3` — 上限跟資料毫無關係,是隨手寫的 |

**根因**:`VARCHAR(30)` 不是效能設定,是一條「超過就拒絕」的約束;人名沒有業務上限,西班牙語系的全名 40 個字元很常見。

**修正**:`ALTER TABLE members ALTER COLUMN name TYPE TEXT;` — 放寬 `VARCHAR` / 改 `TEXT` 只改 catalog,**不重寫表、瞬間完成**,可以直接在線上做。

**驗證**:同一筆 40 字元的資料再插一次成功。

**症狀 D-2**:業務要下架 `legacy` 狀態,`ALTER TYPE ticket_status DROP VALUE 'legacy'` 回 `dropping an enum value is not implemented` (SQLSTATE `0A000`)。

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | `pg_enum` 看目前的值;`information_schema.columns` 看哪些表用這個型別;`GROUP BY status` 看還有多少列在用 | 4 個值、1 張表、1 列還是 `legacy` |

**根因**:ENUM 的值是型別定義的一部分,PostgreSQL 只提供 `ADD VALUE` / `RENAME VALUE`,沒有 `DROP VALUE` — 要保證沒有任何列、索引、預設值還在引用它,成本太高。

**修正** (務實作法):先把資料遷走,再把值改名標記為棄用;真要移除得建新型別、`ALTER COLUMN TYPE` 轉過去、刪舊型別 (會重寫表):

```sql
UPDATE tickets SET status = 'closed' WHERE status = 'legacy';
ALTER TYPE ticket_status RENAME VALUE 'legacy' TO '_deprecated_legacy';
```

**驗證**:`GROUP BY status` 不再有舊值;`pg_enum` 中該值已標記為 `_deprecated_legacy`。

**延伸思考**:這正是 4.2 決策表說的 — 會變的清單用查表而不是 ENUM,下架一個狀態就只是 `UPDATE ... SET active = false`。

## 章節腳本

- [`scripts/01-numeric-string.sql`](./scripts/01-numeric-string.sql) — 數值與字串
- [`scripts/02-datetime.sql`](./scripts/02-datetime.sql) — 日期時間與時區
- [`scripts/03-array-json-uuid.sql`](./scripts/03-array-json-uuid.sql) — 陣列 / JSONB / UUID / ENUM
- [`scripts/04-troubleshooting-scenarios.sql`](./scripts/04-troubleshooting-scenarios.sql) — 4.15 四個排查情境 (可重現)

---

下一章 ➡ [第 5 章:資料表設計與約束](../05-tables-constraints/)
