-- =====================================================================
-- 第 8 章 / 問題排查情境模擬 (對應 README 8.11 節)
-- 用法:psql -d bookstore -f 03-troubleshooting-scenarios.sql
--
-- 每個情境都用自己的 demo 表,跑完會清掉,不影響 bookstore 其他章節。
-- 建議搭配 README 8.11 的「排查順序」逐段執行、對照輸出。
-- 刻意示範的錯誤都包在 DO ... EXCEPTION 裡,腳本本身不會噴 ERROR。
-- =====================================================================
SET search_path TO shop, public;

-- =====================================================================
\echo ''
\echo '════ 情境 A:column "x" must appear in the GROUP BY clause ════'
-- 症狀:想列出「每個分類有幾本書,順便顯示書名」,結果直接報錯
-- =====================================================================

\echo '── A 重現 (錯誤被攔下並印出訊息) ──'
DO $$
BEGIN
    PERFORM category_id, title, COUNT(*) FROM books GROUP BY category_id;
    RAISE NOTICE '不應該執行到這裡';
EXCEPTION WHEN grouping_error THEN
    RAISE NOTICE '❌ SQLSTATE=% : %', SQLSTATE, SQLERRM;
END$$;

-- 根因:GROUP BY category_id 之後,一個群組對應多本書,title 不知道該顯示哪一個。
--       PostgreSQL 不猜,直接拒絕。修法取決於「你到底想要什麼」:

\echo '── A 修法 1:title 也是分組維度 → 加進 GROUP BY (結果是每本書一列) ──'
SELECT category_id, title, COUNT(*) AS cnt
FROM books
GROUP BY category_id, title
ORDER BY category_id, title
LIMIT 4;

\echo '── A 修法 2:只是想「順便看一個代表值」→ 用聚合函數 (STRING_AGG / MAX) ──'
SELECT category_id,
       COUNT(*) AS book_count,
       STRING_AGG(title, ' | ' ORDER BY title) AS titles
FROM books
GROUP BY category_id
ORDER BY category_id;

\echo '── A 修法 3:要的是「每個分類最貴的那本」→ 不是聚合,是 DISTINCT ON ──'
SELECT DISTINCT ON (category_id)
       category_id, title, price
FROM books
ORDER BY category_id, price DESC;

\echo '── A 補充:GROUP BY 主鍵時,同表其他欄位可以直接 SELECT (functional dependency) ──'
SELECT c.id, c.name, COUNT(b.id) AS book_count
FROM categories c
LEFT JOIN books b ON b.category_id = c.id
GROUP BY c.id            -- c.name 不用列,因為 c.id 是 PK
ORDER BY c.id;

-- =====================================================================
\echo ''
\echo '════ 情境 B:平均評分 KPI 突然變高,但沒有人改程式 ════'
-- 症狀:dashboard 的「平均評分」從 3.2 跳到 3.9;產品方很高興,你覺得不對勁
-- =====================================================================
DROP TABLE IF EXISTS reviews;
CREATE TABLE reviews (
    id      SERIAL PRIMARY KEY,
    book_id INT NOT NULL,
    rating  INT              -- NULL = 使用者只留言沒評分 (改版後新增的行為)
);
-- 改版前:每筆都有評分
INSERT INTO reviews (book_id, rating) VALUES
    (1, 5), (1, 4), (1, 1), (1, 2), (1, 4),
    (2, 3), (2, 2), (2, 5), (2, 3), (2, 3);
\echo '── B 改版前:AVG = 3.2 ──'
SELECT COUNT(*) AS reviews, COUNT(rating) AS rated, AVG(rating)::NUMERIC(4,2) AS avg_rating
FROM reviews;

-- 改版後:允許「只留言不評分」,而且大量低分使用者選擇不評分
INSERT INTO reviews (book_id, rating)
SELECT 1, NULL FROM generate_series(1, 20);
UPDATE reviews SET rating = NULL WHERE rating <= 2;   -- 模擬:低分的人改成只留言

\echo '── B 改版後:排查步驟 1:同一條 SQL,AVG 變 3.86 ──'
SELECT AVG(rating)::NUMERIC(4,2) AS avg_rating FROM reviews;

\echo '── B 排查步驟 2:把 COUNT(*) 與 COUNT(rating) 並排看 — 30 筆只有 7 筆有評分 ──'
SELECT COUNT(*)      AS reviews_total,
       COUNT(rating) AS rated,
       COUNT(*) - COUNT(rating) AS unrated,
       SUM(rating)   AS sum_rating,
       AVG(rating)::NUMERIC(4,2)                          AS avg_ignores_null,
       (SUM(rating)::NUMERIC / COUNT(*))::NUMERIC(4,2)    AS avg_over_all_rows,
       AVG(COALESCE(rating, 0))::NUMERIC(4,2)             AS avg_null_as_zero
FROM reviews;

-- 根因:AVG / SUM / COUNT(col) 都「忽略 NULL」。AVG 是 SUM(非 NULL) / COUNT(非 NULL),
--       不是除以總列數。低分使用者變成 NULL 後,分母跟著縮小,平均自然往上飄。
--       這不是 bug,是定義問題:「平均評分」的分母到底是誰?

\echo '── B 修正:KPI 明確定義分母,並把「評分率」一起放上 dashboard ──'
SELECT AVG(rating)::NUMERIC(4,2)                                   AS avg_of_rated,
       ROUND(100.0 * COUNT(rating) / COUNT(*), 1) || '%'           AS rating_coverage,
       AVG(rating) FILTER (WHERE rating IS NOT NULL)::NUMERIC(4,2) AS same_thing_explicit
FROM reviews;

\echo '── B 延伸:SUM 對「全部是 NULL」的群組回 NULL,不是 0 — 報表要 COALESCE ──'
SELECT book_id, SUM(rating) AS raw_sum, COALESCE(SUM(rating), 0) AS safe_sum
FROM (VALUES (1, 5), (1, NULL), (3, NULL)) AS v(book_id, rating)
GROUP BY book_id ORDER BY book_id;

-- =====================================================================
\echo ''
\echo '════ 情境 C:月營收報表比財務對帳多出一倍 (JOIN 膨脹後才聚合) ════'
-- 症狀:加了「出貨」表之後,同一條營收查詢數字變大;沒有人動過金額
-- =====================================================================
DROP TABLE IF EXISTS demo_orders, demo_items, demo_shipments;
CREATE TABLE demo_orders    (id INT PRIMARY KEY, customer TEXT);
CREATE TABLE demo_items     (id SERIAL PRIMARY KEY, order_id INT, amount NUMERIC(10,2));
CREATE TABLE demo_shipments (id SERIAL PRIMARY KEY, order_id INT, carrier TEXT);
INSERT INTO demo_orders VALUES (1, 'A'), (2, 'B');
INSERT INTO demo_items (order_id, amount) VALUES (1, 100), (1, 50), (2, 200);
-- 訂單 1 分兩批出貨,訂單 2 一批
INSERT INTO demo_shipments (order_id, carrier) VALUES (1, 'DHL'), (1, 'UPS'), (2, 'DHL');

\echo '── C 正確答案 (只看 items):350 ──'
SELECT SUM(amount) AS revenue FROM demo_items;

\echo '── C 排查步驟 1:加了 shipments 之後的報表:500 ──'
SELECT o.customer, SUM(i.amount) AS revenue, COUNT(*) AS rows_seen
FROM demo_orders o
JOIN demo_items i     ON i.order_id = o.id
JOIN demo_shipments s ON s.order_id = o.id
GROUP BY o.customer ORDER BY o.customer;

\echo '── C 排查步驟 2:COUNT(*) vs COUNT(DISTINCT item id) — 列數被複製了 ──'
SELECT COUNT(*) AS joined_rows, COUNT(DISTINCT i.id) AS real_items
FROM demo_orders o
JOIN demo_items i     ON i.order_id = o.id
JOIN demo_shipments s ON s.order_id = o.id;

-- 根因:orders → items 是 1:N,orders → shipments 也是 1:N。兩個 1:N 一起 JOIN,
--       每個 item 會與同訂單的每個 shipment 配對 (2 items × 2 shipments = 4 列),
--       金額跟著被複製,SUM 才會膨脹。聚合前先 JOIN 就會踩到。

\echo '── C 修正:各自先聚合到「訂單」粒度,再 JOIN (每邊各 1 列) ──'
SELECT o.customer,
       SUM(i.item_total)  AS revenue,
       SUM(s.shipments)   AS shipments
FROM demo_orders o
JOIN (SELECT order_id, SUM(amount) AS item_total FROM demo_items GROUP BY order_id) i
     ON i.order_id = o.id
JOIN (SELECT order_id, COUNT(*)    AS shipments  FROM demo_shipments GROUP BY order_id) s
     ON s.order_id = o.id
GROUP BY o.customer ORDER BY o.customer;

\echo '── C 驗證:總和回到 350 ──'
SELECT SUM(i.item_total) AS revenue
FROM (SELECT order_id, SUM(amount) AS item_total FROM demo_items GROUP BY order_id) i;

-- =====================================================================
\echo ''
\echo '════ 情境 D:WHERE 裡放聚合 / HAVING 裡放列條件 ════'
-- 症狀:想找「訂單數 > 1 的客戶」,寫在 WHERE 直接報錯;改到 HAVING 後又擔心「先分組再過濾」會慢
-- =====================================================================
\echo '── D 重現:WHERE COUNT(*) > 1 → aggregate functions are not allowed in WHERE ──'
DO $$
BEGIN
    PERFORM customer_id FROM orders WHERE COUNT(*) > 1 GROUP BY customer_id;
EXCEPTION WHEN grouping_error THEN
    RAISE NOTICE '❌ SQLSTATE=% : %', SQLSTATE, SQLERRM;
END$$;
-- 根因:WHERE 在「分組之前」逐列評估,那時候還沒有群組,COUNT(*) 沒有意義。

\echo '── D 修法:群組層級的條件放 HAVING ──'
SELECT customer_id, COUNT(*) AS orders
FROM orders
GROUP BY customer_id
HAVING COUNT(*) > 1
ORDER BY customer_id;

-- 反過來的情況:把「列層級」的條件寫進 HAVING (status 有在 GROUP BY 裡,語法合法)
-- 直覺上會以為「先分完 30 萬列的組再丟掉 90%」,實際上呢?不要猜,看計畫。
DROP TABLE IF EXISTS demo_sales;
CREATE TABLE demo_sales (id SERIAL PRIMARY KEY, region INT, status TEXT, amount NUMERIC(10,2));
INSERT INTO demo_sales (region, status, amount)
SELECT g % 50,
       CASE WHEN g % 10 = 0 THEN 'completed' ELSE 'cancelled' END,
       (g % 500)::NUMERIC
FROM generate_series(1, 300000) g;
ANALYZE demo_sales;

\echo '── D 排查:HAVING status = ... 的計畫 — 注意 Filter 出現在 Seq Scan 那一層 ──'
EXPLAIN (ANALYZE, COSTS OFF)
SELECT region, status, SUM(amount)
FROM demo_sales
GROUP BY region, status
HAVING status = 'completed';

\echo '── D 對照:同一條件寫在 WHERE — 計畫一模一樣 ──'
EXPLAIN (ANALYZE, COSTS OFF)
SELECT region, status, SUM(amount)
FROM demo_sales
WHERE status = 'completed'
GROUP BY region, status;
-- 結論:planner 會把「只牽涉分組欄位、不含聚合」的 HAVING 條件下推到掃描階段,
--       兩者效能相同。所以 WHERE / HAVING 的分界是「語意」不是效能:
--       列條件放 WHERE 是為了讓人一眼看懂,以及避免未來改成非分組欄位時報錯。

-- =====================================================================
\echo ''
\echo '════ 情境 E:GROUP BY 大表突然變慢 — HashAggregate 溢出到磁碟 ════'
-- 症狀:同一條每日彙總查詢,在資料成長後執行時間跳升;磁碟 I/O 同時飆高
-- =====================================================================
DROP TABLE IF EXISTS demo_events;
CREATE TABLE demo_events (id SERIAL PRIMARY KEY, session_key TEXT, amount INT);
-- 30 萬列、10 萬個不同的分組鍵 (高基數,像 session id / user id)
INSERT INTO demo_events (session_key, amount)
SELECT 'sess-' || (g % 100000), g % 100
FROM generate_series(1, 300000) g;
ANALYZE demo_events;

\echo '── E 排查步驟 1:預設 work_mem (4MB) 下看計畫 ──'
RESET work_mem;
SHOW work_mem;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT session_key, SUM(amount), COUNT(*)
FROM demo_events
GROUP BY session_key;
-- 看什麼:HashAggregate 那一行的 Batches > 1、Disk Usage: NNNN kB、
--         Buffers 多了 temp read/written。(work_mem 更小時 planner 可能改走
--         Sort + GroupAggregate,那時看 Sort Method: external merge Disk)

\echo '── E 排查步驟 2:確認累積的 temp file 用量 (整個 DB 層級) ──'
SELECT temp_files, pg_size_pretty(temp_bytes) AS temp_bytes
FROM pg_stat_database WHERE datname = current_database();

-- 根因:HashAggregate 要在記憶體裡為「每個分組」保留一個 bucket;分組數 × 每組大小
--       超過 work_mem 就分批寫到磁碟 (Batches),多出來的都是 temp file I/O。
--       資料剛成長超過門檻時就會「突然」變慢。

\echo '── E 修正:給這條查詢足夠的 work_mem (只在這個 session / 這條查詢生效) ──'
SET work_mem = '64MB';
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT session_key, SUM(amount), COUNT(*)
FROM demo_events
GROUP BY session_key;
RESET work_mem;
-- 看什麼:Batches: 1、沒有 Disk Usage、Execution Time 明顯下降

-- ---------------------------------------------------------------------
-- 清理
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS reviews, demo_orders, demo_items, demo_shipments, demo_sales, demo_events;
\echo ''
\echo '✅ 情境模擬完成 (demo 表已清除)'
