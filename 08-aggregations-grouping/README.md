# 第 8 章 聚合與群組

> 目標:掌握 SQL 的「分組統計」 — 計數、加總、平均、條件聚合、GROUPING SETS / ROLLUP / CUBE;更重要的是**知道報表數字為什麼會錯**,以及怎麼有系統地找出來。
>
> 🧰 **前置準備**:本章範例使用 `bookstore` 資料庫 (`shop` schema 與範例資料)。尚未建立的話,先在 repo 根目錄執行 `psql -d postgres -f setup/01-create-tutorial-db.sql` 與 `psql -d bookstore -f setup/02-sample-data.sql`,詳見[第 1 章 1.8 節](../01-installation/README.md#18-建立教學用資料庫)。
>
> 📐 **本章讀法**:每一節都先講「為什麼會需要這個」,再講「怎麼做」。8.2 是寫報表查詢前的決策清單,8.11 是五個可以實際重現的故障情境與排查順序。聚合的 bug 有個特點:**SQL 不會報錯,只是數字錯了**,所以排查能力比語法更重要。

## 8.1 為什麼需要聚合

**沒有聚合會發生什麼**:業務問的問題幾乎都不是「某一列是什麼」,而是「總共多少」「平均多少」「每個分類各幾筆」。沒有聚合,你只能把 100 萬筆訂單全部撈回應用程式,自己迴圈加總 — 慢 (網路傳輸 100 萬列)、耗記憶體、而且每個開發者各寫一套加總邏輯,數字對不起來。

**聚合怎麼解決**:資料庫在資料所在的地方把「多列」壓成「一個值」(或每組一個值),只把結果傳回。這是 SQL 最有價值的能力之一,也是報表、dashboard、KPI 的基礎。

**但聚合有自己的陷阱**:一列都不會少、也不會報錯,只是**數字悄悄地錯了** — NULL 被忽略、JOIN 讓列數膨脹、分母定義不清。本章後半 (8.9、8.11) 就是在講這些。

| 函數 | 說明 | 注意 |
|------|------|------|
| `COUNT(*)` | 列數 (含 NULL) | 「有幾筆」用這個 |
| `COUNT(col)` | 該欄非 NULL 的列數 | 「有幾筆有填值」 |
| `COUNT(DISTINCT col)` | 該欄不重複值數 | 比 COUNT 慢很多 (要去重) |
| `SUM(col)` | 加總 | 全部 NULL 時回 NULL,不是 0 |
| `AVG(col)` | 平均 | 分母是**非 NULL** 的列數 (8.9) |
| `MAX(col)` / `MIN(col)` | 最大 / 最小 | 有索引時可以只讀索引第一/最後一筆 |
| `BOOL_AND` / `BOOL_OR` | 布林全 TRUE / 任一 TRUE | 「這批訂單是否全部出貨」 |
| `STRING_AGG(col, ',')` | 字串串接 | 可加 `ORDER BY` 控制順序 |
| `ARRAY_AGG(col)` | 聚合為陣列 | 給應用程式直接用 |
| `JSON_AGG(col)` / `JSONB_AGG` | 聚合為 JSON 陣列 | API 回傳一對多時很方便 |

## 8.2 設計前的決策條件與考量重點

**為什麼要先想再寫**:一條聚合查詢寫出來會跑、有結果,不代表數字是對的、也不代表資料量成長後還跑得動。報表數字錯了通常是幾週後財務對帳才發現,那時候已經很難回溯是哪一條 SQL、哪一天開始錯的。寫之前先回答下面幾個問題。

### 先確認的前提

| 問題 | 為什麼重要 | 怎麼確認 |
|------|-----------|---------|
| **分組的粒度是什麼?一列代表什麼?** | 「每月每客戶」和「每月」是不同的查詢;粒度沒定清楚,`GROUP BY` 就會多放或少放欄位,數字直接錯 | 先用一句話寫下「結果的一列 = ___」,再寫 SQL |
| **要 JOIN 的表之間是 1:1 還是 1:N?** | 兩個 1:N 一起 JOIN 再聚合,金額會被複製 (8.11 情境 C)。這是報表數字錯最常見的原因 | `SELECT COUNT(*), COUNT(DISTINCT 主鍵)` 比一下;看 FK 方向 |
| **欄位有 NULL 嗎?NULL 代表什麼意思?** | `AVG`、`SUM`、`COUNT(col)` 都忽略 NULL;分母會默默縮小 (8.11 情境 B) | `SELECT COUNT(*), COUNT(col) FROM t`;問業務「沒填值」該算 0 還是不算 |
| **資料量、分組數有多大?** | 分組數 × 每組狀態超過 `work_mem` 就會溢出到磁碟 (8.11 情境 E);`COUNT(DISTINCT)` 在大表上特別貴 | `n_live_tup`;`SELECT COUNT(DISTINCT 分組鍵)` |
| **這條查詢多久跑一次?誰在看?** | 每分鐘刷新的 dashboard 對 100 萬列做即時聚合是浪費;每天一次的報表則沒必要建 materialized view | 看需求;看 `pg_stat_statements` 的 `calls` |
| **同一份數字有沒有別的地方也在算?** | 兩套邏輯 → 兩個數字 → 沒完沒了的「哪個才對」 | 把聚合邏輯收斂到 view (第 10 章) 或單一 SQL |

### 決策對照:什麼情況選什麼

| 需求長這樣 | 選擇 | 理由 |
|-----------|------|------|
| 「每組一個數字」 | `GROUP BY` + 聚合函數 | 最基本;結果列數 = 組數 |
| 「每一列都要,但旁邊附上該組的統計」 (排名、佔比、累計) | 視窗函數 `OVER (PARTITION BY ...)` (第 14 章) | `GROUP BY` 會把列壓掉;視窗函數保留每一列 |
| 「每組取一列代表」 (最新、最貴的那筆) | `DISTINCT ON (key) ... ORDER BY key, x DESC` | 這不是聚合,是挑列;硬用 `MAX()` 拿不到同一列的其他欄位 (8.11 情境 A) |
| 一個查詢要算多種條件的統計 | `agg FILTER (WHERE ...)` | 比 `SUM(CASE WHEN ...)` 清楚;一次掃描算完 |
| 要同時看「明細、小計、總計」 | `ROLLUP` / `CUBE` / `GROUPING SETS` | 一次掃描產出多個粒度;`UNION ALL` 要掃 N 次 |
| 要的是「有幾筆」 | `COUNT(*)` | `COUNT(col)` 會漏掉 NULL 列,`COUNT(1)` 沒有比較快 |
| 要的是「有幾個不同的」 | `COUNT(DISTINCT col)` | 大表上很貴;近似值可用 `hll` 之類的 extension |
| 沒填值要當 0 算 | `COALESCE(col, 0)` 放在聚合**裡面** | `AVG(COALESCE(x,0))` 與 `COALESCE(AVG(x),0)` 是兩個不同的答案 |
| 過濾條件是「列」的條件 | `WHERE` | 分組前就縮小資料量;語意清楚 |
| 過濾條件是「組」的條件 (含聚合函數) | `HAVING` | `WHERE` 裡不能放聚合函數 (8.11 情境 D) |
| 同一份彙總每分鐘被讀幾百次 | Materialized View / 預先彙總表 (第 10 章) | 讀多算少;付出的是資料新鮮度 |

### 實務考量

- **先聚合再 JOIN,不要先 JOIN 再聚合**:遇到多個 1:N 關係,各自在子查詢/CTE 裡聚合到同一粒度後再 JOIN,金額就不會被複製 (8.11 情境 C)。
- **報表一定要附「分母」**:平均值旁邊放 `COUNT(*)` 與 `COUNT(col)`,讓看的人知道這個平均是幾筆算出來的 (8.11 情境 B)。
- **`work_mem` 是每個聚合節點各自拿一份**:一條查詢有多個 HashAggregate / Sort,每個都可以用到 `work_mem`;全域調高要乘以並發連線數估算記憶體。只對報表 session `SET work_mem` 比較安全 (8.11 情境 E)。
- **`GROUP BY 1, 2` 只適合互動查詢**:正式 SQL 寫欄名,否則 SELECT 清單一改,分組就默默跟著錯。
- **驗證數字**:寫完用一個已知答案 (例如某一張訂單的總額) 對一下;`COUNT(*)` vs `COUNT(DISTINCT id)` 是最便宜的膨脹檢測。

## 8.3 GROUP BY

**為什麼**:`SUM(total)` 只會給你一個總數;業務要的是「**每個**分類 / **每個**月 / **每個**客戶」各多少。`GROUP BY` 定義「什麼算同一組」,聚合函數在每組內各算一次。

**怎麼做**:

![GROUP BY + HAVING 範例](./screenshots/01-group-by-having.png)

```sql
SELECT category_id, COUNT(*) AS book_count, AVG(price)::NUMERIC(10,2) AS avg_price
FROM shop.books
GROUP BY category_id;

-- GROUP BY 多欄:粒度是「月 × 狀態」
SELECT
    DATE_TRUNC('month', ordered_at) AS month,
    status,
    COUNT(*) AS cnt,
    SUM(total) AS revenue
FROM shop.orders
GROUP BY 1, 2
ORDER BY 1, 2;
```

**SQL 規則,以及為什麼有這條規則**:
- `SELECT` 清單中,非聚合欄位**必須**出現在 `GROUP BY` — 因為一組裡有很多列,沒分組也沒聚合的欄位,資料庫不知道該顯示哪一列的值,所以直接拒絕 (8.11 情境 A 有三種修法)。例外:`GROUP BY` 主鍵時,同一張表的其他欄位可以直接選 (functional dependency)。
- 可以用欄位序號 (`GROUP BY 1, 2`) 偷懶,但**正式 SQL 建議寫欄名**。

## 8.4 HAVING

**為什麼**:「訂單數超過 1 的客戶」這種條件,是對**組**的統計結果做過濾。`WHERE` 是在分組**之前**逐列評估,那時候還沒有「組」,`COUNT(*)` 沒有意義 — 所以需要一個分組**之後**才生效的過濾子句。

**怎麼做**:`WHERE` 在分組**前**過濾列,`HAVING` 在分組**後**過濾組。

```sql
SELECT category_id, COUNT(*) AS cnt
FROM shop.books
GROUP BY category_id
HAVING COUNT(*) > 1;
```

判斷原則:條件裡有聚合函數 → `HAVING`;條件只看單一列的欄位 → `WHERE`。PostgreSQL 會把只牽涉分組欄位的 `HAVING` 條件自動下推到掃描階段,所以兩者的分界是語意而不是效能 (8.11 情境 D 用 EXPLAIN 證明這件事)。

## 8.5 FILTER 子句

**為什麼**:dashboard 常要「總訂單數、已完成數、已取消數、已完成營收」同時顯示。寫四條查詢要掃四次表;傳統寫法 `SUM(CASE WHEN status='completed' THEN total ELSE 0 END)` 可以一次掃完,但一多就難讀,而且 `AVG(CASE ... ELSE 0)` 的分母會算錯 (把不符合的列當 0 算進去)。

**怎麼做**:`FILTER (WHERE ...)` 讓每個聚合函數只看符合條件的列,一次掃描、語意精確、分母正確。

```sql
SELECT
    COUNT(*)                                          AS total_orders,
    COUNT(*) FILTER (WHERE status = 'completed')      AS completed,
    COUNT(*) FILTER (WHERE status = 'cancelled')      AS cancelled,
    SUM(total) FILTER (WHERE status = 'completed')    AS rev_completed,
    AVG(total) FILTER (WHERE status = 'completed')::NUMERIC(10,2) AS avg_completed
FROM shop.orders;
```

> 比起傳統的 `SUM(CASE WHEN ... THEN x ELSE 0 END)` 寫法更直覺;而且 `AVG ... FILTER` 的分母只算符合條件的列,`AVG(CASE ... ELSE 0)` 則會除以全部列數 — 這是兩個不同的答案。

## 8.6 字串 / 陣列聚合

**為什麼**:「每個分類有哪些書」如果用一般 JOIN 查,一本書一列,應用程式還得自己把同分類的書收攏在一起。讓資料庫在聚合時直接把「多列」串成一個字串 / 陣列 / JSON,API 回傳一對多資料時不用再組裝。

**怎麼做**:

```sql
-- 每分類有哪些書 (一行一分類)
SELECT
    c.name AS category,
    STRING_AGG(b.title, ', ' ORDER BY b.title) AS titles
FROM shop.books b
JOIN shop.categories c ON c.id = b.category_id
GROUP BY c.name;

-- 聚成陣列
SELECT
    c.name,
    ARRAY_AGG(b.title ORDER BY b.title) AS title_array
FROM shop.books b
JOIN shop.categories c ON c.id = b.category_id
GROUP BY c.name;

-- 聚成 JSON
SELECT
    o.id,
    JSON_AGG(JSON_BUILD_OBJECT('book_id', oi.book_id, 'qty', oi.quantity)) AS items
FROM shop.orders o
JOIN shop.order_items oi ON oi.order_id = o.id
GROUP BY o.id;
```

注意 `ORDER BY` 寫在聚合函數**裡面**,才能控制串接順序;寫在外面只影響結果列的順序。

## 8.7 GROUPING SETS / ROLLUP / CUBE

**為什麼**:報表常常要「分類 × 狀態的明細、每個分類的小計、全部的總計」三種粒度放在同一張表。用三條 `GROUP BY` 查詢 `UNION ALL`,表要掃三次,而且欄位數要對齊、很難維護。

**怎麼做**:一次掃描、指定多組分組粒度,PostgreSQL 在同一個結果集裡回傳全部粒度;小計/總計列在被彙總掉的欄位上是 NULL,用 `COALESCE` 或 `GROUPING()` 標示。

```sql
-- ROLLUP:逐層彙總
-- 等於 GROUPING SETS ((category, status), (category), ())
SELECT category_id, status, COUNT(*) AS cnt
FROM shop.books b
LEFT JOIN shop.order_items oi ON oi.book_id = b.id
LEFT JOIN shop.orders o       ON o.id = oi.order_id
GROUP BY ROLLUP (category_id, status);

-- CUBE:所有組合彙總
SELECT category_id, status, COUNT(*) AS cnt
FROM shop.books b
LEFT JOIN shop.order_items oi ON oi.book_id = b.id
LEFT JOIN shop.orders o       ON o.id = oi.order_id
GROUP BY CUBE (category_id, status);

-- GROUPING SETS:明確指定
SELECT
    COALESCE(c.name, '〔全部〕') AS category,
    COALESCE(o.status::text, '〔小計〕') AS status,
    COUNT(*) AS cnt
FROM shop.books b
JOIN shop.categories c ON c.id = b.category_id
LEFT JOIN shop.order_items oi ON oi.book_id = b.id
LEFT JOIN shop.orders o       ON o.id = oi.order_id
GROUP BY GROUPING SETS ((c.name, o.status), (c.name), ());
```

選擇原則:有階層 (年 → 月 → 日) 用 `ROLLUP`;維度彼此獨立、每種組合都要看用 `CUBE`;只要特定幾組用 `GROUPING SETS` (最省)。

## 8.8 DISTINCT 與聚合

**為什麼**:「客戶總數」和「有下單的客戶數」是兩個不同的問題;後者從 `orders` 數,但一個客戶可能有多筆訂單,直接 `COUNT(*)` 會把同一個客戶算好幾次。

**怎麼做**:

```sql
-- 客戶總數
SELECT COUNT(*) FROM shop.customers;

-- 有下單的客戶總數
SELECT COUNT(DISTINCT customer_id) FROM shop.orders;
```

`COUNT(DISTINCT)` 需要先去重 (排序或 hash),大表上明顯比 `COUNT(*)` 慢;它同時也是**偵測 JOIN 膨脹最便宜的工具** — `COUNT(*)` 與 `COUNT(DISTINCT 主鍵)` 不相等,就是列被複製了 (8.11 情境 C)。

## 8.9 NULL 在聚合中

**為什麼要特別講**:NULL 在聚合裡的行為很一致 — **除了 `COUNT(*)`,全部忽略 NULL** — 但這個「忽略」會讓分母默默縮小,平均值看起來變好了,其實只是低分的人沒填。這類問題不會報錯,只有拿去跟其他數字對才會發現 (8.11 情境 B)。

- `COUNT(*)`:**包含** NULL
- `COUNT(col)`、`SUM(col)`、`AVG(col)`:**忽略** NULL
- `AVG` 是 `SUM / COUNT(col)`,只算非 NULL 行,**不是除以總列數**
- `SUM` 對「全部都是 NULL」的組回傳 NULL,不是 0 — 報表要 `COALESCE(SUM(x), 0)`

```sql
-- 測試
CREATE TEMP TABLE t(x INT);
INSERT INTO t VALUES (1), (2), (3), (NULL);
SELECT COUNT(*), COUNT(x), SUM(x), AVG(x) FROM t;
-- 4 | 3 | 6 | 2.0     ← AVG 是 6/3
```

決定「NULL 要不要算進分母」是業務問題不是技術問題:`AVG(x)` 是「有填的人的平均」,`AVG(COALESCE(x, 0))` 是「把沒填當 0 的平均」,兩個都對,看你要回答哪個問題。

## 8.10 實戰:銷售報表

**為什麼這樣寫**:這張報表的粒度是「月 × 客戶」;營收要從 `order_items` 算 (單價 × 數量),而 `orders → order_items` 是 1:N,所以訂單數不能用 `COUNT(*)` (會算成明細列數),要用 `COUNT(DISTINCT o.id)`。這正是 8.2 決策表裡「先確認粒度與 1:N 關係」的實際應用。

![視窗函數 RANK() 範例](./screenshots/02-window-function.png)

```sql
SELECT
    DATE_TRUNC('month', o.ordered_at)::date    AS month,
    c.name                                     AS customer,
    COUNT(DISTINCT o.id)                       AS orders,
    SUM(oi.quantity * oi.unit_price)           AS revenue,
    SUM(oi.quantity * oi.unit_price)
       FILTER (WHERE o.status = 'completed')   AS rev_completed
FROM shop.orders o
JOIN shop.customers c   ON c.id = o.customer_id
JOIN shop.order_items oi ON oi.order_id = o.id
GROUP BY 1, 2
ORDER BY 1, 2;
```

如果之後再 JOIN 一張 1:N 的表 (例如出貨紀錄),`SUM(oi.quantity * oi.unit_price)` 就會膨脹 — 見 8.11 情境 C 的修法。

## 8.11 問題排查:情境模擬與排查順序

**為什麼要練這個**:聚合查詢的問題分兩類 — 一類會報錯 (`must appear in the GROUP BY`、`aggregate functions are not allowed in WHERE`),錯誤訊息很明確,難的是選對修法;另一類**完全不報錯,只是數字錯** (NULL 分母、JOIN 膨脹) 或**變慢** (溢出到磁碟)。第二類要靠對照與計畫才找得到。

> 🧪 所有情境都在 [`scripts/03-troubleshooting-scenarios.sql`](./scripts/03-troubleshooting-scenarios.sql) 裡,用自己的 demo 表 (最大 30 萬列),跑完自動清掉;刻意示範的錯誤都包在 `DO ... EXCEPTION` 裡,腳本本身不會中斷。建議一段一段執行,對照下面的說明。

### 通用排查順序:「報表數字不對 / 聚合查詢報錯或變慢」

順序的邏輯是**先確認問題定義、再找列數、最後才看效能**:

```
1. 先問「這一列代表什麼?」— 結果的粒度跟 GROUP BY 欄位對得上嗎?
   → 粒度沒定清楚,後面全部白做
2. 報錯的話,讀 SQLSTATE 42803 的訊息:是「欄位不在 GROUP BY」還是「WHERE 裡有聚合」?
   → 前者要決定:加進 GROUP BY / 用聚合函數 / 其實你要的是 DISTINCT ON
   → 後者搬到 HAVING
3. 數字不對:先查列數有沒有被複製
   → SELECT COUNT(*), COUNT(DISTINCT 主鍵);兩者不等就是 JOIN 膨脹
4. 數字不對:再查分母
   → SELECT COUNT(*), COUNT(col);差很多就是 NULL 被忽略;問清楚 NULL 該不該算
5. 用一個已知答案對帳 (某張訂單、某一天的總額)
6. 變慢:EXPLAIN (ANALYZE, BUFFERS)
   → HashAggregate 的 Batches > 1 / Disk Usage / temp written → work_mem 不夠
   → Sort Method: external merge → 同上
   → COUNT(DISTINCT) 在大表上 → 考慮預先彙總
7. 修:改寫 (先聚合再 JOIN / COALESCE / FILTER) > SET work_mem > 預先彙總表
8. 驗證:重跑對帳的那個已知答案;EXPLAIN 確認 Batches: 1
```

### 情境 A:`column "x" must appear in the GROUP BY clause`

**症狀**:想列出「每個分類有幾本書,順便顯示書名」,`SELECT category_id, title, COUNT(*) ... GROUP BY category_id` 直接報錯 `SQLSTATE 42803`。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | 讀錯誤訊息 | `column "books.title" must appear in the GROUP BY clause or be used in an aggregate function` — 訊息已經給了兩個選項 |
| 2 | 回到通用順序第 1 步:我要的一列代表什麼? | 「每個分類一列」→ 那 `title` 一組有好幾個,要哪一個? |

**根因**:`GROUP BY category_id` 之後一組對應多本書,`title` 沒有唯一值可顯示,PostgreSQL 不猜、直接拒絕。修法不是「讓錯誤消失」,而是**回答你到底要什麼**:

| 你要的其實是 | 修法 | 結果 |
|-------------|------|------|
| 每本書一列 (title 也是分組維度) | `GROUP BY category_id, title` | 8 列 |
| 每分類一列,順便看有哪些書 | `STRING_AGG(title, ' \| ' ORDER BY title)` | 5 列,書名串起來 |
| 每分類**最貴的那本** (要同一列的其他欄位) | `SELECT DISTINCT ON (category_id) ... ORDER BY category_id, price DESC` | 5 列;這不是聚合,是挑列 |

**驗證**:三種寫法都跑過,各自的列數符合預期。補充:`GROUP BY c.id` (主鍵) 時 `c.name` 可以直接選,不用列進 GROUP BY。

### 情境 B:平均評分 KPI 突然變高,但沒有人改程式

**症狀**:dashboard 的「平均評分」從 3.2 跳到 3.86;產品方很高興,你覺得不對勁 — 沒有人改 SQL。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | 同一條 `AVG(rating)` 重跑 | 3.86,確認不是快取 |
| 2 | 通用順序第 4 步:`COUNT(*)` 與 `COUNT(rating)` 並排 | 30 筆評論,**只有 7 筆有評分**,23 筆是 NULL |
| 3 | 問「什麼時候開始有 NULL」 | 改版後允許「只留言不評分」,而且低分的人傾向不評分 |

**根因**:`AVG` = `SUM(非 NULL)` / `COUNT(非 NULL)`。低分變成 NULL 後分子分母一起變,平均往上飄。這不是 bug,是**KPI 定義沒講清楚分母**。三個候選答案差很多:`AVG(rating)` = 3.86、`SUM / COUNT(*)` = 0.90、`AVG(COALESCE(rating,0))` = 0.90。

**修正**:跟業務確認定義 (通常是「有評分者的平均」),並且在 dashboard **旁邊放評分率** `COUNT(rating) / COUNT(*)` = 23.3%,讓看的人知道這個平均是 7 個人算出來的。

**驗證**:`AVG(rating) FILTER (WHERE rating IS NOT NULL)` 與 `AVG(rating)` 相同 (3.86),證明分母就是非 NULL 列數。延伸:`SUM` 對全 NULL 的組回 NULL 不是 0,報表要 `COALESCE(SUM(x), 0)`。

### 情境 C:月營收報表比財務對帳多出一倍 (JOIN 膨脹後才聚合)

**症狀**:營收報表加了「出貨」表之後,同一條 `SUM(amount)` 從 350 變成 500;金額欄位沒人動過。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | 只對 `items` 表 `SUM(amount)` (已知答案) | 350 |
| 2 | 加上 `COUNT(*)` 看報表查詢掃了幾列 | 客戶 A 的 `rows_seen = 4`,但 A 只有 2 筆 item |
| 3 | 通用順序第 3 步:`COUNT(*)` vs `COUNT(DISTINCT i.id)` | 5 vs 3 — **列被複製了** |
| 4 | 看 JOIN 的關係 | `orders → items` 1:N,`orders → shipments` 也是 1:N |

**根因**:兩個 1:N 一起 JOIN,每個 item 會跟同訂單的每個 shipment 配對 (2 × 2 = 4 列),金額跟著被複製;之後再 SUM 就膨脹。**先 JOIN 再聚合**是報表錯數最常見的原因。

**修正**:各自先在子查詢裡聚合到「訂單」粒度 (每邊每筆訂單只剩 1 列),再 JOIN:

```sql
FROM demo_orders o
JOIN (SELECT order_id, SUM(amount) AS item_total FROM demo_items     GROUP BY order_id) i ON i.order_id = o.id
JOIN (SELECT order_id, COUNT(*)    AS shipments  FROM demo_shipments GROUP BY order_id) s ON s.order_id = o.id
```

**驗證**:總和回到 350,而且出貨數也正確 (A = 2,B = 1)。

### 情境 D:WHERE 裡放聚合 / HAVING 裡放列條件

**症狀**:想找「訂單數 > 1 的客戶」,`WHERE COUNT(*) > 1` 報錯 `aggregate functions are not allowed in WHERE`;改到 `HAVING` 後又擔心「先分完 30 萬列的組再丟掉 90%」會很慢。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | 讀錯誤訊息 | `SQLSTATE 42803: aggregate functions are not allowed in WHERE` |
| 2 | 條件裡有聚合函數 → 搬到 `HAVING` | 客戶 1 有 2 筆訂單,結果正確 |
| 3 | 反過來,把列條件 `status = 'completed'` 放 `HAVING`,擔心效能 → 通用順序第 6 步:**看計畫,不要猜** | `Filter: (status = 'completed')` 出現在 **Seq Scan** 那一層,`Rows Removed by Filter: 135000` |
| 4 | 同一條件改寫在 `WHERE` 再 EXPLAIN | 計畫**一模一樣**,執行時間都約 11 ms |

**根因**:`WHERE` 在分組前逐列評估,沒有「組」可以 COUNT。反方向的擔心則是多慮:planner 會把**只牽涉分組欄位、不含聚合函數**的 `HAVING` 條件自動下推到掃描階段。

**修正 / 結論**:含聚合的條件放 `HAVING`;列條件放 `WHERE` 是為了**語意清楚**、以及未來欄位不在 GROUP BY 時不會報錯 — 不是為了效能。

**驗證**:兩份 EXPLAIN 的節點與 `Rows Removed by Filter` 相同。

### 情境 E:GROUP BY 大表突然變慢 — HashAggregate 溢出到磁碟

**症狀**:同一條「每個 session 的加總」查詢,資料成長到 30 萬列 / 10 萬個分組後執行時間跳升;監控看到 temp file I/O 同時飆高。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | `EXPLAIN (ANALYZE, BUFFERS)`,`work_mem` 是預設 4MB | `HashAggregate ... Batches: 5  Memory Usage: 8241kB  Disk Usage: 6944kB`,`Buffers: ... temp read=500 written=1233` |
| 2 | `pg_stat_database` 的 `temp_files` / `temp_bytes` | 持續增長,證實整個 DB 都在用 temp file |

**根因**:HashAggregate 要在記憶體裡為**每個分組**維護一個 bucket;10 萬個分組 × 每組的 key 與狀態 ≈ 11MB,超過 4MB 的 `work_mem` 就分成多個 batch 寫到磁碟再合併。資料量剛跨過門檻時就會「突然」變慢;`work_mem` 更小時 planner 甚至改走 `Sort + GroupAggregate`,`Sort Method: external merge Disk: 3736kB`,更慢 (213 ms)。

**修正**:只對這個 session / 這條查詢 `SET work_mem = '64MB'` (不要全域調,`work_mem` 是每個節點各拿一份、乘以並發數)。長期解法是預先彙總或 materialized view。

**驗證**:`Batches: 1  Memory Usage: 11281kB`,沒有 `Disk Usage`,`Buffers` 沒有 temp;本機 (資料都在 cache) 從 87 ms 降到 69 ms — 在真實磁碟上差距會大得多,溢出的成本主要在 I/O。

## 章節腳本

- [`scripts/01-aggregation-basics.sql`](./scripts/01-aggregation-basics.sql) — 聚合函數與 GROUP BY / HAVING
- [`scripts/02-filter-and-multilevel.sql`](./scripts/02-filter-and-multilevel.sql) — FILTER、ROLLUP、CUBE、GROUPING SETS
- [`scripts/03-troubleshooting-scenarios.sql`](./scripts/03-troubleshooting-scenarios.sql) — 8.11 五個排查情境 (可重現)

---

下一章 ➡ [第 9 章:索引](../09-indexes/)
