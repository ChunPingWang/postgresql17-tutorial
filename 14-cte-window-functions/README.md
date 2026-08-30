# 第 14 章 CTE 與視窗函數

> 目標:理解 CTE 與視窗函數各自解決什麼問題、**寫之前要先做哪些取捨** (內聯還是物化、GROUP BY 還是視窗、ROWS 還是 RANGE),能用遞迴 CTE 走階層資料、用視窗函數做排名與累積統計,並在結果「怪怪的」或查詢跑不完時有系統地排查。
>
> 🧰 **前置準備**:本章範例使用 `bookstore` 資料庫 (`shop` schema 與範例資料)。尚未建立的話,先在 repo 根目錄執行 `psql -d postgres -f setup/01-create-tutorial-db.sql` 與 `psql -d bookstore -f setup/02-sample-data.sql`,詳見[第 1 章 1.8 節](../01-installation/README.md#18-建立教學用資料庫)。
>
> 📐 **本章讀法**:每一節都先講「為什麼會需要這個」,再講「怎麼做」。14.2 是動手前的決策清單,14.11 是四個可以實際重現的故障情境與排查順序 — 建議先讀 14.1~14.2 建立判斷框架,再看語法。

## 14.1 為什麼需要 CTE 與視窗函數

**沒有它們時會發生什麼**:兩類需求用「基本 SQL」寫起來特別痛苦 —

1. **多步驟的查詢**:先算每個分類的統計、再拿去 JOIN、再過濾。用子查詢可以做,但會變成三四層巢狀,讀的人要從最裡面往外讀;而且同一個中間結果如果要用兩次,就得複製貼上兩份。
2. **「每一列」都要看到「一組列」的資訊**:每本書旁邊顯示全店平均價、每筆訂單旁邊顯示該客戶的上一筆訂單金額、每個分類內的價格排名。`GROUP BY` 做不到 — 它會把一組列**折疊成一列**,原本每一列的細節就不見了;用自我 JOIN 或相關子查詢做得到,但一個指標一個子查詢,又慢又難維護。

**它們怎麼解決**:
- **CTE (`WITH`)** 讓你替中間結果取名字,查詢從「巢狀」變成「由上往下的步驟」;`WITH RECURSIVE` 更讓 SQL 能表達「重複套用直到沒有新列」,這是走樹狀/階層資料唯一的原生做法。
- **視窗函數 (`OVER`)** 在**不折疊列**的前提下,對「與目前列相關的一組列」做計算 — 排名、累計、前後一筆、分組內的極值,一個 `OVER` 搞定。

**但它們各有代價**,這是本章的核心取捨:CTE 可能變成 planner 的「優化圍籬」讓索引用不上 (14.11 情境 C);遞迴 CTE 在資料有環時會跑到天荒地老 (情境 A);視窗函數的預設 frame 在 ORDER BY 有並列值時會給出「看起來對、其實錯」的數字 (情境 B、D)。下一節先把這些取捨列成清單。

## 14.2 設計前的決策條件與考量重點

**為什麼要先想再寫**:這兩個工具的錯誤都**不會報錯** — 累計金額算錯、`LAST_VALUE` 拿到自己、CTE 讓查詢慢 100 倍,SQL 都能正常執行並回傳結果。寫之前先回答下面幾個問題,比等報表出錯被業務單位找上門便宜得多。

### 先確認的前提

| 問題 | 為什麼重要 | 怎麼確認 |
|------|-----------|---------|
| **中間結果會被引用幾次?** | 只引用一次,PG 12+ 會自動把 CTE 內聯進主查詢,和子查詢沒差;引用兩次以上就會先整個算出來 (物化),外層的過濾條件推不進去 (14.11 情境 C) | 數一下 `FROM cte_name` 出現幾次 |
| **中間結果大不大、貴不貴?** | 便宜且被多次引用 → 內聯 (重算兩次也無妨);昂貴 (大聚合、複雜 JOIN) 且被多次引用 → 物化才划算,算一次用多次 | `EXPLAIN ANALYZE` 看 CTE 節點的 rows 與時間 |
| **階層資料保證沒有環嗎?** | 遞迴 CTE 的終止條件是「這一輪沒有新列」,資料有環就永遠不停 (14.11 情境 A);資料庫層若沒有約束,環一定會在某天出現 | `manager_id IS DISTINCT FROM id` 只能擋自環;跨列的環要靠 `CYCLE` 子句或應用程式檢查 |
| **階層有多深、每次要走多少列?** | 遞迴 CTE 每一層都是一次 JOIN,深度 × 寬度決定成本;十萬節點、深度 20 的樹用遞迴 CTE 每次查都重走,可能該改資料模型 (`ltree`、closure table) | 先用 `depth` 上限跑一次看列數與時間 |
| **視窗的 ORDER BY 會不會有並列值?** | 有 ORDER BY 時預設 frame 是 `RANGE ... CURRENT ROW`,並列的列 (peers) 會被一起算進去,累計與 `LAST_VALUE` 都會「跳」(14.11 情境 B、D) | ORDER BY 的欄位是否唯一?不是就補上主鍵當 tie-breaker |
| **真的需要保留每一列嗎?** | 視窗函數不折疊列,輸出列數 = 輸入列數;報表只要每組一列的話 `GROUP BY` 更便宜也更直接 | 問結果要「每筆明細 + 統計」還是「每組一列」 |
| **資料量與排序成本?** | 每個不同的 `PARTITION BY / ORDER BY` 組合都是一次排序;百萬列上開五個不同視窗 = 五次排序,`work_mem` 不夠就落磁碟 | `EXPLAIN (ANALYZE, BUFFERS)` 看 `WindowAgg` 底下的 `Sort` 有沒有 `Disk` |

### 決策對照:什麼情況選什麼

| 需求長這樣 | 選擇 | 理由 |
|-----------|------|------|
| 多步驟查詢,中間結果只用一次 | CTE (預設行為) 或子查詢 | PG 12+ 會內聯,純粹是可讀性選擇;CTE 由上往下讀較清楚 |
| 中間結果**便宜**、要用多次、外層有過濾條件 | `WITH x AS NOT MATERIALIZED (...)` | 讓條件推進去走索引;重算兩次的成本遠低於全表物化 (情境 C) |
| 中間結果**昂貴** (大聚合)、要用多次 | `WITH x AS MATERIALIZED (...)` | 算一次、掃多次;PG 12+ 對引用多次的 CTE 預設就是這樣,寫明白避免版本差異 |
| 中間結果要跨多個陳述式使用、或要建索引 | `CREATE TEMP TABLE` | CTE 只活在一條陳述式內;暫存表可以 `ANALYZE`、加索引、分段除錯 |
| 中間結果要給很多查詢/很多人重複用 | View (第 10 章) | CTE 是查詢內部的東西,共用邏輯屬於 View 的職責 |
| 走樹/圖:找祖先、找子孫、算路徑 | `WITH RECURSIVE` + `CYCLE` 子句 (PG 14+) | 唯一的原生做法;`CYCLE` 讓有環的資料也能安全終止 |
| 階層很深、查詢極頻繁、資料少變動 | `ltree` extension 或 closure table | 用寫入時多存一點換讀取時不用遞迴;遞迴 CTE 每次都重走整棵樹 |
| 每一列旁邊要顯示「所屬組」的統計 (平均、總和、佔比) | 視窗函數 `OVER (PARTITION BY ...)` | 不折疊列;用 GROUP BY 得再 JOIN 回去 |
| 每組只要一列彙總 | `GROUP BY` | 更便宜、意圖更清楚;視窗函數會多出重複列還得 DISTINCT |
| 排名、每組 Top-N | `ROW_NUMBER()` / `RANK()` + 外層過濾 (14.9) | 一次排序解決;N 很小且分組很多時 `LATERAL` (第 7 章) 可能更快 |
| 累計、移動平均 | `SUM/AVG ... OVER (ORDER BY 唯一鍵 ROWS ...)` | ORDER BY 必須唯一或明確用 `ROWS`,否則並列值會讓結果跳動 (情境 B) |
| 與上一筆/下一筆比較 (差額、間隔天數) | `LAG()` / `LEAD()` | 取代自我 JOIN,一趟掃描完成 |
| 分組內的第一筆/最後一筆 | `FIRST_VALUE()` / `LAST_VALUE()` + `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` | `LAST_VALUE` 沒寫 frame 一定拿到自己 (情境 D) |
| 分頁 | keyset (`WHERE id > ?`) 而不是 `ROW_NUMBER()` 過濾 | `ROW_NUMBER` 分頁每頁都要對全部資料排序編號;keyset 走索引直接定位 (第 18 章 18.9) |

### 上線時的考量

- **CTE 不是效能工具**:它的本意是可讀性。查詢慢時第一件事是 `EXPLAIN` 看有沒有 `CTE Scan` 擋住了條件下推;需要「算一次用多次」的效果請**明確寫** `MATERIALIZED`,不要依賴版本預設。
- **遞迴 CTE 一定要有保險**:生產查詢加 `CYCLE` 子句或 `depth < N`,而且連線層設 `statement_timeout`。「資料不會有環」是假設,不是保證。
- **視窗 ORDER BY 永遠補上唯一鍵**:`ORDER BY tx_date, id` 而不是 `ORDER BY tx_date`。這一個習慣同時消滅情境 B 與 D 兩類錯誤。
- **寫 CTE 修改資料 (`WITH ... DELETE ... RETURNING`) 時**:所有子陳述式看到的都是同一個快照,彼此看不到對方的修改;「先刪再插」在同一條 `WITH` 內是安全的,但不要假設順序。
- **排序成本**:多個視窗盡量共用同一個 `WINDOW w AS (...)` 定義 (14.10),planner 才能只排序一次;`EXPLAIN` 看到多個 `Sort` 節點就是沒共用。
- **驗證再收工**:視窗函數的結果請用一個獨立的、笨方法的查詢對帳 — 例如累計的最後一列應等於 `SUM(*)`、每組 `LAST_VALUE` 應只有一種值 (14.11 每個情境都附這種驗證查詢)。

## 14.3 CTE (Common Table Expression)

**為什麼**:三層以上的巢狀子查詢,讀的人得從最內層往外推;而同一個中間結果要用兩次就得複製一份。CTE 用 `WITH` 替中間結果取名字,查詢變成由上往下的「步驟」,重複引用只要寫名字。

**怎麼做**:

![CTE + 累計視窗函數範例](./screenshots/01-cte-running-total.png)

```sql
WITH
    category_stats AS (
        SELECT category_id, COUNT(*) AS book_cnt, AVG(price) AS avg_price
        FROM shop.books
        GROUP BY category_id
    )
SELECT c.name, cs.book_cnt, cs.avg_price::NUMERIC(10,2)
FROM category_stats cs
JOIN shop.categories c ON c.id = cs.category_id
ORDER BY cs.book_cnt DESC;
```

### 多個 CTE

**為什麼**:步驟之間可以互相引用 (後面的 CTE 用前面的),把一個複雜報表拆成「過濾 → 聚合 → 呈現」三段,每段都能單獨拿出來跑、單獨除錯。

```sql
WITH
    paid_orders AS (
        SELECT * FROM shop.orders WHERE status IN ('paid','completed')
    ),
    revenue_by_customer AS (
        SELECT customer_id, SUM(total) AS revenue
        FROM paid_orders
        GROUP BY customer_id
    )
SELECT c.name, r.revenue
FROM revenue_by_customer r
JOIN shop.customers c ON c.id = r.customer_id
ORDER BY r.revenue DESC;
```

### MATERIALIZED / NOT MATERIALIZED (PG 12+)

**為什麼**:PG 12 之前 CTE **一律**先整個算出來 (物化),外層條件推不進去,是有名的效能陷阱;PG 12 起改成「只引用一次就內聯、引用多次才物化」。這個預設在多數情況是對的,但你可以明確指定 (14.11 情境 C 有實測數字):

```sql
-- 便宜、被引用多次、外層有條件 → 要求內聯,讓條件推進去走索引
WITH recent AS NOT MATERIALIZED (
    SELECT * FROM shop.orders WHERE ordered_at > NOW() - INTERVAL '30 days'
)
SELECT count(*) FROM recent WHERE customer_id = 1
UNION ALL
SELECT count(*) FROM recent WHERE customer_id = 2;

-- 昂貴 (大聚合)、被引用多次 → 明確要求算一次
WITH stats AS MATERIALIZED (
    SELECT customer_id, SUM(total) AS revenue FROM shop.orders GROUP BY customer_id
)
SELECT (SELECT MAX(revenue) FROM stats) AS top, (SELECT AVG(revenue) FROM stats) AS avg;
```

### CTE 可以寫入 (INSERT/UPDATE/DELETE)

**為什麼**:「把符合條件的列搬到封存表」如果分成兩條陳述式 (先 INSERT ... SELECT 再 DELETE),中間若有人改了資料,兩邊就不一致。放在同一個 `WITH` 裡,`DELETE ... RETURNING` 的結果直接餵給 `INSERT`,一條陳述式、一個快照、要嘛全成功要嘛全失敗。

```sql
-- 先準備封存表 (同第 6 章 6.3 的做法)
CREATE SCHEMA IF NOT EXISTS archive;
CREATE TABLE IF NOT EXISTS archive.books_old (LIKE shop.books INCLUDING ALL);

WITH deleted AS (
    DELETE FROM shop.books
    WHERE stock = 0 AND published_at < '2000-01-01'
    RETURNING *
)
INSERT INTO archive.books_old
SELECT * FROM deleted;
-- 練習完可清理:DROP SCHEMA archive CASCADE;
```

## 14.4 遞迴 CTE — `WITH RECURSIVE`

**為什麼**:「找某員工的所有上司」深度不固定 — 可能 1 層也可能 10 層。一般 SQL 每個 JOIN 只能走固定的一層,寫 10 個 LEFT JOIN 既醜又只能到 10 層。遞迴 CTE 表達的是「從起點開始,**重複**套用同一個 JOIN,直到沒有新列」,深度由資料決定。

**怎麼做**:兩段用 `UNION ALL` 接起來 — 基礎條件 (起點) 與遞迴部分 (從上一輪結果再走一步)。

```sql
-- 員工主管鏈:找 id=7 的員工所有上司
WITH RECURSIVE mgr_chain AS (
    -- 基礎條件 (起點)
    SELECT id, name, role, manager_id, 0 AS depth
    FROM shop.employees
    WHERE id = 7

    UNION ALL

    -- 遞迴部分
    SELECT e.id, e.name, e.role, e.manager_id, mc.depth + 1
    FROM shop.employees e
    JOIN mgr_chain mc ON mc.manager_id = e.id
)
SELECT depth, id, name, role FROM mgr_chain ORDER BY depth DESC;
```

另一個方向,**向下找所有下屬**:

```sql
WITH RECURSIVE subordinates AS (
    SELECT id, name, role, manager_id, 0 AS depth
    FROM shop.employees WHERE id = 1   -- CEO

    UNION ALL

    SELECT e.id, e.name, e.role, e.manager_id, s.depth + 1
    FROM shop.employees e
    JOIN subordinates s ON e.manager_id = s.id
)
SELECT depth, lpad('', depth*2, '  ') || name AS org_chart, role
FROM subordinates
ORDER BY depth, name;
```

### 環的保險:`CYCLE` 子句 (PG 14+)

**為什麼**:遞迴的終止條件是「這一輪沒產生新列」。資料一旦有環 (A 的主管是 B、B 的主管是 A),每一輪都會有列,查詢永遠不停、記憶體一路漲 (14.11 情境 A 會實際重現)。`CYCLE` 讓 PostgreSQL 自動記錄走過的路徑,再次遇到同一個節點就標記並停止。

```sql
WITH RECURSIVE subordinates AS (
    SELECT id, name, manager_id, 0 AS depth FROM shop.employees WHERE id = 1
    UNION ALL
    SELECT e.id, e.name, e.manager_id, s.depth + 1
    FROM shop.employees e JOIN subordinates s ON e.manager_id = s.id
) CYCLE id SET is_cycle USING path      -- 遇到重複的 id 就標 is_cycle = true 並停止
SELECT depth, id, name, is_cycle, path FROM subordinates ORDER BY depth, id;
```

PG 13 以前的寫法是自己帶一個 `path` 陣列並在 JOIN 條件加 `NOT (e.id = ANY(s.path))`;無論哪種,生產環境的遞迴查詢都要有其中一種保險。

## 14.5 視窗函數 (Window Functions)

**為什麼**:`GROUP BY` 會把一組列折疊成一列 — 要「每本書旁邊顯示全店平均」,用 GROUP BY 得先算平均再 JOIN 回原表。視窗函數在**不折疊列**的前提下,對「與目前列相關的一組列」做計算,一個 `OVER` 就完成。

```sql
SELECT title, price,
       AVG(price) OVER () AS avg_all
FROM shop.books;
-- 每列都保留,但右邊多了「全表平均」
```

### OVER 語法

**為什麼要懂三個部分**:`PARTITION BY` 決定「哪些列是一組」、`ORDER BY` 決定「組內的順序」(有了它累計才有意義)、frame 決定「以目前列為中心,實際納入計算的是哪幾列」。**三者的預設值**是本章最多錯誤的來源:沒寫 ORDER BY 時 frame 是整個分組;寫了 ORDER BY 時 frame 預設是 `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` — 注意是 `RANGE` 不是 `ROWS`,並列值會一起算 (14.7、14.11 情境 B、D)。

```sql
function_name() OVER (
    [PARTITION BY col1, col2]   -- 分組 (不合併列)
    [ORDER BY col3]              -- 排序 (影響累計型函數,也決定預設 frame)
    [frame_clause]               -- 視窗框 (預設值見上方說明)
)
```

## 14.6 排名函數

**為什麼**:「每個分類最貴的前三本」、「這筆訂單金額在該客戶的所有訂單中排第幾」— 都是「組內排序後的位置」。三個排名函數差別只在**並列值怎麼算**,選錯會讓 Top-N 多幾列或少幾列。

![PARTITION BY 分組視窗函數](./screenshots/02-partition-by.png)

```sql
SELECT
    title, price, category_id,
    ROW_NUMBER()   OVER (PARTITION BY category_id ORDER BY price DESC) AS row_num,
    RANK()         OVER (PARTITION BY category_id ORDER BY price DESC) AS rank,
    DENSE_RANK()   OVER (PARTITION BY category_id ORDER BY price DESC) AS dense_rank,
    PERCENT_RANK() OVER (ORDER BY price)                               AS pct_rank,
    NTILE(3)       OVER (ORDER BY price)                               AS quartile
FROM shop.books;
```

`ROW_NUMBER` vs `RANK` vs `DENSE_RANK`:
- ROW_NUMBER:1,2,3,4 (永遠連續;並列時順序不確定,要「恰好 N 列」用它,但 ORDER BY 請補唯一鍵)
- RANK:1,2,2,4 (並列後跳號;「前三名」可能超過三列)
- DENSE_RANK:1,2,2,3 (並列後不跳;「前三個價位」)

## 14.7 累積型函數

**為什麼**:累計、移動平均是「目前列之前 (或前後幾列) 的聚合」。這裡 frame 是主角 — 而且**預設的 frame 是 `RANGE`**,只要 ORDER BY 有並列值,同一個值的所有列都會被一起算進去,累計就會「跳」。安全的寫法是 ORDER BY 補上唯一鍵,或明確寫 `ROWS`。

```sql
SELECT
    id,
    title,
    price,
    SUM(price) OVER (ORDER BY price, id) AS running_sum,   -- 補 id 當 tie-breaker
    AVG(price) OVER (
        ORDER BY price, id
        ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING   -- 移動平均:明確用 ROWS
    ) AS moving_avg_3
FROM shop.books;
```

### Frame Clause

| 語法 | 說明 |
|------|------|
| `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` | 從頭到目前這**一列** (依實際列數) |
| `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` | 從頭到「與目前列 ORDER BY 值相同的所有列」— **這是有 ORDER BY 時的預設** |
| `ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING` | 前 1 列到後 1 列 |
| `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` | 整個分組 (`LAST_VALUE` 要用這個) |
| `RANGE BETWEEN INTERVAL '7 days' PRECEDING AND CURRENT ROW` | 依**值**的範圍 (時間視窗),ORDER BY 必須是單一欄位 |

## 14.8 Lead / Lag / First_value / Last_value / Nth_value

**為什麼**:「這筆訂單比上一筆多多少」、「距離上次購買幾天」、「該客戶第一筆/最後一筆訂單金額」— 沒有視窗函數要用自我 JOIN 對「上一筆」,而「上一筆」本身就很難用 JOIN 條件表達。`LAG/LEAD` 直接取相對位置的列;`FIRST_VALUE/LAST_VALUE` 取 frame 的頭尾 — 所以 `LAST_VALUE` 一定要把 frame 拉到分組結尾,否則 frame 預設只到目前列,「最後一列」就是自己 (14.11 情境 D)。

```sql
SELECT
    id,
    ordered_at::date,
    total,
    LAG(total)  OVER (PARTITION BY customer_id ORDER BY ordered_at) AS prev_total,
    LEAD(total) OVER (PARTITION BY customer_id ORDER BY ordered_at) AS next_total,
    FIRST_VALUE(total) OVER (PARTITION BY customer_id ORDER BY ordered_at
                             ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS first_order,
    LAST_VALUE(total)  OVER (PARTITION BY customer_id ORDER BY ordered_at
                             ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS last_order
FROM shop.orders
ORDER BY customer_id, ordered_at;
```

## 14.9 每組 Top-N 模式

**為什麼**:視窗函數的值在 `WHERE` 階段還不存在 (它在 WHERE/GROUP BY/HAVING 之後才算),所以 `WHERE ROW_NUMBER() ... = 1` 會直接報錯 `window functions are not allowed in WHERE` (14.11 情境 D-2)。標準做法是先在 CTE 算出排名,外層再過濾。

不用 LATERAL,也可以用 ROW_NUMBER 實現:

```sql
WITH ranked AS (
    SELECT
        b.title, c.name AS category, b.price,
        ROW_NUMBER() OVER (PARTITION BY b.category_id ORDER BY b.price DESC, b.id) AS rn
    FROM shop.books b
    JOIN shop.categories c ON c.id = b.category_id
)
SELECT category, title, price
FROM ranked
WHERE rn = 1;   -- 每分類最貴的書
```

分組很多、N 很小時,第 7 章的 `LATERAL` 每組只掃 N 列,可能比對全表排序更快;分組少、要看很多列時視窗函數較適合。

## 14.10 WINDOW 子句 (命名視窗)

**為什麼**:同一個查詢裡多個視窗函數用同樣的 `PARTITION BY / ORDER BY`,每個 `OVER (...)` 各寫一次不只囉嗦,還容易改了一個忘了另一個;命名視窗讓 planner 也更容易確認它們能共用同一次排序。

```sql
SELECT
    title, category_id, price,
    SUM(price)  OVER w AS sum_price,
    AVG(price)  OVER w AS avg_price,
    MAX(price)  OVER w AS max_price
FROM shop.books
WINDOW w AS (PARTITION BY category_id ORDER BY price, id)
ORDER BY category_id, price;
```

## 14.11 問題排查:情境模擬與排查順序

**為什麼要練這個**:本章的錯誤有兩種面貌 — 一種是**不報錯但數字錯** (累計跳號、`LAST_VALUE` 拿到自己),報表送出去才被發現;另一種是**查詢跑不完** (遞迴遇到環、CTE 物化擋住索引),表面看起來像「資料庫變慢了」。兩種都不會在錯誤訊息裡告訴你原因,靠的是有順序地縮小範圍。

> 🧪 所有情境都在 [`scripts/04-troubleshooting-scenarios.sql`](./scripts/04-troubleshooting-scenarios.sql) 裡,用自己的 demo 表 (`ts_` 開頭,最大 20 萬列),跑完自動清掉。建議一段一段執行,對照下面的說明。情境 A 與 D-2 會刻意觸發錯誤,但都包在 `DO ... EXCEPTION` 裡只印 NOTICE。

### 通用排查順序:「結果怪怪的 / 查詢跑不完」

順序的邏輯是**先確認事實、先便宜後昂貴**:

```
1. 先分類:是「跑不完」還是「跑完但數字錯」?
   → 跑不完:先用 statement_timeout 止血,再往 2、3 走
   → 數字錯:直接跳到 4
2. 看計畫:EXPLAIN (ANALYZE, BUFFERS)
   → 有 CTE Scan 嗎?它底下是 Seq Scan 嗎?條件在 CTE Scan 的 Filter 而不是 Index Cond?
   → 有 Recursive Union 嗎?actual rows 是不是遠超過資料的節點數?
   → WindowAgg 底下的 Sort 有沒有 Disk?
3. CTE 被引用幾次?中間結果有多大?
   → 引用多次 + 便宜 → NOT MATERIALIZED;引用多次 + 昂貴 → MATERIALIZED;
   → 遞迴:資料有沒有環 (用 depth 上限 + path 把走過的列印出來)
4. 把「預設」寫成「明確」再跑一次
   → OVER 裡把 frame 明確寫出 RANGE / ROWS 各一版,比較哪一版是你要的
   → ORDER BY 補上唯一鍵,看結果是否改變 (改變 = 原本有並列值問題)
5. 用「笨方法」對帳
   → 累計的最後一列 = SUM(*)?每組 LAST_VALUE 只有一種值?遞迴回傳列數 ≤ 節點數?
6. 才動手修
   → 改 frame / 補 tie-breaker > 加 CYCLE 或 depth 上限 > 改 MATERIALIZED 屬性 > 改資料模型
7. 驗證:對帳查詢回傳 true;計畫不再有多餘的 CTE Scan / 遞迴列數正常;並把保險 (CYCLE、timeout、約束) 留在生產查詢裡
```

### 情境 A:遞迴 CTE 跑不完 (資料裡有環)

**症狀**:「找某員工的所有下屬」平常 1ms,今天掛住不回來、CPU 100%、backend 記憶體一直漲。沒改 SQL。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | 止血:`SET statement_timeout = '2s'` 後重跑同一條查詢 | 2 秒後 `SQLSTATE 57014` (query_canceled) — 確認是「跑不完」不是「很慢」 |
| 2 | 遞迴加 `WHERE depth < 8` 並帶一個 `path` 陣列,把走過的列印出來 | `{1,2,4,5,1,2,4,5,1}` — 第 4 層又回到起點 1,往後每 4 層重複一次 |
| 3 | 直接找環:對每個節點走主管鏈,看誰會回到自己 | `in_cycle = 1, 2, 4, 5` — 四個人互為上下級 |
| 4 | 問「今天資料發生了什麼」 | HR 組織調整把 CEO 的主管設成了一位基層員工 |

**根因**:遞迴 CTE 的終止條件是「這一輪沒有產生新列」。資料有環時每一輪都會產生列,查詢永遠不會結束;`depth < N` 只是止血,查詢本身要能偵測環。

**修正**:PG 14+ 加 `CYCLE id SET is_cycle USING path`:同一個 `id` 第二次出現時標記 `is_cycle = t` 並停止往下走。

**驗證**:同一條查詢不再需要 timeout,回傳 6 列 (第 6 列 `is_cycle = t`,`path = {(1),(2),(4),(5),(1)}` 直接指出環在哪);修好資料後回傳 5 列、`any_cycle = f`。同時加 `CHECK (manager_id IS DISTINCT FROM id)` 擋掉最常見的自環 — 跨列的環資料庫約束擋不住,生產查詢要**永遠帶著 `CYCLE`**。

**注意**:`statement_timeout` 要在陳述式**開始前**設定;在 `DO` 區塊裡 `SET LOCAL` 是來不及的,計時器在陳述式開始時就決定了。

### 情境 B:累計金額「跳著加」— ORDER BY 有並列值

**症狀**:對帳單的 `running_total` 在同一天的三筆交易上都顯示 600,而不是 100 / 300 / 600;月底總額是對的,中間每一筆都不對。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | 重現:`SUM(amount) OVER (ORDER BY tx_date)` | 3/1 的三筆都是 600,3/2 的兩筆都是 700 |
| 2 | 把預設 frame 寫成明確的 `RANGE ... CURRENT ROW` 與 `ROWS ... CURRENT ROW` 各一欄並排 | `RANGE` 欄與原結果一模一樣;`ROWS` 欄是 100 / 300 / 600 / 650 / 700 / 1700 |
| 3 | 檢查 ORDER BY 欄位是否唯一 | `tx_date` 同一天多筆 → 有並列值 (peers) |

**根因**:有 ORDER BY 時預設 frame 是 `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`,而 `RANGE` 模式的「CURRENT ROW」代表「所有與目前列 ORDER BY 值相同的列」。同一天的三筆互為 peers,每一筆都拿到整天的合計。

**修正**:ORDER BY 補上唯一鍵 `ORDER BY tx_date, id` (最推薦,同時讓結果順序確定),或明確寫 `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`。

**驗證**:`count(DISTINCT running_total) = count(*)` → `t`,`max(running_total) = SUM(amount)` → `t`。

### 情境 C:把查詢重構成 CTE 之後變慢 (optimization fence)

**症狀**:某客戶的「已付款訂單數 + 營收」原本 0.2ms,為了好讀把「已付款訂單」抽成 CTE 並在 `UNION ALL` 的兩段各引用一次,變成 27ms;`customer_id` 上的索引明明在。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | `EXPLAIN (ANALYZE, BUFFERS)` | `CTE paid → Seq Scan on ts_orders` 產出 133,334 列;兩個 `CTE Scan on paid` 各自 `Filter: (customer_id = 42)`、`Rows Removed by Filter: 133307`;`temp written=310` — 中間結果大到落磁碟 |
| 2 | 條件出現在 CTE Scan 的 **Filter** 而不是索引的 Index Cond → 通用順序第 3 步:CTE 被引用幾次? | 兩次 → PG 12+ 預設物化 |
| 3 | 中間結果貴不貴? | 只是一個 `status IN (...)` 過濾,便宜 → 該內聯 |

**根因**:PG 12+ 只會把「被引用一次」的 CTE 內聯進主查詢;引用兩次以上就先整個算出來當暫存結果,外層的 `WHERE customer_id = 42` 推不進去,20 萬列全掃還寫了 temp 檔。

**修正**:
1. `WITH paid AS NOT MATERIALIZED (...)` — 兩段各自內聯,條件推進去走 `Bitmap Index Scan on idx_ts_orders_customer`:**27.5ms → 0.19ms**。
2. 更好:把 `customer_id = 42` 直接寫進 CTE 裡 — 物化仍會發生,但物化的只有 27 列,只掃一次索引:**0.16ms**。

**反例 (什麼時候要 `MATERIALIZED`)**:CTE 是一個 20 萬列的 `GROUP BY customer_id` 聚合、被三個子查詢引用 — 明確寫 `MATERIALIZED` 讓 `HashAggregate` 只跑一次 (29ms),內聯反而會算三次。判斷標準就是 14.2 的「便宜且多次引用 → 內聯;昂貴且多次引用 → 物化」。

**驗證**:計畫中不再有底下接 `Seq Scan` 的 `CTE Scan`;`Buffers` 沒有 `temp`;`Execution Time` 回到 ms 以下。

### 情境 D:`LAST_VALUE` 回傳的不是最後一筆

**症狀**:「每位客戶的第一筆與最後一筆訂單金額」報表,`first_total` 每位客戶都正確且固定,`last_total` 卻每一列都不同 — 剛好等於該列自己的 `total`。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | 重現:`LAST_VALUE(total) OVER (PARTITION BY customer_id ORDER BY ordered_at)` | 客戶 1 的三列 `last_total` = 100 / 250 / 400,與 `total` 逐列相同 |
| 2 | 通用順序第 4 步:把預設 frame 寫出來 | 預設是 `... AND CURRENT ROW` — frame 的「最後一列」永遠是目前列自己 |
| 3 | 為什麼 `FIRST_VALUE` 沒事? | frame 的起點預設就是 `UNBOUNDED PRECEDING` (分組開頭),所以它剛好對 |

**根因**:與情境 B 同源 — 有 ORDER BY 時 frame 預設只到 `CURRENT ROW`;`LAST_VALUE` 取的是 frame 的最後一列,不是分組的最後一列。

**修正**:`LAST_VALUE(total) OVER (w ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)`,把 frame 拉到分組結尾。

**驗證**:每位客戶 `count(DISTINCT last_total) = 1` → `t`,且等於 `ORDER BY ordered_at DESC LIMIT 1` 那筆 → `t` (客戶 1 = 400,客戶 2 = 300)。

**同類問題 D-2**:`WHERE ROW_NUMBER() OVER (...) = 1` → `SQLSTATE 42P20: window functions are not allowed in WHERE`。視窗函數在 WHERE / GROUP BY / HAVING **之後**才計算,WHERE 階段還沒有它的值。修正:先在 CTE 或子查詢算出 `rn`,外層再 `WHERE rn = 1` (14.9 的模式)。

## 章節腳本

- [`scripts/01-cte-basic.sql`](./scripts/01-cte-basic.sql) — CTE 基礎與寫入型 CTE
- [`scripts/02-recursive-cte.sql`](./scripts/02-recursive-cte.sql) — 遞迴 CTE 走階層資料
- [`scripts/03-window-functions.sql`](./scripts/03-window-functions.sql) — 排名、累計、LAG/LEAD
- [`scripts/04-troubleshooting-scenarios.sql`](./scripts/04-troubleshooting-scenarios.sql) — 14.11 四個排查情境 (可重現)

---

下一章 ➡ [第 15 章:JSON / 全文搜尋](../15-json-fulltext/)
