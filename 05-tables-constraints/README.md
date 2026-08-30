# 第 5 章 資料表設計與約束

> 目標:理解約束到底在替你擋什麼、**建表前要先決定哪些事**、每種約束的適用時機,以及當約束「擋錯人」或「沒擋到」時怎麼有系統地排查。
>
> 🧰 **前置準備**:本章範例使用 `bookstore` 資料庫 (`shop` schema 與範例資料)。尚未建立的話,先在 repo 根目錄執行 `psql -d postgres -f setup/01-create-tutorial-db.sql` 與 `psql -d bookstore -f setup/02-sample-data.sql`,詳見[第 1 章 1.8 節](../01-installation/README.md#18-建立教學用資料庫)。
>
> 📐 **本章讀法**:每一節都先講「為什麼會需要這個」,再講「怎麼做」。5.2 是動手前的決策清單,5.12 是四個可以實際重現的故障情境與排查順序 — 建議先讀 5.1~5.2 建立判斷框架,再看語法。

## 5.1 為什麼需要約束

**沒有約束時會發生什麼**:資料庫只是一堆可以塞任何東西的欄位。價格可以是負數、訂單可以指向不存在的客戶、同一個 email 可以註冊三次、`status` 可以是 `'pendng'` (打錯字)。這些資料不會在寫入當下出事,而是在三個月後的報表、對帳、或客服電話裡爆開 — 而那時已經分不清哪一筆才是對的。

**約束怎麼解決**:把「這張表的資料必須長什麼樣」宣告在表定義裡,讓 PostgreSQL 在**每一次寫入**時替你檢查,不合格就拒絕。應用程式有 bug、有人直接下 SQL、匯入腳本寫錯,約束都一視同仁地擋。它是資料正確性的**最後一道防線**,而且是唯一一道不會被繞過的。

**但約束也有代價**:每次寫入都要多做檢查 (FK 要查父表、UNIQUE 要查索引);對既有大表補約束會鎖表;定義得太嚴,合法的業務變化就進不來。所以「要不要加、加哪一種、什麼時候加」是取捨 — 下一節就是做這個取捨的清單。

### CREATE TABLE 完整語法

```sql
CREATE TABLE [IF NOT EXISTS] [schema.]table_name (
    column_name DATA_TYPE [COLUMN_CONSTRAINT ...],
    ...
    [TABLE_CONSTRAINT, ...]
)
[INHERITS (parent_table)]
[PARTITION BY ...]
[TABLESPACE name]
;
```

## 5.2 設計前的決策條件與考量重點

**為什麼要先想再建**:約束是表定義的一部分,表一旦上線、有了幾百萬列資料,改約束就是「鎖表 + 清髒資料 + 改應用程式」三件事一起來 (5.12 情境 D)。建表時多花十分鐘回答下面的問題,比上線後補救便宜一百倍。

### 先確認的前提

| 問題 | 為什麼重要 | 怎麼確認 |
|------|-----------|---------|
| **這張表的「一筆」代表什麼?** | 決定主鍵。一筆是「一個客戶」還是「客戶在某組織的一個身份」?搞錯就會有重複或塞不進去的資料 | 用一句話說出「每一列是一個 ___」;說不出來就是表設計還沒想清楚 |
| **哪些欄位在業務上必須唯一?** | 唯一性是業務規則,不是技術決定。email?員工編號?「同一訂單同一本書」? | 問領域專家;想「兩筆資料在什麼情況下算重複」 |
| **NULL 代表什麼意思?** | 每個可空欄位都是一個隱含的業務狀態 (未知/不適用/尚未填)。沒想清楚就會有 `WHERE col = NULL` 永遠找不到的 bug,以及 5.12 情境 B 的重複 | 每個欄位問「什麼情況下會沒有值?」答不出來就 `NOT NULL` |
| **父資料被刪時,子資料該怎麼辦?** | 這是 FK 的 `ON DELETE` 選項,決定「刪一筆會不會連鎖消失幾千筆」(5.12 情境 C) 或「永遠刪不掉」(情境 A) | 對每一條 FK 明確回答:跟著刪 / 留下但斷開 / 禁止刪 |
| **資料會從哪裡進來?** | 只有應用程式寫入,還是也有匯入腳本、其他系統、DBA 手動?來源越多,越需要在 DB 層擋 | 列出所有寫入路徑 |
| **表會長多大、寫入多頻繁?** | 影響「FK 要不要建索引」、「補約束要不要用 NOT VALID」、「CHECK 裡能不能放昂貴運算」 | 估一年後的列數與每秒寫入量 |

### 決策對照:什麼情況選什麼

| 情況 | 選擇 | 理由 |
|------|------|------|
| 主鍵:業務上有穩定、不重複、不會變的識別碼 (國家 ISO 代碼、ISBN) | 自然鍵 | 不用多一個無意義欄位;JOIN 時可讀 |
| 主鍵:識別碼可能變 (email、電話)、可能重複、或根本沒有 | 代理鍵 `INT GENERATED ALWAYS AS IDENTITY` | 業務變動不影響所有 FK;**預設選這個** |
| 主鍵:需要在 DB 外產生、或要避免被猜到 (公開 URL) | `UUID DEFAULT gen_random_uuid()` | 分散產生不衝突;代價是索引較大、無序插入 |
| 子資料「沒有父就沒意義」(訂單明細之於訂單) | FK `ON DELETE CASCADE` | 父刪子跟著刪是正確語意;但只在**同一業務單元內**用 (5.12 情境 C) |
| 子資料可獨立存在,只是失去關聯 (書之於作者) | FK `ON DELETE SET NULL` | 保留子資料;欄位必須可空 |
| 刪父是重大操作,應該由人明確處理 (客戶之於訂單) | FK `ON DELETE RESTRICT` / `NO ACTION` (預設) | 強迫呼叫端先處理子資料;**跨業務邊界預設選這個** |
| 規則只看同一列的欄位 (`price > 0`、`end > start`) | `CHECK` | 便宜、宣告式、不會被繞過 |
| 規則要看其他表或其他列 (「庫存不能低於未出貨量」) | Trigger (第 12 章) | `CHECK` 不能參照其他表 |
| 規則會隨業務頻繁變動 (促銷條件、地區規則) | 應用程式驗證,DB 只擋底線 | 改 DB 約束要發版 + 鎖表;但「底線」(非負、非空) 仍放 DB |
| 欄位允許空,但非空時必須唯一 (選填的員工編號) | `UNIQUE` (預設 `NULLS DISTINCT`) | 多個 NULL 不算重複,正是要的行為 |
| 欄位允許空,且「空」只能有一筆 (每組織最多一個預設帳號) | `UNIQUE NULLS NOT DISTINCT` (PG 15+) 或部分唯一索引 | 預設行為會放行多個 NULL (5.12 情境 B) |
| 「同一條件下才唯一」(每人只能有一筆 active 訂閱) | 部分唯一索引 `CREATE UNIQUE INDEX ... WHERE status = 'active'` | 一般 UNIQUE 表達不了條件 |
| 固定的初始值 (`status = 'pending'`、`created_at = now()`) | `DEFAULT` | 宣告式、零成本 |
| 初始值要算 (依其他欄位決定、要查表) | Trigger `BEFORE INSERT` | `DEFAULT` 只能是與其他欄位無關的運算式 |
| 多筆寫入之間會暫時違反約束 (循環參照、先建子再建父) | `DEFERRABLE INITIALLY DEFERRED` | 檢查延到 COMMIT,交易內可以暫時不一致 |

### 上線時的考量

- **FK 欄位一定要建索引**:PostgreSQL 建 FK 時**不會**自動替子表的參照欄位建索引。沒索引時,每刪一筆父資料就要全掃子表確認沒人參照;`ON DELETE CASCADE` 更是每層全掃。這是「刪一筆要 30 秒」最常見的原因。
- **補約束會鎖表**:對既有表 `ADD CONSTRAINT` / `SET NOT NULL` 期間持有鎖並全表檢查,大表就是線上寫入卡住幾分鐘。用 `NOT VALID` 先掛上 (只檢查新資料) 再 `VALIDATE CONSTRAINT` (弱鎖) 分兩步做 (5.12 情境 D)。
- **先清資料再加約束**:約束加上去的那一刻會檢查全表,一筆髒資料就失敗。先用查詢找出違反的列 (5.12 情境 D 的查法),決定修正或排除,再加。
- **命名約束**:`CONSTRAINT chk_price CHECK (...)` 而不是匿名 — 錯誤訊息裡會出現約束名,應用程式可以據此對應到使用者看得懂的訊息;之後要 DROP 也不用先查系統自動取的名字。
- **CHECK 裡不要放昂貴或非 IMMUTABLE 的運算**:每次寫入都會執行;用 `now()` 之類的東西會讓「昨天合法的資料今天不合法」,`pg_dump` 還原時整批失敗。
- **驗證再收工**:約束加完,用 `pg_constraint.convalidated` 確認已驗證、故意塞一筆壞資料確認真的會被擋 (本章 `scripts/01` 就是這樣做的)。

## 5.3 約束 (Constraints) 總覽

| 約束 | 擋什麼 |
|------|------|
| `NOT NULL` | 沒有值就不准寫 |
| `DEFAULT` | (不是擋,是補) 沒給值時自動填 |
| `UNIQUE` | 同樣的值不准出現第二次 (NULL 例外,見 5.6) |
| `PRIMARY KEY` | = `UNIQUE` + `NOT NULL`,一張表只能有一個,是「這一列是誰」的定義 |
| `FOREIGN KEY` | 指向別張表的值必須真的存在 (參照完整性) |
| `CHECK` | 任意布林條件不成立就不准寫 |
| `EXCLUDE` | 進階:兩列在某種比較下 (範圍重疊、空間相交) 不准同時存在 |

## 5.4 PRIMARY KEY

**為什麼**:沒有主鍵的表,你無法可靠地指著「這一列」— `UPDATE ... WHERE name = 'Alice'` 可能改到兩個 Alice;FK 沒有東西可以參照;複寫 (logical replication) 與很多工具直接拒絕沒主鍵的表。每張表**強烈建議**有一個。

**怎麼做**:

```sql
-- 單欄主鍵 (代理鍵,推薦寫法;GENERATED ALWAYS 禁止手動塞 id,避免跟 sequence 打架)
CREATE TABLE a (
    id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ...
);

-- 多欄主鍵 (常見於關聯表:「這一列」由兩個欄位合起來定義)
CREATE TABLE order_items (
    order_id INT,
    line_no  INT,
    book_id  INT,
    qty      INT,
    PRIMARY KEY (order_id, line_no)
);
```

**自然鍵 vs 代理鍵** (決策見 5.2):
- **代理鍵 (Surrogate)**:`id INTEGER IDENTITY`,與業務無關。**推薦** — 業務識別碼再穩定也可能改 (公司合併、email 換了),代理鍵讓所有 FK 不受影響。
- **自然鍵 (Natural)**:如 `email`、`國碼+電話`。少一個欄位、JOIN 可讀;但業務變動時所有參照它的表都要跟著改,很痛苦。

## 5.5 FOREIGN KEY

**為什麼**:`orders.customer_id = 42` 只是個數字,沒有 FK 時 42 號客戶可以不存在、可以被刪掉,訂單就變成指向虛空的孤兒 — 報表 JOIN 不到、客服查不到、對帳對不上。FK 讓 PostgreSQL 保證「這個數字指向的東西一定存在」,而且在父資料被刪時**依你事先的決定**處理子資料。

**怎麼做**:

```sql
CREATE TABLE orders (
    id          SERIAL PRIMARY KEY,
    customer_id INT NOT NULL REFERENCES customers(id),
    ...
);
-- 或表級 (可以指定父表變動時的動作)
CREATE TABLE orders (
    id          SERIAL PRIMARY KEY,
    customer_id INT NOT NULL,
    FOREIGN KEY (customer_id) REFERENCES customers(id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT
);
```

**參考動作** — 這是 FK 最重要的決定,回答「父被刪/改時,子怎麼辦」:

| 動作 | 父表變動時 |
|------|-----------|
| `NO ACTION` (預設) | 在交易結尾時檢查;有子資料則錯誤 |
| `RESTRICT` | 立即檢查;有子資料則錯誤 |
| `CASCADE` | 連動刪除/更新子資料 |
| `SET NULL` | 子資料外鍵改為 NULL |
| `SET DEFAULT` | 子資料外鍵改為預設值 |

### 何時用 CASCADE / SET NULL?

- **CASCADE**:子資料「沒有父就沒意義」 (如 `order_items` 與 `orders`)。只在同一業務單元內用。
- **SET NULL**:子資料可獨立存在 (如 `books.author_id` 若作者被刪)。欄位必須可空。
- **RESTRICT**:保守,需要明確處理。跨業務邊界 (客戶 → 訂單) 預設選這個。

> ⚠️ 不要把 CASCADE 視為偷懶工具。CASCADE 會一層層往下傳,刪一筆 org 可能無聲地帶走幾萬筆 comments,而且 PostgreSQL 只回報最上層的 `DELETE 1` — 5.12 情境 C 會重現這件事,並示範刪之前怎麼看連鎖範圍。

> 💡 **FK 欄位記得建索引**:PostgreSQL 只在父表 (被參照端) 要求唯一索引,子表的 `customer_id` 不會自動有索引。沒索引時每次刪父都全掃子表。

## 5.6 UNIQUE

**為什麼**:「同一個 email 不能註冊兩次」這種規則如果只靠應用程式檢查 (先 SELECT 再 INSERT),兩個請求同時進來就會雙雙通過檢查、雙雙寫入 — 這是典型的 race condition。`UNIQUE` 由 PostgreSQL 在索引層原子地保證,不管多少並發都只會有一筆成功。

**怎麼做**:

```sql
-- 單欄
CREATE TABLE users (
    email VARCHAR(120) UNIQUE
);

-- 多欄組合:「同一人在同一組織只能有一筆」
CREATE TABLE memberships (
    org_id  INT,
    user_id INT,
    role    TEXT,
    UNIQUE (org_id, user_id)
);

-- 命名約束 (錯誤訊息會帶名字,方便對應與後續 DROP)
CREATE TABLE x (
    sku TEXT CONSTRAINT uq_sku UNIQUE
);
```

**UNIQUE 對 NULL 的態度**:SQL 標準裡 `NULL <> NULL`,所以預設 (`NULLS DISTINCT`) 允許多個 NULL 並存。這常常是你要的 (選填的員工編號可以很多人沒填);不是你要的時候,用 PG 15+ 的 `UNIQUE NULLS NOT DISTINCT`。同樣地,`'Alice@x.com'` 與 `'alice@x.com'` 是不同的字串 — 大小寫不敏感的唯一要對 `LOWER(email)` 建唯一索引。這兩個坑合起來就是 5.12 情境 B。

**部分唯一索引 (PostgreSQL 特色)**:某條件下才唯一 — 一般 UNIQUE 表達不了「只有 active 的才不能重複」。

```sql
-- 同一使用者只能有一筆 active 訂閱 (已取消的可以有很多筆)
CREATE UNIQUE INDEX uq_user_active_sub
    ON subscriptions(user_id)
    WHERE status = 'active';
```

## 5.7 CHECK

**為什麼**:很多規則只跟同一列自己有關 — 價格不能負、折扣價要低於原價、結束日不能早於開始日。這些規則寫在應用程式裡,每個寫入路徑 (API、後台、匯入腳本) 都要各寫一次,漏一個就漏了;寫成 `CHECK`,一次宣告、所有路徑都擋。

**怎麼做**:任意布林運算式,結果為 `FALSE` 時拒絕 (注意:`NULL` 視為通過,所以 `CHECK (price > 0)` 擋不住 `price IS NULL`,要另外 `NOT NULL`)。

```sql
CREATE TABLE products (
    id    SERIAL PRIMARY KEY,
    price NUMERIC(10,2) CHECK (price > 0),
    stock INT NOT NULL DEFAULT 0,
    CHECK (stock >= 0),

    -- 跨欄
    sale_price NUMERIC(10,2),
    CHECK (sale_price IS NULL OR sale_price < price)
);
```

> CHECK **不能參照其他資料表**,也不該放會變的東西 (`now()`)。要那種驗證請用 trigger (第 12 章)。

## 5.8 NOT NULL 與 DEFAULT

**為什麼**:NULL 是「沒有值」,它會讓 `=` 永遠不成立、讓 `count(col)` 少算、讓 `sum` 默默略過。每一個允許 NULL 的欄位,都是下游每一條查詢要多想一次「這裡會不會是 NULL」。反過來,`DEFAULT` 讓「大多數情況都一樣」的欄位不用每次都寫,也讓補欄位時既有資料有合理的值。

**怎麼做**:

```sql
CREATE TABLE events (
    id          BIGSERIAL PRIMARY KEY,
    payload     JSONB        NOT NULL,
    occurred_at TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    status      TEXT         NOT NULL DEFAULT 'pending'
);
```

**好習慣**:預設 `NOT NULL`,可空欄位請刻意設計,並在註解 (`COMMENT ON COLUMN`) 中說明「什麼情況下會是 NULL、代表什麼」。

## 5.9 修改既有資料表

**為什麼要特別講**:建新表時約束怎麼加都行,表是空的。對**已經有資料、正在被使用**的表做 `ALTER TABLE`,每一步都要問兩件事:(1) 既有資料符合新規則嗎?不符合就直接失敗 (5.12 情境 D);(2) 這個操作要鎖表多久?`ADD COLUMN` 帶常數 `DEFAULT` 是瞬間的,但改型別、加 `NOT NULL`、加 FK 都會全表掃描,期間寫入卡住。

**怎麼做**:

```sql
-- 加欄位 (帶常數 DEFAULT 不需重寫表,PG 11+)
ALTER TABLE books ADD COLUMN summary TEXT;

-- 改型別 (有時需 USING;會重寫整張表,大表要排維護窗口)
ALTER TABLE books ALTER COLUMN price TYPE NUMERIC(12,2);
ALTER TABLE events ALTER COLUMN payload TYPE JSONB USING payload::jsonb;

-- 加/移除預設值 (只影響之後的寫入,瞬間完成)
ALTER TABLE books ALTER COLUMN stock SET DEFAULT 0;
ALTER TABLE books ALTER COLUMN stock DROP DEFAULT;

-- 加 NOT NULL (會掃全表確認沒有 NULL;有就失敗)
ALTER TABLE books ALTER COLUMN price SET NOT NULL;

-- 加約束 (會掃全表檢查;大表用 NOT VALID + VALIDATE 分兩步,見 5.12 情境 D)
ALTER TABLE books ADD CONSTRAINT chk_price CHECK (price >= 0);
ALTER TABLE books DROP CONSTRAINT chk_price;

-- 改欄位名
ALTER TABLE books RENAME COLUMN summary TO description;

-- 改表名
ALTER TABLE books RENAME TO books_v1;

-- 改 schema
ALTER TABLE shop.books SET SCHEMA archive;

-- 刪除欄位
ALTER TABLE books DROP COLUMN description;

-- 刪除表
DROP TABLE books;
DROP TABLE books CASCADE;   -- 連同依賴的 view/FK 一起刪
```

## 5.10 暫時表 (Temporary Tables)

**為什麼**:ETL 或複雜查詢常需要「先算一個中間結果放著,後面幾步都用它」。用正式表要取名、要清理、多個 session 會互相干擾;暫時表只在當前 session 存在,session 結束自動消失,別人看不到、也不會留垃圾。

**怎麼做**:

```sql
CREATE TEMP TABLE staging AS
SELECT * FROM shop.orders WHERE status = 'pending';

-- 或顯式
CREATE TEMPORARY TABLE staging (
    id INT,
    payload JSONB
) ON COMMIT DROP;     -- 交易結束就刪
```

## 5.11 IDENTITY 重排與 Sequence

**為什麼要知道**:`IDENTITY` / `SERIAL` 背後是 sequence,它的設計目標是「保證不重複」而**不是**「保證連號」。失敗的 INSERT、ROLLBACK 的交易、多個 session 同時取號,都會讓號碼跳過去 — 這是正常行為,不是資料遺失。批量匯入指定了 id 之後,sequence 不知道,下一次自動取號就會撞 `duplicate key`,所以要手動重設。

**怎麼做**:

```sql
-- 看 sequence 當前值
SELECT pg_get_serial_sequence('shop.books','id');
SELECT last_value FROM shop.books_id_seq;

-- 重設 (在批量匯入後常用;設成目前最大 id + 1)
ALTER SEQUENCE shop.books_id_seq RESTART WITH 1000;

-- 跳號示範
INSERT INTO shop.categories (name) VALUES ('Test');
ROLLBACK;          -- sequence 不會回退,下次仍是下一號
```

### 完整範例

把本章的東西合在一起 — 一張「上線等級」的表長這樣:每個欄位都決定了可不可空、有沒有預設、約束都有名字、欄位有註解。

```sql
DROP TABLE IF EXISTS demo_products CASCADE;
CREATE TABLE demo_products (
    id          INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku         VARCHAR(30) NOT NULL,
    name        TEXT        NOT NULL,
    price       NUMERIC(10,2) NOT NULL,
    stock       INT         NOT NULL DEFAULT 0,
    category_id INT REFERENCES shop.categories(id) ON DELETE SET NULL,
    metadata    JSONB       NOT NULL DEFAULT '{}'::jsonb,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_demo_sku UNIQUE (sku),
    CONSTRAINT chk_price   CHECK (price >= 0),
    CONSTRAINT chk_stock   CHECK (stock >= 0)
);

COMMENT ON TABLE  demo_products       IS '示範:完整定義的產品表';
COMMENT ON COLUMN demo_products.sku   IS '商品料號 (對外公開)';
COMMENT ON COLUMN demo_products.stock IS '當前可售庫存,扣除預留';
```

## 5.12 問題排查:情境模擬與排查順序

**為什麼要練這個**:約束相關的問題分兩類,排查方向完全相反 — (1) **約束擋了你**:錯誤訊息很明確,但「該改資料還是該改約束」需要判斷;(2) **約束沒擋到**:沒有任何錯誤,壞資料默默進來,發現時已經一堆。能不能快速分辨是哪一類、並找出所有受影響的資料,比背語法重要。

> 🧪 所有情境都在 [`scripts/03-troubleshooting-scenarios.sql`](./scripts/03-troubleshooting-scenarios.sql) 裡,用自己的 demo 表 (前綴 `ts_`),跑完自動清掉。建議一段一段執行,對照下面的說明。情境 D 會刻意出現 2 個 ERROR。

### 通用排查順序:「約束擋了 / 約束沒擋到」

順序的邏輯是**先讀錯誤、再查定義、再看資料、最後才動手改**:

```
1. 讀完整的錯誤訊息,包括 DETAIL 那一行
   → 約束名、哪張表、哪個 key;psql 預設會印,應用程式的 log 常常只留第一行
2. 查約束的實際定義 (不要憑印象)
   → \d 表名;或 pg_constraint + pg_get_constraintdef()
3. 這個約束是在保護誰?
   → FK:誰參照這張表 (pg_constraint.confrelid);CASCADE 會傳到哪一層
4. 看資料:受影響的到底有幾筆、是哪些
   → 違反 FK 的孤兒列、被 UNIQUE 放行的「業務上重複」、NULL 有幾筆
5. 判斷:是資料錯、還是約束定義跟業務規則不一致?
   → 資料錯 → 修資料;定義不一致 → 改約束 (先清資料,否則新約束建不起來)
6. 大表改約束,先評估鎖
   → NOT VALID + VALIDATE;離峰;交易內先試跑再 ROLLBACK
7. 驗證:故意塞一筆壞資料確認真的被擋;pg_constraint.convalidated = true
```

### 情境 A:DELETE 父資料被擋 — `violates foreign key constraint`

**症狀**:客服要刪一位作者,得到 `ERROR: update or delete on table "ts_authors" violates foreign key constraint "ts_books_author_id_fkey" on table "ts_books"`。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | 讀 DETAIL | `Key (id)=(1) is still referenced from table "ts_books"` — 誰、哪個值、被誰參照,一行講完 |
| 2 | 錯誤只列**第一個**擋住的 FK;查 `pg_constraint WHERE confrelid = 'ts_authors'::regclass` 列出**所有**參照這張表的子表 | `ts_books_author_id_fkey` → `FOREIGN KEY (author_id) REFERENCES ts_authors(id)`,沒有 `ON DELETE` 子句 = 預設 `NO ACTION` |
| 3 | 算子資料有幾筆 | `dependent_books = 2` |

**根因**:FK 預設 `ON DELETE NO ACTION` — 有子資料就拒絕。**這是約束在保護你,不是 bug**。真正該問的是業務問題:「刪作者時,他的書該怎麼辦?」答案決定修法。

**修正** (三選一,依業務答案):
1. 書應保留、只是沒有作者 → FK 改 `ON DELETE SET NULL` (欄位要先 `DROP NOT NULL`)
2. 書沒有作者就沒意義 → `ON DELETE CASCADE` — 但先看情境 C
3. 保守 → 不改 FK,應用程式先處理子資料再刪;或改軟刪除 (`deleted_at`)

**驗證**:改成 `SET NULL` 後 `DELETE FROM ts_authors WHERE id = 1` 成功,`ts_books` 仍有 3 列、其中 2 列 `author_id = NULL`。

### 情境 B:明明有 UNIQUE,資料還是重複了

**症狀**:`email` 有 `UNIQUE`,報表卻出現同一個人兩筆;`sku` 也有 `UNIQUE`,卻有多筆「空的」。沒有任何錯誤訊息。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | 確認約束真的存在 (`pg_constraint ... contype = 'u'`) | `UNIQUE (email)`、`UNIQUE (sku)` — 都在 |
| 2 | 用「**業務上的相等**」找重複:`GROUP BY LOWER(email) HAVING count(*) > 1` | `alice@example.com \| 2` — `alice@` 與 `Alice@` 各一筆 |
| 3 | 數 NULL | `null_emails = 2, null_skus = 2` |

**根因**:`UNIQUE` 比的是「值完全相等」。(1) `'alice'` 與 `'Alice'` 是不同字串;(2) SQL 標準裡 `NULL` 不等於任何值 (含 `NULL`),所以多個 NULL 不算重複。**約束沒壞,是它定義的「唯一」跟業務想的不一樣** — 通用順序第 5 步的第二種情況。

**修正** (先清資料,否則新約束建不起來):
- 大小寫不敏感 → `CREATE UNIQUE INDEX ... ON ts_users (LOWER(email))` (或用 `citext` 型別)
- NULL 也要視為同一值 → `ALTER TABLE ... ADD CONSTRAINT ... UNIQUE NULLS NOT DISTINCT (sku)` (PG 15+)

**驗證**:再塞 `'ALICE@example.com'` → `duplicate key value violates unique constraint "uq_ts_users_email_ci"`;再塞第二個 `NULL` sku → `violates unique constraint "ts_users_sku_key"`。

### 情境 C:刪一筆,消失了幾千筆 — CASCADE 連鎖範圍超出預期

**症狀**:刪除一個「測試用組織」,結果 `tasks` 與 `comments` 少了一大片。PostgreSQL 只回了 `DELETE 1`,沒有任何警告。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | **刪之前**用遞迴查詢走 `pg_constraint`,列出 CASCADE 鏈 | `ts_orgs → ts_projects (CASCADE) → ts_tasks (CASCADE) → ts_comments (CASCADE)` 三層 |
| 2 | 在交易裡試刪,比對各表列數,然後 `ROLLBACK` | projects 20→10、tasks 2000→1000、comments 10000→5000:**刪 1 筆 org 帶走 6010 筆** |

**根因**:每一層 FK 都是 `ON DELETE CASCADE`,連鎖會一路傳到底;PostgreSQL 的 `DELETE n` 只算最上層那張表,連鎖刪掉的列數不會出現在任何訊息裡。CASCADE 在「訂單 → 明細」這種同一業務單元內是對的,跨到「組織 → 專案」這種業務邊界就危險了 (5.2 決策表)。

**修正**:在跨業務邊界的那一層改用 `ON DELETE RESTRICT`,強迫呼叫端明確處理 (先歸檔、先確認、或改軟刪除)。

**驗證**:再刪 org → `violates foreign key constraint "ts_projects_org_id_fkey"`,三張表列數不變。

**延伸**:任何 `DELETE` 之前,對不熟的表先跑步驟 1 的遞迴查詢;或養成 `BEGIN; DELETE ...; SELECT count(*) ...; ROLLBACK;` 先看再做的習慣。

### 情境 D:對既有大表補約束失敗 — 髒資料與鎖表

**症狀**:表上線時沒加 FK 與 `NOT NULL`,現在想補。`ALTER TABLE ... ADD CONSTRAINT ... FOREIGN KEY` 報 `violates foreign key constraint ... Key (category_id)=(999) is not present in table "categories"`;`SET NOT NULL` 報 `column "sku" of relation "ts_products" contains null values`。而且每次嘗試都鎖住整張表。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | 找孤兒列:`LEFT JOIN 父表 ... WHERE 父.id IS NULL`,依值分組 | `category_id = 999 \| orphan_rows = 200` — 20 萬列中 0.1% 指向不存在的分類 |
| 2 | 數 NULL | `null_skus = 40` |
| 3 | 評估鎖:`ADD CONSTRAINT` 要全表檢查並持有 `SHARE ROW EXCLUSIVE` 鎖 | 20 萬列還好;2 億列就是線上寫入卡好幾分鐘 |

**根因**:約束只在「加上去的那一刻」對全表檢查一次,既有髒資料一筆就失敗;而且檢查期間鎖表。兩個問題要分開解。

**修正**:
1. **先修資料**:孤兒改指向合理值或 `NULL`;NULL 的 sku 補值 (`'UNKNOWN-' || id`)
2. **FK 分兩步**:`ADD CONSTRAINT ... NOT VALID` (只檢查之後的新資料,幾乎不鎖,實測 1.4ms) → `VALIDATE CONSTRAINT` (只取 `SHARE UPDATE EXCLUSIVE` 鎖,線上讀寫不受影響,實測 10.9ms)
3. **NOT NULL 同樣可以過渡**:先 `ADD CONSTRAINT ... CHECK (sku IS NOT NULL) NOT VALID` → `VALIDATE` → `SET NOT NULL` (PG 12+ 看到已驗證的 CHECK 就不再掃表) → `DROP` 那個 CHECK

**驗證**:`pg_constraint` 顯示 `ts_products_category_fkey | f | convalidated = t`;`pg_attribute.attnotnull = t`。

## 章節腳本

- [`scripts/01-create-with-constraints.sql`](./scripts/01-create-with-constraints.sql) — 建立含完整約束的表,並驗證約束真的會擋
- [`scripts/02-alter-table.sql`](./scripts/02-alter-table.sql) — ALTER TABLE 各種變更
- [`scripts/03-troubleshooting-scenarios.sql`](./scripts/03-troubleshooting-scenarios.sql) — 5.12 四個排查情境 (可重現)

---

下一章 ➡ [第 6 章:基本 SQL — CRUD](../06-crud-basic-sql/)
