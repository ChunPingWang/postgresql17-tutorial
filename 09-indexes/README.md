# 第 9 章 索引 (Index)

> 目標:理解索引解決什麼問題、**建索引前要先想清楚哪些事**、各種索引型別的適用時機,以及當索引「沒有用」時怎麼有系統地排查。
>
> 🧰 **前置準備**:本章範例使用 `bookstore` 資料庫 (`shop` schema 與範例資料)。尚未建立的話,先在 repo 根目錄執行 `psql -d postgres -f setup/01-create-tutorial-db.sql` 與 `psql -d bookstore -f setup/02-sample-data.sql`,詳見[第 1 章 1.8 節](../01-installation/README.md#18-建立教學用資料庫)。
>
> 📐 **本章讀法**:每一節都先講「為什麼會需要這個」,再講「怎麼做」。9.2 是動手前的決策清單,9.11 是四個可以實際重現的故障情境與排查順序 — 建議先讀 9.1~9.2 建立判斷框架,再看語法。

## 9.1 為什麼需要索引

**沒有索引時會發生什麼**:PostgreSQL 把表存成一堆 8KB 的頁面,要找 `WHERE isbn = '978-...'` 的那一列,唯一的辦法是從第一頁讀到最後一頁,逐列比對 — 這就是 **Sequential Scan**。8 本書無所謂,800 萬筆訂單就是每次查詢讀幾 GB。

**索引怎麼解決**:索引是一份「依某欄位排好序、並記錄每個值在表裡哪一頁」的獨立結構 (B-Tree)。有了它,找一個值變成在排序樹上往下走幾層,O(n) 變 O(log n) — 800 萬筆也只要讀十幾個頁面。

**但索引不是免費的**,這是整章的核心矛盾:

- 它是一份**額外的資料副本**,佔磁碟 (一個索引常是表的 10~30%)
- 每次 INSERT / UPDATE / DELETE,**所有**索引都要同步更新 → 寫入變慢 (9.11 情境 C 會量化這件事)
- 沒被用到的索引純粹是負擔:占空間、拖慢寫入、拖慢 VACUUM,一點好處都沒有

所以「要不要建索引、建哪一種」是**取捨**,不是有就好。下一節就是做這個取捨的清單。

## 9.2 建索引前的決策條件與考量重點

**為什麼要先想再建**:索引加錯不會報錯,只會讓系統默默變慢、變胖,而且很難事後歸因 (「寫入慢」的原因可能是半年前某人順手加的索引)。建之前花五分鐘回答下面幾個問題,比事後排查便宜得多。

### 先確認的前提

| 問題 | 為什麼重要 | 怎麼確認 |
|------|-----------|---------|
| **這條查詢真的慢、真的常跑嗎?** | 憑感覺加索引是最常見的浪費。一天跑一次的報表慢 3 秒,不值得為它拖慢每秒上千次的寫入 | `pg_stat_statements` 看 `calls` 與 `total_exec_time` (第 18 章);慢查詢日誌 |
| **表有多大?會長多大?** | 小表 (幾千列) Seq Scan 比索引還快,planner 根本不會用索引;決策要看一年後的規模 | `SELECT pg_size_pretty(pg_table_size('shop.orders'))`、`n_live_tup` |
| **讀寫比例?** | 索引是「用寫入成本換讀取速度」。寫入為主的表 (log、事件流) 每多一個索引,寫入吞吐就掉一截 | `pg_stat_user_tables` 的 `n_tup_ins/upd/del` vs `seq_scan/idx_scan` |
| **條件的選擇度 (selectivity) 高嗎?** | 索引只在「條件能過濾掉絕大多數列」時才划算。`WHERE is_deleted = false` 命中 95% 的列,走索引反而比 Seq Scan 慢 (逐列回表) | `SELECT count(DISTINCT col), count(*) FROM t`;`pg_stats.n_distinct` |
| **查詢的形狀是什麼?** | 索引型別與欄位順序完全取決於查詢怎麼寫:等值?範圍?`LIKE`?JSONB 包含?`ORDER BY`?多欄組合? | 收集實際 SQL,不要憑想像 |
| **已有的索引能不能涵蓋?** | `(a, b)` 的複合索引已經能服務 `WHERE a = ?`,再建 `(a)` 是純浪費 (9.10) | `\d shop.orders` 看現有索引 |

### 決策對照:什麼情況選什麼

| 查詢條件長這樣 | 選擇 | 理由 |
|---------------|------|------|
| `col = ?`、`col > ?`、`BETWEEN`、`ORDER BY col`、`LIKE 'abc%'` | B-Tree (預設) | 排序結構,等值與範圍都能走;涵蓋 90% 的需求 |
| `a = ? AND b = ?` 常一起出現 | 複合索引 `(a, b)`,選擇度高或常單獨查的放前面 | 一個索引服務多種查詢,且能同時過濾兩個條件 (9.10) |
| 只查表的一小部分 (`WHERE status = 'pending'` 且 pending 很少) | 部分索引 `WHERE status = 'pending'` | 索引只含關心的列,小很多、寫入其他狀態的列不用維護它 (9.5) |
| 條件對欄位套函數 `LOWER(email) = ?`、`created_at::date = ?` | 表達式索引;或改寫條件 | B-Tree 存的是原值,對欄位做運算後就對不上了 (9.5、9.11 情境 A) |
| `jsonb @> ?`、陣列 `@>`/`&&`、全文 `@@`、`LIKE '%abc%'` | GIN (+ `pg_trgm`) | 這些是「包含」而不是「等於/大於」,B-Tree 無法表達 (9.6) |
| 超大表、依時間順序寫入、只查時間範圍 | BRIN | 索引只記每個區塊的最小/最大值,幾 MB 就能服務 TB 級表;但要求資料物理順序與欄位相關 |
| `SELECT a, b WHERE a = ?` 且要極致讀取速度 | 覆蓋索引 `(a) INCLUDE (b)` | 讓查詢只讀索引不回表 (Index-Only Scan);代價是索引更大 (9.5) |
| 純等值、值很長 (長字串、UUID 字串) | Hash | 索引比 B-Tree 小;但不支援範圍與排序,一般仍建議 B-Tree |

### 上線時的考量

- **鎖**:一般 `CREATE INDEX` 會鎖住整張表的寫入直到建完,大表可能是幾十分鐘。生產環境一律 `CREATE INDEX CONCURRENTLY` (9.4),並理解它失敗時會留下 INVALID 索引 (9.11 情境 D)。
- **HOT update 失效**:PostgreSQL 對「沒有更新到任何索引欄位」的 UPDATE 有一條快速路徑 (HOT)。一旦你對常被 UPDATE 的欄位建索引,每次 UPDATE 都要寫索引,寫入成本會跳一級。常變動的欄位 (計數器、`updated_at`) 三思。
- **磁碟與備份**:索引會一起被備份、一起被複寫到 replica;索引體積直接反映在 `pg_basebackup` 與 WAL 量上。
- **統計資料**:建完要 `ANALYZE`,planner 才知道新索引的選擇度;否則第一段時間可能不用它 (9.11 情境 B)。
- **驗證再收工**:建完用 `EXPLAIN (ANALYZE, BUFFERS)` 確認查詢真的改走索引、真的變快。「索引存在」和「索引被用」是兩件事 (9.7)。

## 9.3 索引類型

**為什麼有這麼多種**:B-Tree 的本質是「排序」,所以它只能回答「等於、大於、小於、以某字串開頭」這類**能靠排序比對**的問題。「JSONB 裡有沒有這個 key」、「陣列有沒有交集」、「這段文字含不含某個詞」都不是排序能回答的,才需要其他結構。

| 類型 | 適用 | 範例 |
|------|------|------|
| **B-Tree** (預設) | 等值、範圍、`<` `>` `BETWEEN` `LIKE 'abc%'` `ORDER BY` | `CREATE INDEX ON books(price)` |
| **Hash** | 純等值,不支援範圍 | `USING hash (col)` |
| **GIN** | 多值欄位 (陣列、JSONB、全文 tsvector、pg_trgm) — 一個列對應多個索引項目 | `USING gin (tags)` |
| **GiST** | 幾何、範圍、近鄰、自訂 | `USING gist (period)` |
| **SP-GiST** | 不平衡資料 (IP 地址、四叉樹) | `USING spgist (ip)` |
| **BRIN** | 大表 + 物理排序天然 (時間序列) | `USING brin (ordered_at)` |

不確定就用 B-Tree;只有在 9.2 的決策表明確指向其他型別時才換。

## 9.4 建立 / 刪除索引

![查看現有索引](./screenshots/01-list-indexes.png)

![索引使用統計](./screenshots/02-index-stats.png)

```sql
-- 基本
CREATE INDEX idx_books_price ON shop.books(price);
CREATE INDEX idx_books_category ON shop.books(category_id);

-- 多欄複合索引 (順序很重要!見 9.10)
CREATE INDEX idx_orders_customer_status ON shop.orders(customer_id, status);

-- UNIQUE:除了加速,同時是「不可重複」的約束
CREATE UNIQUE INDEX uq_authors_email ON shop.authors(email);
```

**為什麼生產環境要用 `CONCURRENTLY`**:一般 `CREATE INDEX` 會對表取得 `SHARE` 鎖 — 讀可以、**寫全部卡住**直到索引建完。大表建索引可能要幾十分鐘,等於服務停寫。`CONCURRENTLY` 改用多階段方式建立,期間允許讀寫,代價是慢兩三倍、不能在交易內執行、失敗會留下 INVALID 索引 (見 9.11 情境 D)。

```sql
-- 大型表別鎖表
CREATE INDEX CONCURRENTLY idx_books_isbn ON shop.books(isbn);

-- 刪除:同樣有 CONCURRENTLY,避免刪除時鎖住正在跑的查詢
DROP INDEX shop.idx_books_price;
DROP INDEX CONCURRENTLY shop.idx_books_isbn;
```

## 9.5 進階索引技巧

### 部分索引 (Partial Index)

**為什麼**:很多查詢只關心表的一小部分 — 「進行中」的訂單、「未處理」的工作、「未刪除」的使用者。對整欄建索引,90% 的索引項目都在描述你永遠不會查的 `completed` 訂單:白占空間,而且每筆歷史訂單狀態變更都要維護它。

**怎麼做**:加 `WHERE` 讓索引只包含符合條件的列。查詢的條件必須能讓 planner 推論出「落在索引範圍內」,索引才會被用。

```sql
-- 只索引「進行中」訂單:索引小、查詢快、完成的訂單不再維護它
CREATE INDEX idx_active_orders
    ON shop.orders(customer_id)
    WHERE status IN ('pending','paid','shipped');

-- 這個查詢會用到 (條件涵蓋在索引的 WHERE 內)
SELECT * FROM shop.orders WHERE customer_id = 1 AND status = 'pending';
-- 這個不會 (completed 不在索引裡)
SELECT * FROM shop.orders WHERE customer_id = 1 AND status = 'completed';
```

### 表達式索引

**為什麼**:B-Tree 存的是欄位的**原值**。`WHERE LOWER(name) = 'carl sagan'` 比對的是 `LOWER(name)` 的結果,索引裡沒有這個值,planner 只能 Seq Scan 後逐列算 `LOWER()`。這是「有索引卻沒被用」最常見的原因之一 (9.11 情境 A)。

**怎麼做**:直接對表達式建索引,並且**查詢時寫一模一樣的表達式**。表達式必須是 `IMMUTABLE` (同樣輸入永遠同樣輸出);`timestamptz::date` 依賴 session 時區,就不行。

```sql
-- 不分大小寫搜尋
CREATE INDEX idx_authors_lower_name
    ON shop.authors (LOWER(name));

-- 查詢時用同樣的表達式才會命中
SELECT * FROM shop.authors WHERE LOWER(name) = LOWER('CARL SAGAN');
```

### 包含欄位 (Covering Index, PG 11+)

**為什麼**:索引找到符合條件的項目後,通常還得**回表** (讀 heap 頁面) 拿 SELECT 需要的其他欄位;每一列一次隨機讀。如果查詢要的欄位全在索引裡,就能 **Index-Only Scan**,完全不碰表。

**怎麼做**:`INCLUDE` 把「只是要讀、不用來過濾」的欄位塞進索引葉節點。這些欄位不參與排序,所以不會膨脹樹的高度,但索引會變大。

```sql
-- SELECT total, status ... WHERE customer_id = ? 可以只讀索引
CREATE INDEX idx_orders_cover
    ON shop.orders (customer_id)
    INCLUDE (total, status);
```

> Index-Only Scan 還依賴 visibility map:剛大量寫入、還沒 VACUUM 的表,即使有覆蓋索引也可能得回表確認可見性 (`EXPLAIN` 會顯示 `Heap Fetches`)。這是第 18 章 VACUUM 的主題之一。

## 9.6 GIN 索引 (常用於 JSONB / 陣列 / 全文)

**為什麼**:`metadata @> '{"language":"en"}'` 問的是「這個 JSON 裡**有沒有**這個鍵值」;一列 JSONB 可能有幾十個鍵,一個陣列有幾十個元素。B-Tree 一列對應一個排序值,表達不了「一列對應多個可搜尋項」。GIN (倒排索引) 正是「每個項目 → 出現在哪些列」的結構,搜尋引擎用的就是它。

**怎麼做**:對整個 JSONB 欄位建 GIN,所有 key 都可查;若只查特定 path,對那個 path 建可以小很多。

```sql
-- 對 JSONB 建 GIN,所有 key 都可快速查
CREATE INDEX idx_books_meta_gin ON shop.books USING gin (metadata);

-- 查詢
SELECT * FROM shop.books WHERE metadata @> '{"language":"en"}';

-- 對特定 path
CREATE INDEX idx_books_meta_tags
    ON shop.books USING gin ((metadata->'tags'));
```

GIN 的代價:建立與更新比 B-Tree 慢得多 (一列要更新多個項目),寫入密集的表要評估;`LIKE '%abc%'` 這種模糊比對也是靠 GIN + `pg_trgm` (9.11 情境 A-2、第 15 章)。

## 9.7 EXPLAIN — 看執行計畫

**為什麼**:9.2 說過,「索引存在」跟「索引被用」是兩回事。planner 會依統計資料估算成本,決定要不要用你的索引;它的決定可能跟你的預期不同,而且往往它是對的 (小表、低選擇度時 Seq Scan 更快)。**不要猜,看計畫。**

**怎麼看**:

```sql
EXPLAIN
SELECT * FROM shop.books WHERE price > 500;

-- ANALYZE 會實際執行並回報耗時
EXPLAIN ANALYZE
SELECT * FROM shop.books WHERE price > 500;

-- 詳細版 (排查時用這個)
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT * FROM shop.books WHERE price > 500;
```

**關鍵欄位**:
- `Seq Scan` — 全表掃描 (小表無妨,大表要警惕)
- `Index Scan` — 用索引找到位置,再回表拿資料
- `Index Only Scan` — 用索引且不必回表 (最快)
- `Bitmap Index Scan + Bitmap Heap Scan` — 中等選擇度:先用索引收集所有符合的頁面,再一次讀 heap
- `Filter: ...` — 在掃描結果上逐列過濾的條件;**條件出現在 Filter 而不是 `Index Cond`,就代表它沒有用到索引**
- `cost=A..B` — 啟動成本..總成本 (估計值,不是時間)
- `rows=N` (估計) vs `actual rows=N` (實際,要加 ANALYZE) — **兩者差距大,就是統計資料有問題** (9.11 情境 B)
- `actual time=...` — 實際耗時 ms;`Buffers: shared hit/read` — 讀了多少頁面 (hit 在 cache,read 要碰磁碟)

## 9.8 何時不該建索引

回到 9.1 的取捨:以下情況索引的成本大於收益,planner 也多半不會用它。

- 表很小 (< 10000 列):Seq Scan 幾個頁面就讀完,比走索引再回表還快
- 選擇度低 (例如 `is_active = TRUE` 但 95% 都是 TRUE):符合的列太多,逐列回表比直接掃過去慢
- 寫入遠多於讀取:每個索引都是寫入成本,而收益 (讀取) 幾乎沒有
- 已被其他複合索引前綴覆蓋 (9.10):重複付出寫入與空間成本,沒有額外收益
- 欄位頻繁被 UPDATE:破壞 HOT update,寫入成本跳級 (9.2)

## 9.9 維護索引

**為什麼要維護**:索引不會自己消失,但會**變胖** (bloat:大量 UPDATE/DELETE 後,索引裡留下許多指向死元組的項目,VACUUM 只能回收一部分),也會**變成孤兒** (需求變了、查詢改寫了,索引卻沒人刪)。定期看兩件事:誰沒被用、誰太大。

```sql
-- 看索引大小與使用次數 (idx_scan 是自統計重設以來被用的次數)
SELECT
    schemaname,
    relname    AS table,
    indexrelname AS index,
    pg_size_pretty(pg_relation_size(indexrelid)) AS size,
    idx_scan,
    idx_tup_read
FROM pg_stat_user_indexes
ORDER BY pg_relation_size(indexrelid) DESC;

-- 找出可能無用的索引:觀察期要夠長 (月結報表一個月才跑一次),
-- 且 UNIQUE / PK 索引即使 idx_scan = 0 也不能刪 (它們是約束)
SELECT
    schemaname || '.' || relname AS table,
    indexrelname AS index,
    pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE idx_scan = 0
ORDER BY pg_relation_size(indexrelid) DESC;

-- 重建索引 (修復 bloat)。一般 REINDEX 需獨佔鎖,生產環境用 CONCURRENTLY (PG 12+)
REINDEX INDEX shop.idx_books_price;
REINDEX TABLE shop.books;
REINDEX INDEX CONCURRENTLY shop.idx_books_price;
```

## 9.10 索引順序為什麼重要 (複合索引)

**為什麼**:複合索引 `(a, b)` 是「先依 a 排序、a 相同再依 b 排序」— 就像電話簿先依姓、再依名。要找「姓王的」很快;要找「所有名叫小明的」,電話簿幫不上忙,因為「小明」散落在每個姓底下。

`CREATE INDEX i ON t(a, b)` 可被使用於:
- `WHERE a = ?`
- `WHERE a = ? AND b = ?`
- `WHERE a = ? ORDER BY b`

**不能**有效用於:
- `WHERE b = ?` (a 沒給條件)

> 原則:**等值條件、選擇度高 (distinct 多) 的欄位放前面**,或常常單獨被 query 的欄位放前面。範圍條件 (`>`、`BETWEEN`) 的欄位放最後,因為範圍之後的欄位無法再縮小搜尋。

## 9.11 問題排查:情境模擬與排查順序

**為什麼要練這個**:索引相關的問題有個共同特徵 — **不會報錯**。系統只是變慢、變胖,錯誤訊息裡沒有任何線索。能不能有系統地縮小範圍,比背再多語法都重要。本節先給一套通用排查順序,再用四個可以在本機重現的情境走一遍。

> 🧪 所有情境都在 [`scripts/03-troubleshooting-scenarios.sql`](./scripts/03-troubleshooting-scenarios.sql) 裡,用自己的 demo 表 (50 萬列),跑完自動清掉。建議一段一段執行,對照下面的說明。情境 D 會刻意出現一個 ERROR。

### 通用排查順序:「查詢慢 / 索引沒用到」

順序的邏輯是**先便宜後昂貴、先確認事實再動手改**:

```
1. 確認問題是真的、是哪一條 SQL
   → pg_stat_statements / 慢查詢日誌;不要對著「感覺慢」排查
2. 看計畫:EXPLAIN (ANALYZE, BUFFERS)
   → 是 Seq Scan?條件在 Filter 還是 Index Cond?rows 估計 vs 實際差多少?
3. 索引存在嗎、是有效的嗎?
   → \d 表名;pg_index.indisvalid
4. 條件寫法能用索引嗎? (sargable)
   → 欄位被套函數/轉型?LIKE 前置 %?型別不符 (int 欄位比 text)?OR 串接?
5. 統計資料新鮮嗎?
   → pg_stat_user_tables.last_analyze / n_mod_since_analyze
6. planner 是不是其實是對的?
   → 表很小?條件命中大部分列?用 SET enable_seqscan = off 強迫走索引比較看看,
     若索引版本更慢,問題不在索引
7. 才動手修
   → 改寫 SQL > 建表達式/部分索引 > ANALYZE > 調 random_page_cost 等參數
8. 驗證:再跑一次 EXPLAIN ANALYZE,確認計畫與時間都改善;觀察一段時間 idx_scan 有增加
```

### 情境 A:明明有索引,查詢還是 Seq Scan

**症狀**:`ts_events.created_at` 上有 B-Tree 索引,但「查 3 月 1 日那天的事件」跑了全表掃描,50 萬列每次 17ms;上線後資料是幾億列,就是每次好幾秒。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | `pg_indexes` 確認索引存在 | `idx_events_created ... btree (created_at)` — 索引在 |
| 2 | `EXPLAIN (ANALYZE, BUFFERS)` | `Parallel Seq Scan on ts_events` + `Filter: ((created_at)::date = ...)` + `Rows Removed by Filter: 165707` |
| 3 | 條件出現在 **Filter** 而非 **Index Cond** → 進通用順序第 4 步:條件寫法 | `created_at::date` 對欄位做了轉型 |

**根因**:索引存的是 `timestamptz` 原值;`created_at::date` 是算出來的新值,索引裡沒有,planner 只能全掃後逐列算。而且 `timestamptz → date` 依賴 session 時區、不是 IMMUTABLE,連表達式索引都建不了。

**修正**:把條件改寫成對欄位**原值**的範圍比對:

```sql
WHERE created_at >= TIMESTAMPTZ '2025-03-01 00:00:00+00'
  AND created_at <  TIMESTAMPTZ '2025-03-02 00:00:00+00'
```

**驗證**:計畫變成 `Index Only Scan using idx_events_created`,17ms → 0.5ms。

**同類問題 A-2**:`WHERE payload LIKE '%abc%'`。B-Tree 靠排序,只能從字串**開頭**比對;前置 `%` 沒有開頭可比 → Seq Scan。修正不是改 SQL,而是換索引型別:`CREATE INDEX ... USING gin (payload gin_trgm_ops)`,計畫變成 `Bitmap Index Scan on idx_events_payload_trgm`,22ms → 4ms。

### 情境 B:昨天還很快的查詢,今天突然變慢

**症狀**:`SELECT ... FROM jobs WHERE status = 'pending'` 一直是 0.6ms,今天變成 45ms。SQL 沒改、索引沒動、沒有人 deploy。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | `EXPLAIN (ANALYZE, BUFFERS)` 對照估計與實際 | `Index Only Scan ... rows=930` 但 `actual rows=400100` — **估計差了 430 倍** |
| 2 | 估計錯 → 通用順序第 5 步:統計資料 | `pg_stat_user_tables`:`n_mod_since_analyze = 400000`,`last_analyze` 是昨天 |
| 3 | 問「昨天到今天資料發生了什麼」 | 批次作業把 80% 的 job 重設成 `pending` |

**根因**:planner 靠統計資料 (`pg_stats`) 估算 `status = 'pending'` 會命中幾列。舊統計說 pending 只佔 0.1%,所以它選索引;實際上現在 80% 的列都符合,走索引要逐列回表 40 萬次,比直接 Seq Scan 慢。**資料分布劇變 + 統計沒跟上**,是「沒改任何東西卻變慢」最常見的原因。

**修正**:`ANALYZE jobs;`

**驗證**:估計變成 `rows=167347`,planner 自己改選 `Parallel Seq Scan`,45ms → 24ms;`n_mod_since_analyze` 歸零。

**延伸思考**:autovacuum 平常會自動 ANALYZE (門檻是 `autovacuum_analyze_threshold + autovacuum_analyze_scale_factor × 列數`),但批次寫入後到它跑之前有空窗。**大量 ETL / 批次更新之後主動 `ANALYZE`** 是標準作法;第 18 章會談如何調整這些門檻。

### 情境 C:寫入越來越慢、磁碟一直長

**症狀**:讀取沒變慢,但 `INSERT INTO ts_events` 的延遲一路往上爬;監控顯示這張表的索引總大小已經超過表本身。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | `pg_table_size` vs `pg_indexes_size` | 5 個索引,索引總量 > 表 |
| 2 | 量化:`EXPLAIN ANALYZE INSERT ... 10 萬列` | 535ms — 建立基準線,修完才有東西比 |
| 3 | 找**完全重複**的索引 (`pg_index` 依 `indkey`、`indclass`、表達式、條件分組) | `{idx_events_created, idx_events_created_dup}` |
| 4 | 找**被複合索引前綴覆蓋**的索引 | `idx_events_created` 被 `idx_events_created_kind (created_at, kind)` 覆蓋 |
| 5 | 找**從未被用**的索引 (`pg_stat_user_indexes.idx_scan = 0`) | `idx_events_kind` (只有 3 種值,planner 從不選它) |

**根因**:歷任開發者各自「順手」加索引,沒人檢查已有的。每一個索引都是每次寫入的固定成本,重複的索引是純浪費。

**修正**:`DROP INDEX CONCURRENTLY` 刪掉重複、前綴冗餘、低選擇度的三個索引 (生產環境先確認 `idx_scan` 觀察期夠長、不是 UNIQUE/PK)。

**驗證**:同樣插 10 萬列,535ms → 261ms — **多餘的索引讓寫入慢了一倍**。

### 情境 D:CREATE INDEX CONCURRENTLY 失敗,留下 INVALID 索引

**症狀**:上線時執行 `CREATE UNIQUE INDEX CONCURRENTLY` 報錯 (`could not create unique index`);之後查詢沒變快,寫入反而更慢了。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | 通用順序第 3 步:索引存在嗎、**有效嗎**?`pg_index.indisvalid` | `idx_events_kind_uq \| indisvalid = f` — 索引還在,但是 INVALID |

**根因**:`CONCURRENTLY` 為了不鎖表,分成多個交易階段執行;中途失敗 (這裡是資料有重複值違反 UNIQUE) 無法整體 rollback,索引物件會以 INVALID 狀態留下來。INVALID 索引**查詢不會用它,但每次寫入仍要維護它** — 只有成本沒有收益,而且 `\d` 不仔細看很容易漏掉。

**修正**:`DROP INDEX CONCURRENTLY idx_events_kind_uq;`,修好資料 (或改定義) 後再重建。

**驗證**:`pg_index` 中不再有 `indisvalid = f` 的索引。

**延伸**:任何 `CREATE INDEX CONCURRENTLY` 失敗後 (含被 cancel、連線中斷),都要主動檢查一次 INVALID 索引:

```sql
SELECT indexrelid::regclass, indrelid::regclass
FROM pg_index WHERE NOT indisvalid;
```

## 章節腳本

- [`scripts/01-create-indexes.sql`](./scripts/01-create-indexes.sql) — 建立各種索引
- [`scripts/02-explain-analyze.sql`](./scripts/02-explain-analyze.sql) — EXPLAIN ANALYZE 觀察 planner
- [`scripts/03-troubleshooting-scenarios.sql`](./scripts/03-troubleshooting-scenarios.sql) — 9.11 四個排查情境 (可重現)

---

下一章 ➡ [第 10 章:視圖 (View / Materialized View)](../10-views/)
