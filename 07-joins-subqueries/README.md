# 第 7 章 JOIN 與子查詢

> 目標:理解資料為什麼要拆成多張表再「拼回來」、各種 JOIN 的差異與使用時機、**動手寫查詢前該怎麼選 JOIN / 子查詢 / EXISTS / LATERAL**,以及當 JOIN 給出「錯的答案但不報錯」時怎麼有系統地排查。
>
> 🧰 **前置準備**:本章範例使用 `bookstore` 資料庫 (`shop` schema 與範例資料)。尚未建立的話,先在 repo 根目錄執行 `psql -d postgres -f setup/01-create-tutorial-db.sql` 與 `psql -d bookstore -f setup/02-sample-data.sql`,詳見[第 1 章 1.8 節](../01-installation/README.md#18-建立教學用資料庫)。
>
> 📐 **本章讀法**:每一節都先講「為什麼會需要這個」,再講「怎麼做」。7.2 是動筆前的決策清單,7.12 是四個可以實際重現的故障情境與排查順序 — JOIN 的錯誤絕大多數**不會報錯,只會給錯的數字**,所以 7.12 的排查習慣比語法更重要。

## 7.1 為什麼需要 JOIN

**沒有 JOIN 會發生什麼**:第 5 章把書店拆成 `books`、`authors`、`categories`、`orders`、`order_items`… 七張表,是為了避免重複 (作者改名只改一處) 與維持一致性。代價是:任何一份有意義的報表 —「哪本書、誰寫的、誰買的、花了多少」— 資料都散在三四張表裡。沒有 JOIN,你得先 `SELECT` 一張表,再拿著 id 一張張查,在應用程式裡自己拼。

**JOIN 怎麼解決**:JOIN 讓資料庫在**一次查詢**裡依「配對條件」(通常是 FK = PK) 把多張表的列橫向接起來,由 planner 決定最有效率的接法 (Hash / Merge / Nested Loop)。你描述「要什麼」,不描述「怎麼拼」。

**但 JOIN 的錯誤很安靜**:少寫一個條件、條件放錯位置、兩個一對多同時接 — 查詢照樣成功,只是列數與金額悄悄變了。這也是本章要花整整一節 (7.12) 講排查的原因。

## 7.2 設計前的決策條件與考量重點

**為什麼要先想再寫**:同一個問題通常有 JOIN、子查詢、EXISTS、CTE、LATERAL 好幾種寫法,結果一樣,但正確性邊界 (NULL、重複) 與效能 (掃幾次表) 差很多。先弄清楚資料的**基數關係** (一對一、一對多、多對多) 與你要的**結果粒度** (一列代表一張訂單?還是一筆明細?),再選寫法,能避掉 7.12 全部四種故障。

### 先確認的前提

| 問題 | 為什麼重要 | 怎麼確認 |
|------|-----------|---------|
| **結果的一列代表什麼?** | 結果粒度決定要 JOIN 到哪一層。要「每張訂單的金額」卻 JOIN 到 `order_items`,一張訂單就變成多列,SUM 直接錯 (7.12 情境 A) | 先用一句話寫下「一列 = 一個 ___」,再看每個 JOIN 會不會讓它變多列 |
| **兩表之間是 1:1、1:N 還是 N:M?** | 1:N 的 JOIN 會複製「1」那邊的列;兩個 1:N 同時接就是 N×M 的膨脹 | 看 FK 方向與 UNIQUE 約束 (`\d shop.order_items`);不確定就 `SELECT fk, COUNT(*) ... GROUP BY fk HAVING COUNT(*) > 1` |
| **「沒有對應」的列要不要留?** | 這決定 INNER 還是 OUTER。「所有作者與各自的書」要留沒書的作者 → LEFT;「有書的作者」→ INNER | 問業務:清單裡缺了某個人是 bug 還是預期? |
| **關聯欄位允許 NULL 嗎?** | NULL 在 JOIN 條件永遠不相等;在 `NOT IN` 子查詢裡一個 NULL 就讓整個查詢回 0 列 (7.12 情境 C) | `\d` 看 `NOT NULL`;`SELECT COUNT(*) WHERE col IS NULL` |
| **表有多大?會長多大?** | 相關子查詢是「外層每列跑一次內層」,小表沒感覺,幾萬 × 幾十萬就是分鐘級 (7.12 情境 D) | `pg_stat_user_tables.n_live_tup`;想一年後的規模 |
| **關聯欄位有索引嗎?** | Nested Loop 型的 JOIN / 子查詢每一輪都要在內層找列,沒索引就是每輪全表掃描 | `\d 表名` 看 FK 欄位有沒有索引 (PostgreSQL **不會**自動為 FK 建索引) |

### 決策對照:什麼情況選什麼

| 需求長這樣 | 選擇 | 理由 |
|-----------|------|------|
| 要把兩表的欄位放在同一列輸出 | `JOIN` | 只有 JOIN 能「橫向」接欄位;子查詢/EXISTS 只能過濾 |
| 只是「A 裡有沒有對應的 B」,不需要 B 的欄位 | `EXISTS` / `NOT EXISTS` | 找到第一筆就停,不會複製列,NULL 語意正確 |
| 「A 不在 B 裡」 | `NOT EXISTS` (不要用 `NOT IN`) | `NOT IN` 遇到子查詢含 NULL 會整個失效;`NOT EXISTS` 不會 |
| 子查詢值來自固定小清單 (`IN (1,2,3)`) | `IN` | 可讀性最好,planner 會轉成等值比對 |
| 要「所有 A」,即使沒對應的 B | `LEFT JOIN`,且 B 的過濾條件寫在 `ON` | 條件寫在 `WHERE` 會把 OUTER 退化成 INNER (7.12 情境 B) |
| 兩邊都要保留沒對應的列 (對帳、差異比對) | `FULL JOIN` + `COALESCE` | 一次看出「只在左」「只在右」「兩邊都有」 |
| 每組取前 N 筆 (每位客戶最近 2 筆訂單) | `LATERAL` + `ORDER BY ... LIMIT N` | 子查詢能參照外層列,而且 LIMIT 在每組內生效;比 Window Function 直覺、常常也更快 |
| 同一張表的階層關係 (員工 → 主管) | 自我 JOIN (兩個別名) | 就是普通 JOIN,只是兩邊是同一張表;多層則用第 14 章遞迴 CTE |
| 要對「每一列」算一個統計值 (每位作者幾本書) | `JOIN + GROUP BY`,或子查詢先聚合再 JOIN | 一次掃過明細表;相關子查詢要掃 N 次 |
| 兩個結果集要合併成一欄 (作者名 + 客戶名) | `UNION ALL` (確定無重複或不在乎) / `UNION` (要去重) | `UNION` 多一道排序去重;能用 `ALL` 就用 |
| 查詢用了很多 `OR`、跨不同欄位 | 拆成多段 `UNION ALL` | 每段能各自用索引;`OR` 常讓 planner 放棄索引 |
| 中間結果要在同一查詢裡用多次、或要可讀 | CTE (`WITH`,第 14 章) | 命名中間結果;PG 12+ 預設會 inline,效能與子查詢相當 |
| 同一個 JOIN 每個頁面都在跑、資料極少變 | 考慮反正規化 (冗餘欄位 / Materialized View,第 10 章) | 讀取省掉 JOIN;代價是寫入時要維護一致性 (第 12 章 Trigger) |

### 上線/實務考量

- **planner 怎麼選 JOIN 演算法,你怎麼配合它**:`Hash Join` (一邊建 hash 表,另一邊掃一次;大表對大表的等值 JOIN 首選)、`Merge Join` (兩邊都排序後合併;有索引順序或本來就要排序時)、`Nested Loop` (外層每列去內層找;**外層小、內層有索引**時最快,否則最慢)。看到 `Nested Loop` 配 `Seq Scan` 在內層,幾乎一定是缺索引 (7.12 情境 D)。
- **FK 欄位一定要有索引**:PostgreSQL 建 FK 不會自動建索引。沒索引的 FK 讓 JOIN 走 Nested Loop + Seq Scan,也讓父表 DELETE 時逐列全表掃描子表。
- **JOIN 順序不用你排**:planner 會依統計資料重排 (`join_collapse_limit` 預設 8 張表以內)。超過 8 張表或統計不準時,順序可能不理想 — 先 `ANALYZE`,再考慮拆 CTE 或 `MATERIALIZED`。
- **先聚合再 JOIN,不要先 JOIN 再聚合**:多個 1:N 關係時,各自 `GROUP BY` 成一列再接,既正確也少複製資料。
- **COUNT(\*) 與 COUNT(DISTINCT 主鍵) 是最便宜的健康檢查**:寫完任何多表 JOIN,先比這兩個數字;不相等就代表有列被複製了。
- **`SELECT *` 在 JOIN 裡是陷阱**:同名欄位 (`id`, `name`, `created_at`) 會互相遮蔽,ORM 與報表工具拿到的可能是另一張表的值。永遠明確列出欄位並取別名。

## 7.3 JOIN 類型

**為什麼有這麼多種**:差別只有一件事 —「配不到對象的列要不要留、留哪一邊」。決定權在業務需求 (7.2 的第 3 個前提),不在語法。

![INNER JOIN 多表查詢範例](./screenshots/01-inner-join.png)

```
A ── INNER JOIN ── B     :兩邊都有對應的列
A ── LEFT  JOIN ── B     :左邊全留,右邊沒對應補 NULL
A ── RIGHT JOIN ── B     :右邊全留,左邊沒對應補 NULL
A ── FULL  JOIN ── B     :兩邊全留,沒對應的補 NULL
A ── CROSS JOIN ── B     :笛卡兒積 (m × n)
```

```sql
-- INNER JOIN (預設):只要「有作者的書」
SELECT b.title, a.name
FROM shop.books b
INNER JOIN shop.authors a ON a.id = b.author_id;

-- LEFT JOIN:要「所有作者」,沒書的也列出來 (title 為 NULL)
SELECT a.name, b.title
FROM shop.authors a
LEFT JOIN shop.books b ON b.author_id = a.id;

-- FULL JOIN:對帳用,兩邊沒對應的都看得到
SELECT COALESCE(a.name, '(無作者)') AS name,
       COALESCE(b.title,'(無書)')   AS title
FROM shop.authors a
FULL JOIN shop.books b ON b.author_id = a.id;
```

`RIGHT JOIN` 就是把兩表對調的 `LEFT JOIN`,實務上幾乎都改寫成 LEFT 以維持「左邊是主體」的閱讀習慣。`CROSS JOIN` 很少刻意用 (產生所有組合,例如「每個日期 × 每個分類」的骨架);**不小心寫出來**倒是常見 (7.12 情境 A-2)。

## 7.4 多表 JOIN

**為什麼**:真實報表很少只碰兩張表。「訂單明細」要同時知道客戶是誰、買了什麼書、單價多少 — 四張表。多表 JOIN 就是把 7.3 的動作串起來,每個 `JOIN ... ON` 接上一張表。

**怎麼做**:從「結果粒度」那張表出發 (這裡一列 = 一筆明細,所以主體是 `order_items` 附著的 `orders`),沿著 FK 一張張接。

![LEFT JOIN 含聚合範例](./screenshots/02-left-join-aggregate.png)

```sql
-- 訂單 + 客戶 + 訂單明細 + 書
SELECT
    o.id            AS order_id,
    c.name          AS customer,
    o.status,
    b.title,
    oi.quantity,
    oi.unit_price,
    oi.quantity * oi.unit_price AS subtotal
FROM shop.orders o
JOIN shop.customers   c  ON c.id = o.customer_id
JOIN shop.order_items oi ON oi.order_id = o.id
JOIN shop.books       b  ON b.id = oi.book_id
ORDER BY o.id, b.title;
```

注意這裡 `customers` 與 `books` 都是 N:1 (多筆明細對一個客戶/一本書),不會複製列;`order_items` 是 1:N,所以結果一列是一筆明細而不是一張訂單 — 這正是 7.2 第 1 個前提要先想清楚的事。

## 7.5 USING 與自然 JOIN

**為什麼**:當兩表的關聯欄位**同名**時,`ON a.book_id = b.book_id` 有點囉嗦,`USING (book_id)` 更短,而且輸出只會有一個 `book_id` 欄位 (不會左右各一個)。

**怎麼做與限制**:

```sql
-- 同名 join 欄位可以用 USING
SELECT * FROM shop.order_items JOIN shop.books USING (book_id);
-- 等價於 ON order_items.book_id = books.book_id (但 books 沒有此欄,所以不會成功)
-- 此例僅作語法示範
```

`NATURAL JOIN` 更進一步,自動用**所有**同名欄位配對 — 這正是它危險的地方:兩表都有 `created_at` 或 `name`,就會被拿去配對,結果悄悄變成空的。實務上不建議使用。

## 7.6 自我 JOIN

**為什麼**:階層關係 (員工的主管也是員工、分類的父分類也是分類) 存在同一張表裡,要把「某列」和「它參照的另一列」並排顯示,就得把同一張表當兩張表用。

**怎麼做**:給同一張表兩個別名,一個代表「員工」,一個代表「主管」。用 LEFT JOIN 是因為 CEO 沒有主管 (`manager_id` 為 NULL),INNER JOIN 會把 CEO 排除。

```sql
SELECT
    e.name           AS employee,
    e.role,
    m.name           AS manager
FROM shop.employees e
LEFT JOIN shop.employees m ON m.id = e.manager_id
ORDER BY e.id;
```

只能看一層;要展開整棵組織樹是第 14 章遞迴 CTE 的工作。

## 7.7 子查詢的三種位置

**為什麼需要子查詢**:有些問題分兩步比較自然 —「先算出每個分類有幾本書,再挑出超過 1 本的分類」、「先找出名字 P 開頭的分類 id,再用它篩書」。子查詢就是把「第一步」寫在查詢裡面,讓第二步使用它。

**怎麼做**:依它放的位置,子查詢有三種角色與限制:

```sql
-- (1) 在 SELECT 子句 (純量子查詢,只能回一列一欄)
--     用途:順手帶一個值;注意它對外層每一列都會執行一次 (見 7.9)
SELECT
    b.title,
    (SELECT name FROM shop.authors WHERE id = b.author_id) AS author
FROM shop.books b;

-- (2) 在 FROM 子句 (派生表 / inline view)
--     用途:先聚合、再對聚合結果做條件或 JOIN — 「先聚合再 JOIN」就是靠它
SELECT t.category, t.cnt
FROM (
    SELECT c.name AS category, COUNT(*) AS cnt
    FROM shop.books b
    JOIN shop.categories c ON c.id = b.category_id
    GROUP BY c.name
) t
WHERE t.cnt > 1;

-- (3) 在 WHERE 子句
--     用途:用另一個查詢的結果當過濾清單
SELECT title FROM shop.books
WHERE category_id IN (SELECT id FROM shop.categories WHERE name LIKE 'P%');
```

## 7.8 EXISTS / NOT EXISTS

**為什麼**:「有訂單的客戶」這種問題,你其實**不需要訂單的任何欄位**,只需要知道「有沒有」。用 JOIN 會把每張訂單都接出來 (客戶被複製 N 次,還得 DISTINCT);用 `IN (SELECT customer_id ...)` 語意上可以,但反向的 `NOT IN` 遇到 NULL 會失效 (7.12 情境 C)。`EXISTS` 正好是「找到一筆就停、不複製列、NULL 不會出事」。

**怎麼做**:子查詢的 SELECT 列表寫什麼都無所謂 (慣例寫 `1`),只看有沒有列。

```sql
-- 有訂單的客戶
SELECT name FROM shop.customers c
WHERE EXISTS (SELECT 1 FROM shop.orders o WHERE o.customer_id = c.id);

-- 從未下訂單的客戶
SELECT name FROM shop.customers c
WHERE NOT EXISTS (SELECT 1 FROM shop.orders o WHERE o.customer_id = c.id);
```

planner 會把 `EXISTS` 轉成 Semi Join、`NOT EXISTS` 轉成 Anti Join,效能與 JOIN 相當且通常優於 `IN`。

## 7.9 相關子查詢

**為什麼要認識它**:子查詢內部參照外層欄位 (下例的 `a.id`) 時,就是「相關子查詢」。它很直覺 —「對每位作者,數一下他的書」— 但執行模型是**外層每一列跑一次內層**,資料一大就是 7.12 情境 D 的災難。認識它是為了知道何時該改寫。

**怎麼做**:

```sql
-- 每位作者的書籍數
SELECT
    a.name,
    (SELECT COUNT(*) FROM shop.books b WHERE b.author_id = a.id) AS book_count
FROM shop.authors a;
```

> ⚠️ 相關子查詢對每一外層列都會跑一次,資料量大時效能差。改用 JOIN + GROUP BY 通常更快 (`EXPLAIN` 裡看到 `SubPlan` 且 `loops=` 很大就是警訊)。

## 7.10 LATERAL JOIN

**為什麼**:「每位客戶最近 2 筆訂單」這種 **每組 Top-N** 需求,普通子查詢做不到 — FROM 子句裡的子查詢看不到外層的 `c.id`,`LIMIT 2` 也只會對整體生效。`LATERAL` 解除這個限制:子查詢能參照前面表的欄位,並且**對每一列各自執行**,所以 `ORDER BY ... LIMIT` 是「每組內」的。

**怎麼做**:用 `LEFT JOIN LATERAL (...) ON TRUE`,LEFT 是為了沒訂單的客戶也保留。

```sql
-- 每位客戶最近 2 筆訂單
SELECT c.name, t.order_id, t.ordered_at, t.total
FROM shop.customers c
LEFT JOIN LATERAL (
    SELECT id AS order_id, ordered_at, total
    FROM shop.orders
    WHERE customer_id = c.id
    ORDER BY ordered_at DESC
    LIMIT 2
) t ON TRUE
ORDER BY c.name, t.ordered_at DESC;
```

它本質上也是「外層每列跑一次內層」,所以 `orders(customer_id, ordered_at)` 上要有索引,每輪才是索引掃描。另一種解法是第 14 章的 `ROW_NUMBER() OVER (PARTITION BY ...)`。

## 7.11 集合運算

**為什麼**:JOIN 是「橫向」接欄位;集合運算是「縱向」疊列 — 兩個結構相同的結果集合併、取交集、取差集。典型用途:把作者與客戶合成一份「所有人名」清單、找兩份名單的重疊、找「A 有 B 沒有」(從沒賣出過的書)。

**怎麼做**:各段 SELECT 的欄位數與型別要一致。

```sql
-- UNION:聯集 (預設去重)
SELECT name FROM shop.authors
UNION
SELECT name FROM shop.customers;

-- UNION ALL:保留重複 (較快,少一道排序去重)
SELECT name FROM shop.authors
UNION ALL
SELECT name FROM shop.customers;

-- INTERSECT:交集
SELECT email FROM shop.authors WHERE email IS NOT NULL
INTERSECT
SELECT email FROM shop.customers;

-- EXCEPT:差集
SELECT id FROM shop.books
EXCEPT
SELECT book_id FROM shop.order_items;  -- 從沒賣出過的書
```

`EXCEPT` 與 `NOT EXISTS` 常能互換;差集是集合語意 (會去重、比整列),`NOT EXISTS` 保留原列且可以帶其他欄位。

## 7.12 問題排查:情境模擬與排查順序

**為什麼要練這個**:JOIN 與子查詢的問題有個共同特徵 — **查詢成功、沒有錯誤訊息,只是數字不對或列數不對**。它們常常在報表被質疑時才被發現,而那時候查詢已經上線幾個月。能不能快速判斷「是資料的問題還是查詢的問題」,靠的是一套固定的檢查順序。

> 🧪 所有情境都在 [`scripts/04-troubleshooting-scenarios.sql`](./scripts/04-troubleshooting-scenarios.sql) 裡,用自己的 demo 表 (前綴 `t7_`),跑完自動清掉。建議一段一段執行,對照下面的說明。

### 通用排查順序:「JOIN 結果不對 / 太慢」

順序的邏輯是**先確認事實 (列數) 再看語意,最後才看效能**:

```
1. 先量「應該有幾列」
   → 結果粒度是什麼?母體表 COUNT(*) 是多少?這是後面所有比對的基準
2. 比 COUNT(*) 與 COUNT(DISTINCT 主鍵)
   → 不相等 = 有列被複製 → 找出哪個 JOIN 是 1:N 或 N:M (情境 A)
3. 列數比母體少?
   → OUTER JOIN 的 WHERE 是否過濾了右表欄位 (情境 B)
   → JOIN 欄位是否有 NULL (NULL 永遠配不上)
4. 用了 NOT IN?
   → 子查詢結果有沒有 NULL (情境 C);一律改 NOT EXISTS
5. 拿一個具體 id 手動驗算
   → 挑一張訂單,用最笨的方式 (單表 SELECT) 算出正確答案,跟 JOIN 結果比
6. 結果對了但慢:EXPLAIN (ANALYZE, BUFFERS)
   → SubPlan + loops=N 很大 → 相關子查詢逐列執行 (情境 D)
   → Nested Loop 內層是 Seq Scan → 關聯欄位缺索引
   → rows 估計 vs 實際差很多 → ANALYZE
7. 才動手修
   → 先聚合再 JOIN > 條件搬到 ON > NOT IN 改 NOT EXISTS > 子查詢改 JOIN > 補索引
8. 驗證:修完再跑步驟 1、2、5 的數字,確認一致
```

### 情境 A:報表金額比實際多出好幾倍 (多對多 JOIN 造成列數膨脹)

**症狀**:「各訂單金額」報表原本正確;為了加上付款方式,多 JOIN 一張 `payments`,訂單 1 的金額從 1,850 變成 3,700,訂單 4 從 860 變成 2,580。沒有任何錯誤訊息。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | 用單表算「真相」:`orders JOIN order_items` 直接 SUM | 訂單 1 = 1850、訂單 4 = 860 |
| 2 | 在有問題的查詢加上 `COUNT(*)` 與 `COUNT(DISTINCT oi.id)` | 訂單 1:`joined_rows = 4`,`real_item_rows = 2`;訂單 4:6 vs 2 — **列被複製了** |
| 3 | 找出哪張表造成複製:訂單 1 有 2 筆付款、訂單 4 有 3 筆 | 膨脹倍數 = 付款筆數 |

**根因**:`order_items` 與 `payments` 都是「一張訂單對多筆」。兩個 1:N 同時 JOIN 到 `orders`,每筆明細會和每筆付款配對一次,明細被複製成 (付款筆數) 份,SUM 就乘上了付款筆數。

**修正**:先各自聚合成「每張訂單一列」,再 JOIN:

```sql
SELECT o.id, i.item_total, p.paid_total
FROM shop.orders o
JOIN (SELECT order_id, SUM(quantity * unit_price) AS item_total
      FROM shop.order_items GROUP BY order_id) i ON i.order_id = o.id
JOIN (SELECT order_id, SUM(amount) AS paid_total
      FROM t7_payments GROUP BY order_id)  p ON p.order_id = o.id;
```

**驗證**:訂單 1 `item_total = 1850`、訂單 4 `860`,與步驟 1 的真相一致。

**同類問題 A-2:忘記 JOIN 條件 → 笛卡兒積**。`FROM orders o, order_items oi` 沒寫 WHERE,6 張訂單 × 8 筆明細 = 48 列而不是 8 列。列數突然變成兩表列數的乘積,就是這個。用明確的 `JOIN ... ON` 語法,少寫 ON 會直接報語法錯誤,比逗號寫法安全。

### 情境 B:「沒有書的作者」從報表上消失了 (LEFT JOIN 退化成 INNER)

**症狀**:要列出所有作者與各自「單價 > 400 的書」,用了 `LEFT JOIN`,但 Carl Sagan (沒有符合的書) 不見了 — 6 位作者只出現 5 位。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | 通用順序第 1 步:母體 `SELECT COUNT(*) FROM authors` | 6 |
| 2 | 結果比母體少 → 通用順序第 3 步:檢查 WHERE 有沒有右表欄位 | `WHERE b.price > 400` — `b` 是右表 |

**根因**:LEFT JOIN 先把沒書的作者補成 `b.* = NULL`,接著 `WHERE b.price > 400` 對 NULL 判斷為 UNKNOWN,整列被丟掉。**任何對右表欄位的 WHERE 條件都會把 LEFT JOIN 變成 INNER JOIN**,除非條件本身允許 NULL (`OR b.id IS NULL`)。

**修正**:右表的條件放進 `ON`,讓它在「配對階段」生效而不是「配對後過濾」:

```sql
SELECT a.name, b.title, b.price
FROM shop.authors a
LEFT JOIN shop.books b ON b.author_id = a.id AND b.price > 400;
```

**驗證**:結果 7 列 (Yuval Harari 有兩本),`COUNT(DISTINCT a.id) = 6` = 作者總數,Carl Sagan 出現且 title 為 NULL。

### 情境 C:NOT IN 查「從未下單的客戶」回傳 0 列 (子查詢含 NULL)

**症狀**:5 位客戶只有 2 位下過單,`WHERE id NOT IN (SELECT customer_id FROM orders)` 卻回傳 0 列。同事改成 `NOT EXISTS` 就正常了,但沒人知道為什麼。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | 母體與子查詢各幾列?子查詢有 NULL 嗎? | `customers_total = 5`、`orders_total = 3`、`orders_with_null_customer = 1` (一筆訪客訂單) |
| 2 | 通用順序第 4 步:用了 `NOT IN` + 子查詢含 NULL | 命中 |

**根因**:`x NOT IN (1, 2, NULL)` 展開成 `x <> 1 AND x <> 2 AND x <> NULL`,最後一項永遠是 UNKNOWN,整個 AND 不可能為 TRUE → 0 列。子查詢只要混進一個 NULL,`NOT IN` 就整個失效,而且完全不報錯。(`IN` 沒這個問題,因為 OR 裡有一個 TRUE 就夠了。)

**修正**:改用 `NOT EXISTS`;或至少在子查詢排除 NULL:

```sql
SELECT c.id, c.name FROM shop.customers c
WHERE NOT EXISTS (SELECT 1 FROM t7_orders o WHERE o.customer_id = c.id);
```

**驗證**:回傳 3 位客戶 (陳大文、林志玲、張三豐),與「5 − 2 位下過單」一致。

### 情境 D:一條「每位客戶的訂單數」查詢跑好幾秒 (相關子查詢逐列執行)

**症狀**:2,000 位客戶、10 萬張訂單,`SELECT c.id, (SELECT COUNT(*) FROM orders o WHERE o.customer_id = c.id) FROM customers c` 要 **3.85 秒**。上線初期只有幾十位客戶時完全沒感覺。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | 結果正確 → 通用順序第 6 步:`EXPLAIN (ANALYZE, BUFFERS)` | `SubPlan 1` 底下 `Seq Scan on t7_big_orders ... loops=2000` |
| 2 | 看內層是什麼掃描 | `Seq Scan` — 每一輪都全表掃描 10 萬列 |

**根因**:相關子查詢對外層每一列各執行一次 (loops = 客戶數),每次都是對 orders 的全表掃描,成本 = 客戶數 × 訂單數 = 2 億次比對。

**修正 1 (首選)**:改寫成 JOIN + GROUP BY,orders 只掃一次:

```sql
SELECT c.id, COUNT(o.id) AS order_count
FROM t7_big_customers c
LEFT JOIN t7_big_orders o ON o.customer_id = c.id
GROUP BY c.id;
```

計畫變成 `Hash Right Join` + `HashAggregate`,**3,850ms → 20ms**。

**修正 2 (若必須保留子查詢寫法)**:在 `orders(customer_id)` 建索引,每輪從 Seq Scan 變成 `Bitmap Index Scan`,3,850ms → 32ms。仍然是 2,000 次 loop,只是每次便宜很多;資料再大十倍,修正 1 仍會明顯勝出。

**驗證**:三種寫法 `SUM(order_count) = 100000`,結果一致;`EXPLAIN` 裡不再有 `loops=2000` 的 `Seq Scan`。

## 章節腳本

- [`scripts/01-inner-outer.sql`](./scripts/01-inner-outer.sql) — 各種 JOIN
- [`scripts/02-subqueries.sql`](./scripts/02-subqueries.sql) — 子查詢、EXISTS、相關子查詢
- [`scripts/03-lateral-set-ops.sql`](./scripts/03-lateral-set-ops.sql) — LATERAL 與集合運算
- [`scripts/04-troubleshooting-scenarios.sql`](./scripts/04-troubleshooting-scenarios.sql) — 7.12 四個排查情境 (可重現)

---

下一章 ➡ [第 8 章:聚合與群組](../08-aggregations-grouping/)
