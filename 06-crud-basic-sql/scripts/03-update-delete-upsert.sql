-- =====================================================================
-- 第 6 章 / UPDATE / DELETE 並使用交易確保不污染資料
-- =====================================================================
SET search_path TO shop, public;

BEGIN;

-- 1) 看初始狀態
SELECT id, title, price FROM books WHERE id IN (1, 2);

-- 2) 基本更新
UPDATE books SET price = price * 1.1 WHERE id IN (1, 2)
RETURNING id, title, price;

-- 3) 從子查詢更新 (修正 orders.total)
UPDATE orders o
SET total = COALESCE(sub.total, 0)
FROM (
    SELECT order_id, SUM(quantity * unit_price) AS total
    FROM order_items
    GROUP BY order_id
) sub
WHERE sub.order_id = o.id
RETURNING o.id, o.status, o.total;

-- 4) DELETE 使用 USING (跨表條件)
DELETE FROM order_items oi
USING orders o
WHERE oi.order_id = o.id
  AND o.status = 'cancelled'
RETURNING oi.id, oi.order_id, oi.book_id;

-- 5) TRUNCATE 示範 (在 temp table)
CREATE TEMP TABLE temp_to_truncate AS SELECT * FROM books LIMIT 3;
SELECT count(*) AS before_truncate FROM temp_to_truncate;
TRUNCATE temp_to_truncate;
SELECT count(*) AS after_truncate FROM temp_to_truncate;

-- 6) 視察:這些變更會被 ROLLBACK 取消
ROLLBACK;

\echo '✅ 變更已 ROLLBACK,bookstore 範例資料保持原狀'
