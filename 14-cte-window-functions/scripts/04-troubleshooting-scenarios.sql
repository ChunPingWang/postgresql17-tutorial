-- =====================================================================
-- 第 14 章 / 問題排查情境模擬 (對應 README 14.11 節)
-- 用法:psql -d bookstore -f 04-troubleshooting-scenarios.sql
--
-- 每個情境都用自己的 demo 表 (ts_ 開頭),跑完會清掉,不影響 bookstore 其他章節。
-- 建議搭配 README 14.11 的「排查順序」逐段執行、對照輸出。
-- 注意:情境 A 與 D-2 會刻意觸發錯誤,但都包在 DO ... EXCEPTION 裡,
--       只會印出 NOTICE,不會出現 psql ERROR。
-- =====================================================================
SET search_path TO shop, public;

-- =====================================================================
\echo ''
\echo '════ 情境 A:遞迴 CTE 跑不完 (資料裡有環) ════'
-- 症狀:「找某員工所有下屬」的查詢平常 1ms,今天掛住不回來,CPU 100%
-- =====================================================================
DROP TABLE IF EXISTS ts_staff;
CREATE TABLE ts_staff (
    id          INT PRIMARY KEY,
    name        TEXT NOT NULL,
    manager_id  INT REFERENCES ts_staff(id)
);
INSERT INTO ts_staff VALUES
    (1, 'Alice', NULL),
    (2, 'Bob',   1),
    (3, 'Carol', 1),
    (4, 'Dave',  2),
    (5, 'Eve',   4);

\echo '── A 昨天:正常的組織樹,5 列 ──'
WITH RECURSIVE subs AS (
    SELECT id, name, manager_id, 0 AS depth FROM ts_staff WHERE id = 1
    UNION ALL
    SELECT s.id, s.name, s.manager_id, subs.depth + 1
    FROM ts_staff s JOIN subs ON s.manager_id = subs.id
)
SELECT depth, id, name FROM subs ORDER BY depth, id;

-- 今天:HR 系統一次「組織調整」把 Alice 的主管改成 Eve → 1→2→4→5→1 成了環
UPDATE ts_staff SET manager_id = 5 WHERE id = 1;

\echo '── A 排查步驟 1:同一條查詢,先設 statement_timeout 保護後重跑 (預期被取消) ──'
-- 注意:statement_timeout 要在「陳述式開始前」設定才會生效,在 DO 內用 SET LOCAL 是來不及的
SET statement_timeout = '2s';
DO $$
DECLARE n BIGINT;
BEGIN
    SELECT count(*) INTO n FROM (
        WITH RECURSIVE subs AS (
            SELECT id, name, manager_id, 0 AS depth FROM ts_staff WHERE id = 1
            UNION ALL
            SELECT s.id, s.name, s.manager_id, subs.depth + 1
            FROM ts_staff s JOIN subs ON s.manager_id = subs.id
        )
        SELECT * FROM subs
    ) x;
    RAISE NOTICE '不應該跑到這裡,列數 = %', n;
EXCEPTION WHEN query_canceled THEN
    RAISE NOTICE '❌ 2 秒後被 statement_timeout 取消 (SQLSTATE %) → 遞迴沒有終止條件', SQLSTATE;
END$$;
RESET statement_timeout;

\echo '── A 排查步驟 2:先限制深度看「走過哪些列」,環一眼就看得出來 ──'
WITH RECURSIVE subs AS (
    SELECT id, name, manager_id, 0 AS depth, ARRAY[id] AS path FROM ts_staff WHERE id = 1
    UNION ALL
    SELECT s.id, s.name, s.manager_id, subs.depth + 1, subs.path || s.id
    FROM ts_staff s JOIN subs ON s.manager_id = subs.id
    WHERE subs.depth < 8
)
SELECT depth, id, name, path FROM subs ORDER BY depth, id;

\echo '── A 排查步驟 3:直接找出資料裡的環 (誰的主管鏈會回到自己) ──'
WITH RECURSIVE chain AS (
    SELECT id AS start_id, manager_id AS cur, 1 AS hops FROM ts_staff WHERE manager_id IS NOT NULL
    UNION ALL
    SELECT c.start_id, s.manager_id, c.hops + 1
    FROM chain c JOIN ts_staff s ON s.id = c.cur
    WHERE c.cur <> c.start_id AND c.hops < 100
)
SELECT DISTINCT start_id AS in_cycle FROM chain WHERE cur = start_id ORDER BY 1;

-- 根因:遞迴 CTE 的終止條件是「recursive term 不再產生新列」;資料有環時每一輪都會產生列,永遠不停。
--       WHERE depth < N 只是止血,真正的修法是讓查詢自己偵測環 (PG 14+ CYCLE 子句)。

\echo '── A 修正:CYCLE 子句自動偵測環並停止 (PG 14+),不用手寫 path ──'
WITH RECURSIVE subs AS (
    SELECT id, name, manager_id, 0 AS depth FROM ts_staff WHERE id = 1
    UNION ALL
    SELECT s.id, s.name, s.manager_id, subs.depth + 1
    FROM ts_staff s JOIN subs ON s.manager_id = subs.id
) CYCLE id SET is_cycle USING path
SELECT depth, id, name, is_cycle, path FROM subs ORDER BY depth, id;

\echo '── A 驗證:同一條查詢不再需要 timeout,回傳有限列數;並修好資料 + 加約束防止再發生 ──'
UPDATE ts_staff SET manager_id = NULL WHERE id = 1;
ALTER TABLE ts_staff ADD CONSTRAINT ts_staff_no_self CHECK (manager_id IS DISTINCT FROM id);
WITH RECURSIVE subs AS (
    SELECT id, 0 AS depth FROM ts_staff WHERE id = 1
    UNION ALL
    SELECT s.id, subs.depth + 1 FROM ts_staff s JOIN subs ON s.manager_id = subs.id
) CYCLE id SET is_cycle USING path
SELECT count(*) AS rows_returned, bool_or(is_cycle) AS any_cycle FROM subs;

-- =====================================================================
\echo ''
\echo '════ 情境 B:累計金額「跳著加」— ORDER BY 有並列值 ════'
-- 症狀:對帳單的 running_total 在同一天的多筆交易上顯示相同的累計值,最後一筆才對
-- =====================================================================
DROP TABLE IF EXISTS ts_ledger;
CREATE TABLE ts_ledger (
    id       SERIAL PRIMARY KEY,
    tx_date  DATE NOT NULL,
    amount   NUMERIC(10,2) NOT NULL
);
INSERT INTO ts_ledger (tx_date, amount) VALUES
    ('2025-03-01', 100), ('2025-03-01', 200), ('2025-03-01', 300),
    ('2025-03-02', 50),  ('2025-03-02', 50),
    ('2025-03-03', 1000);

\echo '── B 排查步驟 1:重現 — 只寫 ORDER BY tx_date 的累計 ──'
SELECT id, tx_date, amount,
       SUM(amount) OVER (ORDER BY tx_date) AS running_total
FROM ts_ledger ORDER BY tx_date, id;

\echo '── B 排查步驟 2:把預設 frame 寫出來,問題就在 RANGE ──'
SELECT id, tx_date, amount,
       SUM(amount) OVER (ORDER BY tx_date
                         RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS same_as_default,
       SUM(amount) OVER (ORDER BY tx_date
                         ROWS  BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS rows_frame
FROM ts_ledger ORDER BY tx_date, id;

-- 根因:有 ORDER BY 時預設 frame 是 RANGE ... CURRENT ROW,「CURRENT ROW」在 RANGE 模式下
--       代表「所有與目前列 ORDER BY 值相同的列 (peers)」,所以同一天的三筆都拿到整天的合計。

\echo '── B 修正:ORDER BY 加上唯一鍵讓排序沒有並列 (最推薦),或明確用 ROWS ──'
SELECT id, tx_date, amount,
       SUM(amount) OVER (ORDER BY tx_date, id) AS running_total
FROM ts_ledger ORDER BY tx_date, id;

\echo '── B 驗證:每一列的累計都不同、最後一列 = 全部總和 ──'
SELECT count(DISTINCT running_total) = count(*) AS all_distinct,
       max(running_total) = (SELECT sum(amount) FROM ts_ledger) AS last_equals_total
FROM (SELECT SUM(amount) OVER (ORDER BY tx_date, id) AS running_total FROM ts_ledger) x;

-- =====================================================================
\echo ''
\echo '════ 情境 C:把查詢重構成 CTE 之後變慢 (optimization fence) ════'
-- 症狀:原本 1ms 的查詢,為了「好讀」抽成 CTE 並在兩個地方引用,變成 30ms;索引明明在
-- =====================================================================
DROP TABLE IF EXISTS ts_orders;
CREATE TABLE ts_orders (
    id           SERIAL PRIMARY KEY,
    customer_id  INT NOT NULL,
    status       TEXT NOT NULL,
    total        NUMERIC(10,2) NOT NULL
);
INSERT INTO ts_orders (customer_id, status, total)
SELECT (g % 5000) + 1,
       (ARRAY['pending','paid','completed'])[1 + g % 3],
       (g % 900) + 100
FROM generate_series(1, 200000) g;
CREATE INDEX idx_ts_orders_customer ON ts_orders (customer_id);
ANALYZE ts_orders;

\echo '── C 排查步驟 1:看計畫 — CTE 被引用兩次,出現 CTE Scan,底下是整表 Seq Scan ──'
EXPLAIN (ANALYZE, BUFFERS)
WITH paid AS (
    SELECT customer_id, total FROM ts_orders WHERE status IN ('paid', 'completed')
)
SELECT 'orders' AS metric, count(*)::numeric AS value FROM paid WHERE customer_id = 42
UNION ALL
SELECT 'revenue', sum(total) FROM paid WHERE customer_id = 42;

-- 根因:PG 12+ 只會把「被引用一次」的 CTE 內聯進主查詢;被引用兩次以上就先整個算出來
--       (materialize) 當暫存結果,外面的 WHERE customer_id = 42 推不進去 → 20 萬列全掃。

\echo '── C 修正 1:NOT MATERIALIZED 明確要求內聯,條件推進去就能走索引 ──'
EXPLAIN (ANALYZE, BUFFERS)
WITH paid AS NOT MATERIALIZED (
    SELECT customer_id, total FROM ts_orders WHERE status IN ('paid', 'completed')
)
SELECT 'orders' AS metric, count(*)::numeric AS value FROM paid WHERE customer_id = 42
UNION ALL
SELECT 'revenue', sum(total) FROM paid WHERE customer_id = 42;

\echo '── C 修正 2 (更好):把過濾條件寫進 CTE 裡,只算一次、只掃索引 ──'
EXPLAIN (ANALYZE, BUFFERS)
WITH paid AS (
    SELECT customer_id, total FROM ts_orders
    WHERE status IN ('paid', 'completed') AND customer_id = 42
)
SELECT 'orders' AS metric, count(*)::numeric AS value FROM paid
UNION ALL
SELECT 'revenue', sum(total) FROM paid;

\echo '── C 反例:什麼時候反而要 MATERIALIZED — CTE 很貴且會被引用多次 ──'
EXPLAIN (ANALYZE, BUFFERS)
WITH stats AS MATERIALIZED (
    SELECT customer_id, sum(total) AS revenue FROM ts_orders GROUP BY customer_id
)
SELECT (SELECT max(revenue) FROM stats) AS top_revenue,
       (SELECT avg(revenue) FROM stats) AS avg_revenue,
       (SELECT count(*) FROM stats WHERE revenue > 30000) AS big_customers;

-- =====================================================================
\echo ''
\echo '════ 情境 D:LAST_VALUE 回傳的不是最後一筆 ════'
-- 症狀:「每位客戶的第一筆與最後一筆訂單金額」報表,first_total 正確,last_total 卻等於目前列
-- =====================================================================
DROP TABLE IF EXISTS ts_cust_orders;
CREATE TABLE ts_cust_orders (
    id           SERIAL PRIMARY KEY,
    customer_id  INT NOT NULL,
    ordered_at   DATE NOT NULL,
    total        NUMERIC(10,2) NOT NULL
);
INSERT INTO ts_cust_orders (customer_id, ordered_at, total) VALUES
    (1, '2025-01-05', 100), (1, '2025-02-10', 250), (1, '2025-03-15', 400),
    (2, '2025-01-20', 900), (2, '2025-02-28', 300);

\echo '── D 排查步驟 1:重現 — last_total 隨著列變動 ──'
SELECT customer_id, ordered_at, total,
       FIRST_VALUE(total) OVER (PARTITION BY customer_id ORDER BY ordered_at) AS first_total,
       LAST_VALUE(total)  OVER (PARTITION BY customer_id ORDER BY ordered_at) AS last_total
FROM ts_cust_orders ORDER BY customer_id, ordered_at;

-- 根因:同情境 B — 有 ORDER BY 時預設 frame 只到 CURRENT ROW,
--       「目前這格看得到的最後一列」就是自己。FIRST_VALUE 沒事只是因為 frame 的起點本來就是分組開頭。

\echo '── D 修正:把 frame 拉到分組結尾 ──'
SELECT customer_id, ordered_at, total,
       FIRST_VALUE(total) OVER w AS first_total,
       LAST_VALUE(total)  OVER (w ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS last_total
FROM ts_cust_orders
WINDOW w AS (PARTITION BY customer_id ORDER BY ordered_at)
ORDER BY customer_id, ordered_at;

\echo '── D 驗證:每位客戶的 last_total 只有一種值,且等於日期最大那筆 ──'
SELECT customer_id,
       count(DISTINCT last_total) = 1 AS one_value,
       max(last_total) = (SELECT total FROM ts_cust_orders o2
                          WHERE o2.customer_id = x.customer_id
                          ORDER BY ordered_at DESC LIMIT 1) AS is_latest
FROM (SELECT customer_id,
             LAST_VALUE(total) OVER (PARTITION BY customer_id ORDER BY ordered_at
                                     ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS last_total
      FROM ts_cust_orders) x
GROUP BY customer_id ORDER BY customer_id;

\echo '── D-2 同類問題:視窗函數不能直接放在 WHERE (預期錯誤,已包在 DO 內) ──'
DO $$
BEGIN
    PERFORM customer_id FROM ts_cust_orders
    WHERE ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY ordered_at DESC) = 1;
    RAISE NOTICE '不應該跑到這裡';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '❌ SQLSTATE %: %', SQLSTATE, SQLERRM;
END$$;

-- 根因:視窗函數在 WHERE / GROUP BY / HAVING 之後才計算,WHERE 階段還沒有它的值。
\echo '── D-2 修正:先在 CTE / 子查詢算出 rn,外層再過濾 ──'
WITH ranked AS (
    SELECT customer_id, ordered_at, total,
           ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY ordered_at DESC) AS rn
    FROM ts_cust_orders
)
SELECT customer_id, ordered_at, total FROM ranked WHERE rn = 1 ORDER BY customer_id;

-- ---------------------------------------------------------------------
-- 清理
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS ts_cust_orders;
DROP TABLE IF EXISTS ts_orders;
DROP TABLE IF EXISTS ts_ledger;
DROP TABLE IF EXISTS ts_staff;
\echo ''
\echo '✅ 情境模擬完成 (demo 表已清除)'
