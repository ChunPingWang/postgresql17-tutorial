# 第 12 章 觸發器 (Trigger)

> 目標:理解 trigger 解決什麼問題、**什麼時候不該用 trigger**、各種時機/粒度的選擇依據,並能有系統地排查「trigger 造成的怪現象」— 資料默默消失、批次變慢、無限遞迴、衍生欄位對不上。
>
> 🧰 **前置準備**:本章範例使用 `bookstore` 資料庫 (`shop` schema 與範例資料)。尚未建立的話,先在 repo 根目錄執行 `psql -d postgres -f setup/01-create-tutorial-db.sql` 與 `psql -d bookstore -f setup/02-sample-data.sql`,詳見[第 1 章 1.8 節](../01-installation/README.md#18-建立教學用資料庫)。
>
> 📐 **本章讀法**:每一節都先講「為什麼會需要這個」,再講「怎麼做」。12.2 是動手前的決策清單,12.12 是五個可以實際重現的故障情境與排查順序 — 建議先讀 12.1~12.2 建立判斷框架,再看範例。

## 12.1 為什麼需要 Trigger

**沒有 trigger 時會發生什麼**:有些規則是「只要資料改了,就一定要跟著做的事」— 改了 `books` 就要更新 `updated_at`、改了 `order_items` 就要重算 `orders.total`、任何人改價格都要留一筆稽核。這些邏輯如果寫在應用程式裡,問題是**進資料庫的路不只一條**:後台工具、批次腳本、DBA 手動 `UPDATE`、另一個團隊的服務 — 任何一條路忘了做,資料就不一致,而且沒有人會收到錯誤。

**Trigger 怎麼解決**:把規則綁在**資料表本身**。不管誰、用什麼工具、走哪條路寫入,規則都會執行。這是 trigger 唯一真正不可替代的價值:**強制一致性,不依賴呼叫端自律**。

**但 trigger 有明顯代價**,這是整章的核心矛盾:

- 它是**隱形的**:應用程式開發者看 `INSERT` 一行,不會知道背後跑了三個 function;出問題時第一個被懷疑的永遠不是 trigger (12.12 情境 A)
- 每一列都要付出成本:row-level trigger 在批次匯入時可能讓寫入慢好幾倍 (12.12 情境 B)
- 邏輯散落在資料庫裡,難測試、難版本控制、難 code review

所以「這條規則要不要用 trigger、用哪一種」是**取捨**,下一節就是做這個取捨的清單。

### Trigger 的組成

![建立 TRIGGER 範例](./screenshots/02-create-trigger.png)

一個 trigger 由兩部分組成,分開的原因是**一個 function 可以被多張表、多個 trigger 重用** (例如 12.6 的稽核 function):

1. **Trigger function**:`RETURNS TRIGGER`,描述要做什麼
2. **Trigger 本身**:綁定到表 + 事件 + 條件

```sql
CREATE OR REPLACE FUNCTION fn_xxx() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN ... END $$;

CREATE TRIGGER trg_xxx
BEFORE INSERT OR UPDATE ON some_table
FOR EACH ROW EXECUTE FUNCTION fn_xxx();
```

## 12.2 設計前的決策條件與考量重點

**為什麼要先想再建**:trigger 建錯不會報錯,只會讓系統默默變慢、資料默默不對,而且因為它是隱形的,事後排查的成本特別高 —「為什麼 INSERT 成功了資料卻不在」這種問題,可以耗掉一個團隊一整天 (12.12 情境 A)。建之前先回答下面幾個問題。

### 先確認的前提

| 問題 | 為什麼重要 | 怎麼確認 |
|------|-----------|---------|
| **這條規則真的「所有寫入路徑」都要遵守嗎?** | 這是 trigger 唯一不可替代的理由。如果寫入只有一個服務、一條路,放在應用程式層更好測、更看得見 | 列出所有會寫這張表的程式/腳本/人;超過一個 → trigger 有理由 |
| **能不能用更便宜的機制取代?** | 約束 (CHECK / FK / UNIQUE)、`DEFAULT`、`GENERATED ... STORED` 欄位都是宣告式的,planner 看得懂、沒有 PL/pgSQL 開銷、不會遞迴 | 規則能用一個運算式表達 → 用 generated column / CHECK;需要查別的表或寫別的表 → 才是 trigger |
| **這張表的寫入量與批次模式?** | row-level trigger 是「每列呼叫一次 function」,20 萬列的批次匯入就是 20 萬次呼叫 | `pg_stat_user_tables.n_tup_ins/upd`;有沒有 COPY / ETL / 大量 UPDATE 的作業 |
| **要改「這一列」還是「別的地方」?** | 決定 BEFORE 還是 AFTER (見下表);選錯會導致遞迴或改不到 | 只改 NEW 自己的欄位 → BEFORE;要寫別張表 → AFTER |
| **衍生資料可以事後算嗎?** | 用 trigger 維護衍生欄位 (總額、計數) 一旦事件漏綁就會飄 (12.12 情境 D);讀取時算或用 view/materialized view 可能更穩 | 讀取頻率 ≫ 寫入且算得慢 → trigger 維護;否則讀時算 |
| **稽核需求的規模?** | 每列寫一筆 JSONB 稽核的 trigger,在高寫入表上是顯著成本;大規模稽核有 logical decoding (`wal2json`、pgoutput) 這種零侵入的替代方案 | 稽核表成長速度、是否需要跨表/跨庫收集 |

### 決策對照:什麼情況選什麼

| 需求長這樣 | 選擇 | 理由 |
|-----------|------|------|
| 欄位值能由同一列其他欄位算出 (`total = qty * price`) | `GENERATED ALWAYS AS (...) STORED`,不用 trigger | 宣告式、永遠一致、沒有 PL/pgSQL 開銷 |
| 「插入時沒給就用某值」 | `DEFAULT`,不用 trigger | 同上;`DEFAULT NOW()`、`DEFAULT gen_random_uuid()` 都夠用 |
| 「這個值不能超出範圍 / 不能是這幾種」 | `CHECK` 約束,不用 trigger | 約束是 planner 可見的、錯誤訊息標準、不會被 `DISABLE TRIGGER` 繞過 |
| 要驗證或修改**正在寫入的這一列** (正規化、`updated_at`、跨欄位驗證需要查別表) | `BEFORE ... FOR EACH ROW`,改 `NEW` 後 `RETURN NEW` | 資料還沒落地,直接改 NEW 就好,不需要第二次 UPDATE (12.12 情境 C) |
| 要在寫入**之後**去動別的表 (稽核、重算彙總、發通知) | `AFTER ... FOR EACH ROW` | 此時這一列已確定寫入 (含其他 BEFORE trigger 與約束檢查都過了) |
| 批次操作為主、要一次處理整批變動 | `AFTER ... FOR EACH STATEMENT` + `REFERENCING NEW/OLD TABLE` (transition table) | 一個 statement 呼叫一次,用 set-based SQL 處理整批,比 row-level 快數倍 (12.12 情境 B) |
| 讓帶 JOIN / 聚合的 view 可以被寫入 | `INSTEAD OF` trigger (僅 view) | view 沒有底層列可改,只能由 trigger 決定怎麼拆到底表 (12.10) |
| 只有某幾個欄位變動才需要跑 | `UPDATE OF col1, col2` + `WHEN (NEW.x IS DISTINCT FROM OLD.x)` | 減少不必要的 function 呼叫;`WHEN` 在 function 之外評估,更便宜 |
| 稽核所有變更、量大、不想影響寫入延遲 | logical decoding / CDC,或 statement-level trigger 批次寫 | row-level 稽核 trigger 在高寫入表上是明顯成本 |
| 阻止某種操作 (禁止降價、禁止刪除歷史資料) | `BEFORE` trigger `RAISE EXCEPTION`;或用權限 (`REVOKE DELETE`) | 能用權限解決的優先用權限;需要看資料內容才能判斷的才用 trigger |

### 上線與實務考量

- **Trigger 是隱形的,一定要留線索**:function 與 trigger 都加 `COMMENT ON`,命名用 `trg_` 前綴,在表的文件或 schema migration 裡明列;新同事第一次看到「INSERT 0 0」不會想到 trigger。
- **BEFORE ROW 的回傳值就是「要寫入的那一列」**:`RETURN NULL` = 跳過這列且**不報錯**;`RETURN OLD` = 用舊值覆蓋這次 UPDATE。這是最常見、最難察覺的 trigger bug (12.12 情境 A)。
- **同表同時機的多個 trigger 依名稱字典序執行**,不是建立順序;有順序需求就用 `trg_10_`、`trg_20_` 這種前綴 (12.12 情境 E)。
- **Trigger 內寫同一張表會遞迴**:AFTER UPDATE 裡再 UPDATE 自己 → 無限遞迴到 `stack depth limit exceeded`。要改自己這一列用 BEFORE 改 NEW;真的要 AFTER 就用 `WHEN (pg_trigger_depth() = 0)` 擋 (12.12 情境 C)。
- **批次匯入 / 資料搬遷前評估要不要暫停 trigger**:`ALTER TABLE ... DISABLE TRIGGER trg_x` 或整個 session `SET session_replication_role = replica` (停用所有非 ALWAYS trigger,含 FK 檢查 — 要很清楚後果);停用期間漏掉的衍生資料事後要回填 (12.12 情境 B、D)。
- **`TRUNCATE` 不會觸發 row-level 的 INSERT/UPDATE/DELETE trigger**:依賴 DELETE trigger 做稽核或清理的設計,遇到 TRUNCATE 會靜靜漏掉;需要的話另外綁 `AFTER TRUNCATE FOR EACH STATEMENT`。
- **Trigger 在同一個交易內執行**:trigger 失敗 = 整個 statement 失敗;trigger 慢 = 每次寫入都慢,鎖也拿得更久。不要在 trigger 裡做外部呼叫、`pg_sleep`、大範圍 UPDATE。
- **可測試性**:trigger 的邏輯放在 function,function 可以獨立用測試表驗證;部署 trigger 的 migration 要能 rollback (`DROP TRIGGER IF EXISTS`)。
- **修 trigger 不會修歷史資料**:事件漏綁、邏輯錯誤期間寫入的資料,要另外寫對帳查詢找出來並回填 (12.12 情境 D)。

## 12.3 Trigger 屬性

**為什麼有這麼多維度**:trigger 的本質是「在**什麼時機**、對**哪種事件**、以**什麼粒度**、在**什麼條件下**執行 function」。四個維度各自回答不同問題,選錯任何一個都會出現 12.12 裡的故障。

| 維度 | 選項 | 怎麼選 |
|------|------|--------|
| 時機 | `BEFORE` / `AFTER` / `INSTEAD OF` (僅 view) | 改這一列自己 → BEFORE;動別的表 → AFTER;view → INSTEAD OF |
| 事件 | `INSERT` / `UPDATE` / `DELETE` / `TRUNCATE` | 維護衍生資料要**三個都綁** (`INSERT OR UPDATE OR DELETE`),漏一個就會飄 |
| 粒度 | `FOR EACH ROW` / `FOR EACH STATEMENT` | 需要 NEW/OLD 單列值 → ROW;批次為主 → STATEMENT + transition table |
| 過濾 | `WHEN (condition)` / `OF column_list` | 能用 WHEN/OF 擋掉的就不要進 function,便宜很多 |
| 順序 | 同表多 trigger 按**名稱字典序**執行 | 有先後需求用數字前綴命名 |

> `TRUNCATE` 是獨立事件,**不會**觸發 row-level 的 DELETE trigger;要攔 TRUNCATE 得另外寫 `AFTER TRUNCATE ... FOR EACH STATEMENT`。

## 12.4 函數內可用變數

**為什麼需要這些變數**:同一個 trigger function 可能綁在多張表、多種事件上 (12.6 的通用稽核 function 就是),function 執行時必須能知道「我現在是被誰、因為什麼事件叫起來的」,以及「變動前後的列長什麼樣」。

```text
NEW         INSERT/UPDATE 的「新值」(DELETE 時為 NULL)
OLD         UPDATE/DELETE 的「舊值」(INSERT 時為 NULL)
TG_OP       'INSERT' / 'UPDATE' / 'DELETE' / 'TRUNCATE'
TG_TABLE_NAME, TG_TABLE_SCHEMA, TG_NAME, TG_WHEN, TG_LEVEL
```

**回傳值規則 (最重要,也最常寫錯)**:
- `BEFORE ROW` 回 NULL → **該列不執行,而且不報錯**
- `BEFORE ROW` 回 NEW → 用此值繼續 (可以先修改 NEW 的欄位)
- `BEFORE ROW` 回 OLD → 用舊值繼續,等於這次 UPDATE 被丟掉
- `AFTER` / `STATEMENT` → 回 NULL 即可,值不重要

## 12.5 範例 A:自動維護 `updated_at`

**為什麼**:「最後修改時間」這種欄位,靠應用程式每次 UPDATE 都記得帶 `updated_at = NOW()` 是不可靠的 — 任何一個 ORM 設定、任何一支維運腳本漏了,這個欄位就開始說謊。

**怎麼做**:`BEFORE UPDATE` 直接改 `NEW.updated_at` 再 `RETURN NEW`。用 BEFORE 而不是 AFTER,是因為資料還沒落地、改 NEW 就好,不需要再發一次 UPDATE (那會遞迴,12.12 情境 C)。

```sql
CREATE OR REPLACE FUNCTION shop.fn_touch_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_books_updated_at
BEFORE UPDATE ON shop.books
FOR EACH ROW EXECUTE FUNCTION shop.fn_touch_updated_at();
```

## 12.6 範例 B:稽核 (Audit Log)

**為什麼**:「這筆價格是誰、什麼時候、從多少改成多少」— 這種問題出現時,通常已經來不及回頭記錄。稽核必須在變更發生的**當下**、對**所有路徑**都生效,這正是 trigger 的強項。

**怎麼做**:`AFTER INSERT OR UPDATE OR DELETE`,把 `OLD` / `NEW` 用 `to_jsonb()` 整列存下來。用 AFTER 是因為要等這一列確定寫入 (所有 BEFORE trigger 與約束都過了) 才記;用 JSONB 是為了同一個 function 能綁在任何表上,不用為每張表寫一份。

```sql
CREATE TABLE IF NOT EXISTS shop.audit_log (
    id          BIGSERIAL PRIMARY KEY,
    table_name  TEXT NOT NULL,
    op          TEXT NOT NULL,
    old_data    JSONB,
    new_data    JSONB,
    changed_by  TEXT DEFAULT CURRENT_USER,
    changed_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION shop.fn_audit_books()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO shop.audit_log(table_name, op, old_data, new_data)
    VALUES (
        TG_TABLE_NAME,
        TG_OP,
        CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) END,
        CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) END
    );
    RETURN COALESCE(NEW, OLD);   -- AFTER 不重要,但要回非 NULL
END;
$$;

CREATE TRIGGER trg_audit_books
AFTER INSERT OR UPDATE OR DELETE ON shop.books
FOR EACH ROW EXECUTE FUNCTION shop.fn_audit_books();
```

> 高寫入量的表,row-level 稽核是每列一次 INSERT 的成本;12.9 的 statement-level 寫法或 CDC 是替代方案 (12.12 情境 B 有量測)。

## 12.7 範例 C:防止非法更新

**為什麼**:「價格不可降低」這種規則,如果要看**舊值與新值的關係**才能判斷,`CHECK` 約束做不到 (CHECK 只看新的那一列);用權限也做不到 (同一個人可以漲價但不能降價)。這時才輪到 trigger。

**怎麼做**:`BEFORE UPDATE OF price` 限定只有 price 變動才觸發,`WHEN (NEW.price <> OLD.price)` 再過濾一次 — 兩層過濾都在進 function 之前,便宜。不合規則就 `RAISE EXCEPTION`,整個 statement 回滾。

```sql
CREATE OR REPLACE FUNCTION shop.fn_no_lower_price()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.price < OLD.price THEN
        RAISE EXCEPTION '價格不可降低 (% → %)', OLD.price, NEW.price;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_books_no_lower
BEFORE UPDATE OF price ON shop.books        -- 只對 price 變動觸發
FOR EACH ROW
WHEN (NEW.price <> OLD.price)               -- 額外條件
EXECUTE FUNCTION shop.fn_no_lower_price();
```

## 12.8 範例 D:維護衍生欄位 (訂單總額)

**為什麼**:`orders.total` 可以每次讀取時 `SUM(order_items)` 算出來,但訂單列表頁每次都要 JOIN 明細加總,量大時很慢;存起來讀得快,代價是**明細一動就要跟著改**。這種「寫入時多做一點、讀取時省很多」的取捨,是用 trigger 維護衍生欄位的典型理由。

**怎麼做**:`AFTER INSERT OR UPDATE OR DELETE ON order_items` — 三個事件**都要綁**,漏任何一個 total 就會飄 (12.12 情境 D 示範漏綁的後果與對帳方法)。用 AFTER 是因為要動的是**另一張表** (orders),不是正在寫的這一列。`COALESCE(NEW.order_id, OLD.order_id)` 讓同一個 function 同時處理 INSERT (只有 NEW) 與 DELETE (只有 OLD)。

```sql
CREATE OR REPLACE FUNCTION shop.fn_update_order_total()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_order_id INT := COALESCE(NEW.order_id, OLD.order_id);
BEGIN
    UPDATE shop.orders SET total = COALESCE((
        SELECT SUM(quantity * unit_price)
        FROM shop.order_items
        WHERE order_id = v_order_id
    ), 0)
    WHERE id = v_order_id;
    RETURN NULL;  -- AFTER trigger,回值不重要
END;
$$;

CREATE TRIGGER trg_order_items_total
AFTER INSERT OR UPDATE OR DELETE ON shop.order_items
FOR EACH ROW EXECUTE FUNCTION shop.fn_update_order_total();
```

> 如果 UPDATE 會改 `order_id` (明細搬到另一張訂單),NEW 與 OLD 的 order_id 不同,兩張訂單都要重算 — 上面的簡化版只算一張,是刻意留給讀者的思考題。

## 12.9 STATEMENT-LEVEL Trigger 與 Transition Tables

**為什麼**:row-level trigger 是「每一列呼叫一次 function」。一次 COPY 進 20 萬列,就是 20 萬次 PL/pgSQL 呼叫加 20 萬次單列 INSERT,固定開銷被放大 20 萬倍 (12.12 情境 B 實測:20 萬列從 0.37 秒變 0.91 秒,其中 0.58 秒都在 trigger 裡)。批次為主的表,需要「一個 statement 只呼叫一次、一次處理整批」的機制。

**怎麼做**:`FOR EACH STATEMENT` + `REFERENCING NEW TABLE AS ...` (PG 10+):transition table 是這個 statement 影響的所有列的暫時表,可以直接 `INSERT ... SELECT FROM new_rows`,一次寫完。

```sql
CREATE OR REPLACE FUNCTION shop.fn_bulk_audit()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO shop.audit_log(table_name, op, new_data)
    SELECT TG_TABLE_NAME, 'BULK_INSERT', to_jsonb(n)
    FROM new_rows n;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_bulk
AFTER INSERT ON shop.books
REFERENCING NEW TABLE AS new_rows
FOR EACH STATEMENT EXECUTE FUNCTION shop.fn_bulk_audit();
```

## 12.10 INSTEAD OF Trigger (僅 View)

**為什麼**:帶 JOIN 的 view 沒有「對應的底層列」,PostgreSQL 不知道 `INSERT INTO v_book_with_author` 該把 `author_name` 寫去哪裡,所以預設直接拒絕。但對使用者來說,「透過一個好懂的 view 寫入」常常比直接操作三張表友善 — 這時需要有人告訴 PostgreSQL「遇到對 view 的寫入,**改成**做這些事」。

**怎麼做**:`INSTEAD OF INSERT ON view`,在 function 裡自己決定怎麼拆到底表 (先找作者、沒有就建、再插書)。注意 `RETURNING id INTO NEW.id` 讓呼叫端的 `RETURNING` 也拿得到新 id。

```sql
CREATE VIEW shop.v_book_with_author AS
SELECT b.id, b.title, a.name AS author_name
FROM shop.books b JOIN shop.authors a ON a.id = b.author_id;

CREATE OR REPLACE FUNCTION shop.fn_v_book_insert()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_author_id INT;
BEGIN
    SELECT id INTO v_author_id FROM shop.authors WHERE name = NEW.author_name;
    IF NOT FOUND THEN
        INSERT INTO shop.authors(name) VALUES (NEW.author_name) RETURNING id INTO v_author_id;
    END IF;
    INSERT INTO shop.books(title, author_id, price)
    VALUES (NEW.title, v_author_id, 0)
    RETURNING id INTO NEW.id;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_v_book_ins
INSTEAD OF INSERT ON shop.v_book_with_author
FOR EACH ROW EXECUTE FUNCTION shop.fn_v_book_insert();
```

## 12.11 管理 Trigger

**為什麼要會這些**:trigger 是隱形的,排查任何「資料怪怪的」問題,第一步都是**列出這張表上有哪些 trigger**;批次匯入、資料修復時則需要暫時關掉再打開。

```sql
-- 列出 (information_schema 版本,好讀)
SELECT trigger_name, event_manipulation, action_timing, action_statement
FROM information_schema.triggers
WHERE event_object_schema = 'shop';

-- 列出 (pg_trigger 版本,能看到是否停用、綁哪個 function)
SELECT tgrelid::regclass AS table_name, tgname, tgenabled, tgfoid::regproc AS function_name
FROM pg_trigger
WHERE NOT tgisinternal
ORDER BY 1, 2;

-- 暫停 / 啟用
ALTER TABLE shop.books DISABLE TRIGGER trg_audit_books;
ALTER TABLE shop.books ENABLE  TRIGGER trg_audit_books;
ALTER TABLE shop.books DISABLE TRIGGER ALL;     -- 全部 (含 FK 的內部 trigger,小心)

-- 刪除
DROP TRIGGER trg_audit_books ON shop.books;
```

`tgenabled` 的值:`O` = 啟用 (origin)、`D` = 停用、`R` = 只在 replica 模式執行、`A` = 永遠執行。看到 `D` 就知道有人停過沒開回來。

## 12.12 問題排查:情境模擬與排查順序

**為什麼要練這個**:trigger 相關的問題有個共同特徵 — **應用程式那一層看不到 trigger**。錯誤訊息裡沒有它、程式碼裡沒有它、`INSERT 0 0` 也不算錯誤。能不能想到「這張表上是不是有 trigger」並有系統地檢查,比背語法重要得多。

> 🧪 所有情境都在 [`scripts/04-troubleshooting-scenarios.sql`](./scripts/04-troubleshooting-scenarios.sql) 裡,用自己的 `demo_*` 表與 trigger,跑完自動清掉,不會碰 `shop.*` 表上既有的 trigger。建議一段一段執行,對照下面的說明。情境 C、E 會刻意觸發錯誤,但已包在 `DO ... EXCEPTION` 裡。

### 通用排查順序:「資料不對 / 寫入怪怪的」

順序的邏輯是**先確認有沒有 trigger、再看它做了什麼、最後才改**:

```
1. 這張表上有哪些 trigger?哪些是啟用的?
   → SELECT ... FROM pg_trigger WHERE tgrelid = 'tbl'::regclass AND NOT tgisinternal
     (看 tgname / tgenabled / tgfoid;時機與粒度從 tgtype 解出來,腳本裡有範例)
2. 每個 trigger 綁了哪些事件、什麼時機、什麼粒度?
   → INSERT/UPDATE/DELETE 有沒有漏?BEFORE 還是 AFTER?ROW 還是 STATEMENT?
3. 讀 trigger function 的原始碼
   → pg_get_functiondef(tgfoid);重點看 RETURN 什麼、有沒有寫同一張表、有沒有查別的表
4. 用最小操作重現,看「statement 回應的列數」與「實際資料」
   → INSERT 0 0 / UPDATE 1 但值沒變 = BEFORE trigger 回傳值有問題
5. 量化成本:EXPLAIN (ANALYZE) 對 INSERT/UPDATE 也能用
   → 輸出裡的 "Trigger trg_x: time=... calls=..." 直接告訴你 trigger 花了多少、被叫幾次
6. 對帳:衍生資料 vs 重新計算的值
   → 找出飄掉的列,判斷是「從某天開始」(邏輯改過) 還是「只有某類操作」(事件漏綁)
7. 才動手修:修 function / 補事件 / 改粒度 / 加 WHEN 條件
8. 驗證 + 回填:重跑重現步驟;修 trigger 不會修歷史資料,要另外回填
```

### 情境 A:INSERT 沒報錯,資料卻沒進去

**症狀**:應用程式 INSERT 成功 (沒有 exception),事後查卻找不到那筆資料。開發者花了半天懷疑 ORM、連線池、交易沒 commit。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | 用 psql 直接 INSERT 一筆 | 回應是 **`INSERT 0 0`** — 0 列,但沒有錯誤 |
| 2 | 列出這張表的 trigger (`pg_trigger`) | `trg_normalize_email \| BEFORE \| ROW \| O \| demo_fn_normalize_email` — 有一個 BEFORE ROW trigger |
| 3 | `pg_get_functiondef()` 讀原始碼,找 RETURN | `RETURN NULL;` |

**根因**:BEFORE ROW trigger 的回傳值就是「接下來要寫入的那一列」;回 NULL 代表「跳過這列」,而且這**不是錯誤**,所以應用程式完全不知道。寫這個 function 的人照著 AFTER trigger 的習慣寫了 `RETURN NULL`。

**修正**:BEFORE ROW 一定要 `RETURN NEW` (DELETE 時 `RETURN OLD`)。

**驗證**:再 INSERT 一次 → `INSERT 0 1`,而且 email 已被正規化成 `alice@example.com`。

**同類問題 A-2**:BEFORE UPDATE 裡改了 `OLD.xxx` 又 `RETURN OLD` → `UPDATE 1` 但值沒變 (用舊值覆蓋了這次更新)。同樣的排查順序,同樣看 RETURN。

### 情境 B:批次匯入從幾百毫秒變成將近一秒

**症狀**:同樣的 20 萬列批次匯入,加了「稽核 trigger」之後慢了 2.5 倍;資料量再大幾倍就是分鐘級。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | `EXPLAIN (ANALYZE) INSERT ...` 直接量 | 沒 trigger:`Execution Time: 367 ms`;有 trigger:`911 ms`,而且多了一行 **`Trigger trg_audit_row: time=576 calls=200000`** |
| 2 | `calls = 列數` → 是 row-level | `pg_trigger` 確認 `trg_audit_row \| ROW` |

**根因**:`FOR EACH ROW` = 每一列呼叫一次 PL/pgSQL function + 一次單列 INSERT 到稽核表;固定開銷 × 20 萬。EXPLAIN 顯示 63% 的時間都在 trigger 裡。

**修正 1 (保留即時稽核)**:改成 `FOR EACH STATEMENT` + `REFERENCING NEW TABLE AS new_rows`,function 內一次 `INSERT ... SELECT FROM new_rows` → `Trigger trg_audit_stmt: time=226 calls=1`,`Execution Time: 583 ms`。稽核筆數與事件筆數仍然一致 (40 萬 / 40 萬)。

**修正 2 (初始匯入 / 搬遷)**:`ALTER TABLE ... DISABLE TRIGGER trg_audit_stmt` 匯入 (`337 ms`,回到基準線),匯完 `ENABLE`,再用 `NOT EXISTS` 補寫缺的稽核 → 60 萬 / 60 萬。**停用期間漏掉的東西不會自己回來,回填是修正的一部分。**

### 情境 C:一條普通的 UPDATE 爆出 stack depth limit exceeded

**症狀**:`UPDATE demo_counters SET hits = hits + 1 WHERE id = 1` 跑了幾秒後報錯 `stack depth limit exceeded` (SQLSTATE 54001),錯誤的 CONTEXT 是同一個 function 名稱重複幾百行。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | 看錯誤 CONTEXT | `SQL statement "UPDATE demo_counters ..." PL/pgSQL function demo_fn_touch_after()` 一直重複 → 遞迴 |
| 2 | 列 trigger,並在原始碼裡找「寫回同一張表」 | `trg_touch_after \| demo_fn_touch_after \| writes_same_table = t` |

**根因**:AFTER UPDATE trigger 裡對**同一張表**再 UPDATE,又觸發同一個 trigger,無限遞迴直到 `max_stack_depth` 用完。動機 (記 `updated_at`) 完全合理,只是選錯時機。

**修正 1 (最佳)**:改成 `BEFORE UPDATE`,直接 `NEW.updated_at := NOW(); RETURN NEW;` — 根本不需要第二次 UPDATE。
**修正 2 (真的需要 AFTER 時)**:`WHEN (pg_trigger_depth() = 0)` 讓「由 trigger 引起的 UPDATE」不再觸發。

**驗證**:`UPDATE 1`,`touched = t`,不再報錯。

### 情境 D:訂單總額跟明細對不起來,但只有部分訂單

**症狀**:財務對帳發現 `orders.total` 與 `SUM(items)` 有出入,但不是全部 — 看起來像隨機發生。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | 對帳查詢:`total` vs `SUM(qty*price)`,`HAVING` 不相等 | 訂單 2 差 `-1200`,訂單 3 差 `+70`;訂單 1 正常 |
| 2 | 問「飄掉的訂單經歷了什麼操作」 | 訂單 2 被改過數量、訂單 3 被刪過一筆明細;訂單 1 只有新增 |
| 3 | 看 trigger 綁的事件 (`tgtype` 位元:4=INSERT、8=DELETE、16=UPDATE) | `on_insert = t, on_update = f, on_delete = f` |

**根因**:trigger 只綁了 `AFTER INSERT`,明細被 UPDATE / DELETE 時 total 停在舊值。只有「被改過或刪過明細」的訂單會飄,所以看起來像隨機。

**修正 1**:`CREATE TRIGGER ... AFTER INSERT OR UPDATE OR DELETE`。
**修正 2 (一定要做)**:回填 — `UPDATE demo_orders SET total = (SELECT SUM(...))` 重算所有訂單。修 trigger 只影響**之後**的變更。

**驗證**:對帳查詢回 0 列;再做一次 UPDATE / DELETE 明細,`drifted_orders = 0`。

### 情境 E:兩個 trigger 的執行順序不如預期

**症狀**:表上有「補預設值」與「驗證」兩個 BEFORE INSERT trigger,先建了補值、再建驗證,但沒填 priority 的 INSERT 總是被驗證擋下:`priority 不合法: <NULL>`。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | `SELECT tgname FROM pg_trigger ... ORDER BY tgname` | `trg_check_priority` 排在 `trg_set_default` 前面 |

**根因**:同表、同時機的 trigger 依**名稱字典序**執行,跟建立順序無關;`c` < `s`,驗證先跑。

**修正**:`ALTER TRIGGER ... RENAME TO trg_10_set_default` / `trg_20_check_priority`,用數字前綴明確排序。

**驗證**:同一筆 INSERT 成功,`priority = normal`。

## 章節腳本

- [`scripts/01-touch-and-audit.sql`](./scripts/01-touch-and-audit.sql) — updated_at 與稽核 trigger
- [`scripts/02-derived-total.sql`](./scripts/02-derived-total.sql) — 衍生欄位維護與防止降價
- [`scripts/03-instead-of-view.sql`](./scripts/03-instead-of-view.sql) — INSTEAD OF trigger 讓 view 可寫
- [`scripts/04-troubleshooting-scenarios.sql`](./scripts/04-troubleshooting-scenarios.sql) — 12.12 五個排查情境 (可重現)

---

下一章 ➡ [第 13 章:交易與並發控制](../13-transactions-concurrency/)
