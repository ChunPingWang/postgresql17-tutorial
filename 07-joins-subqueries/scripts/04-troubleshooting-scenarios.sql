-- =====================================================================
-- 第 7 章 / 問題排查情境模擬 (對應 README 7.12 節)
-- 用法:psql -d bookstore -f 04-troubleshooting-scenarios.sql
--
-- 每個情境都用自己的 demo 表 (前綴 t7_),跑完會清掉,不影響 bookstore 其他章節。
-- 建議搭配 README 7.12 的「排查順序」逐段執行、對照輸出。
-- 本腳本不會出現 ERROR — JOIN 類的問題正是「不報錯、只給錯答案」。
-- =====================================================================
SET search_path TO shop, public;

-- =====================================================================
\echo ''
\echo '════ 情境 A:報表金額比實際多出好幾倍 (多對多 JOIN 造成列數膨脹) ════'
-- 症狀:「各訂單的金額」報表,一加上付款紀錄,金額就變成原本的 2~3 倍
-- =====================================================================
DROP TABLE IF EXISTS t7_payments;
CREATE TABLE t7_payments (
    id        SERIAL PRIMARY KEY,
    order_id  INT NOT NULL REFERENCES orders(id),
    method    TEXT NOT NULL,
    amount    NUMERIC(10,2) NOT NULL
);
-- 訂單 1 分兩次付 (信用卡 + 折價券),訂單 4 分三次付
INSERT INTO t7_payments (order_id, method, amount) VALUES
    (1, 'card', 1500), (1, 'coupon', 350),
    (2, 'card', 480),
    (3, 'card', 900),
    (4, 'card', 400), (4, 'card', 400), (4, 'coupon', 60);

\echo '── A 排查步驟 1:對照「真相」— 直接從 order_items 算每張訂單金額 ──'
SELECT o.id AS order_id, SUM(oi.quantity * oi.unit_price) AS real_total
FROM orders o JOIN order_items oi ON oi.order_id = o.id
WHERE o.id IN (1, 4)
GROUP BY o.id ORDER BY o.id;

\echo '── A 症狀重現:多 JOIN 一張 payments,金額變大 ──'
SELECT o.id AS order_id,
       SUM(oi.quantity * oi.unit_price) AS inflated_total,
       COUNT(*)                          AS joined_rows,
       COUNT(DISTINCT oi.id)             AS real_item_rows
FROM orders o
JOIN order_items oi ON oi.order_id = o.id
JOIN t7_payments p  ON p.order_id  = o.id
WHERE o.id IN (1, 4)
GROUP BY o.id ORDER BY o.id;
-- 根因:order_items 與 payments 都是「一張訂單對多筆」,兩個一對多同時 JOIN,
--       每筆 item 會被複製成 (付款筆數) 份 → 金額乘上付款筆數。
--       線索就是 COUNT(*) 與 COUNT(DISTINCT oi.id) 不相等。

\echo '── A 修正:先各自聚合成「每張訂單一列」,再 JOIN ──'
SELECT o.id AS order_id, i.item_total, p.paid_total
FROM orders o
JOIN (SELECT order_id, SUM(quantity * unit_price) AS item_total
      FROM order_items GROUP BY order_id) i ON i.order_id = o.id
JOIN (SELECT order_id, SUM(amount) AS paid_total
      FROM t7_payments GROUP BY order_id)  p ON p.order_id = o.id
WHERE o.id IN (1, 4)
ORDER BY o.id;

\echo '── A-2 同類問題:忘記 JOIN 條件 → 笛卡兒積 ──'
-- 6 張訂單 × 8 筆明細 = 48 列,而不是 8 列
SELECT (SELECT COUNT(*) FROM orders) AS orders,
       (SELECT COUNT(*) FROM order_items) AS items,
       (SELECT COUNT(*) FROM orders o, order_items oi) AS comma_join_no_where,
       (SELECT COUNT(*) FROM orders o JOIN order_items oi ON oi.order_id = o.id) AS proper_join;

-- =====================================================================
\echo ''
\echo '════ 情境 B:「沒有書的作者」從報表上消失了 (LEFT JOIN 退化成 INNER) ════'
-- 症狀:作者清單要列出所有作者與「單價 > 400 的書」,結果沒書的作者不見了
-- =====================================================================
\echo '── B 排查步驟 1:確認母體有幾列 (LEFT JOIN 的左表列數不該減少) ──'
SELECT COUNT(*) AS authors_total FROM authors;

\echo '── B 症狀重現:WHERE 過濾右表欄位 ──'
SELECT a.name, b.title, b.price
FROM authors a
LEFT JOIN books b ON b.author_id = a.id
WHERE b.price > 400
ORDER BY a.name, b.title;
-- 根因:LEFT JOIN 先把沒書的作者補成 b.* = NULL,
--       接著 WHERE b.price > 400 對 NULL 判斷為 UNKNOWN → 整列被丟掉。
--       任何「對右表欄位的 WHERE 條件」都會讓 LEFT JOIN 變成 INNER JOIN。

\echo '── B 修正:把右表的條件放進 ON (在配對階段過濾,而不是配對後) ──'
SELECT a.name, b.title, b.price
FROM authors a
LEFT JOIN books b ON b.author_id = a.id AND b.price > 400
ORDER BY a.name, b.title;

\echo '── B 驗證:結果中 DISTINCT 作者數 = 作者總數 ──'
SELECT COUNT(DISTINCT a.id) AS authors_in_result
FROM authors a
LEFT JOIN books b ON b.author_id = a.id AND b.price > 400;

-- =====================================================================
\echo ''
\echo '════ 情境 C:NOT IN 查「從未下單的客戶」回傳 0 列 (子查詢含 NULL) ════'
-- 症狀:明明有客戶從沒下過單,NOT IN 卻一列都不回;NOT EXISTS 就正常
-- =====================================================================
DROP TABLE IF EXISTS t7_orders;
CREATE TABLE t7_orders (
    id          SERIAL PRIMARY KEY,
    customer_id INT,             -- 允許 NULL:匿名/訪客訂單
    total       NUMERIC(10,2)
);
INSERT INTO t7_orders (customer_id, total) VALUES
    (1, 100), (2, 200), (NULL, 50);   -- 一筆訪客訂單,customer_id 是 NULL

\echo '── C 排查步驟 1:母體與子查詢各有幾列?子查詢有沒有 NULL? ──'
SELECT (SELECT COUNT(*) FROM customers) AS customers_total,
       (SELECT COUNT(*) FROM t7_orders) AS orders_total,
       (SELECT COUNT(*) FROM t7_orders WHERE customer_id IS NULL) AS orders_with_null_customer;

\echo '── C 症狀重現:NOT IN 回傳 0 列 ──'
SELECT id, name FROM customers
WHERE id NOT IN (SELECT customer_id FROM t7_orders);
-- 根因:x NOT IN (1, 2, NULL) 等於 x <> 1 AND x <> 2 AND x <> NULL,
--       最後一項永遠是 UNKNOWN,整個條件不可能為 TRUE → 0 列。
--       只要子查詢裡混進一個 NULL,NOT IN 就整個失效,而且不報錯。

\echo '── C 修正 1:NOT EXISTS (NULL 不會配對到任何列,語意正確) ──'
SELECT c.id, c.name FROM customers c
WHERE NOT EXISTS (SELECT 1 FROM t7_orders o WHERE o.customer_id = c.id)
ORDER BY c.id;

\echo '── C 修正 2:若堅持用 NOT IN,子查詢要排除 NULL ──'
SELECT id, name FROM customers
WHERE id NOT IN (SELECT customer_id FROM t7_orders WHERE customer_id IS NOT NULL)
ORDER BY id;

-- =====================================================================
\echo ''
\echo '════ 情境 D:一條「每位客戶的訂單數」查詢跑好幾秒 (相關子查詢逐列執行) ════'
-- 症狀:資料量小時沒感覺,客戶與訂單長到幾千/幾十萬筆後,報表變成秒級甚至分鐘級
-- =====================================================================
DROP TABLE IF EXISTS t7_big_orders;
DROP TABLE IF EXISTS t7_big_customers;
CREATE TABLE t7_big_customers (id INT PRIMARY KEY, name TEXT);
CREATE TABLE t7_big_orders (id SERIAL PRIMARY KEY, customer_id INT NOT NULL, total NUMERIC(10,2));
INSERT INTO t7_big_customers SELECT g, 'customer_' || g FROM generate_series(1, 2000) g;
INSERT INTO t7_big_orders (customer_id, total)
SELECT 1 + (g % 2000), (random() * 1000)::NUMERIC(10,2)
FROM generate_series(1, 100000) g;
ANALYZE t7_big_customers;
ANALYZE t7_big_orders;

\echo '── D 排查步驟 1:EXPLAIN ANALYZE — 注意 SubPlan 節點的 loops= ──'
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.id,
       (SELECT COUNT(*) FROM t7_big_orders o WHERE o.customer_id = c.id) AS order_count
FROM t7_big_customers c;
-- 根因:相關子查詢對「外層每一列」各執行一次 (loops = 客戶數),
--       每次都是對 orders 的全表掃描 → 成本 = 客戶數 × 訂單數。

\echo '── D 修正 1:改寫成 JOIN + GROUP BY,一次掃過 orders (Hash Join / HashAggregate) ──'
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.id, COUNT(o.id) AS order_count
FROM t7_big_customers c
LEFT JOIN t7_big_orders o ON o.customer_id = c.id
GROUP BY c.id;

\echo '── D 修正 2:若必須保留子查詢寫法,至少在關聯欄位上建索引,讓每次 loop 變成索引掃描而非全表掃描 ──'
CREATE INDEX t7_big_orders_customer_idx ON t7_big_orders (customer_id);
ANALYZE t7_big_orders;
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.id,
       (SELECT COUNT(*) FROM t7_big_orders o WHERE o.customer_id = c.id) AS order_count
FROM t7_big_customers c;

\echo '── D 驗證:三種寫法結果一致 ──'
SELECT COUNT(*) AS customers, SUM(order_count) AS total_orders
FROM (SELECT c.id, COUNT(o.id) AS order_count
      FROM t7_big_customers c LEFT JOIN t7_big_orders o ON o.customer_id = c.id
      GROUP BY c.id) t;

-- ---------------------------------------------------------------------
-- 清理
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS t7_big_orders;
DROP TABLE IF EXISTS t7_big_customers;
DROP TABLE IF EXISTS t7_orders;
DROP TABLE IF EXISTS t7_payments;
\echo ''
\echo '✅ 情境模擬完成 (demo 表已清除)'
