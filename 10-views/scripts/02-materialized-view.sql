-- =====================================================================
-- 第 10 章 / Materialized View
-- =====================================================================
SET search_path TO shop, public;

DROP MATERIALIZED VIEW IF EXISTS mv_category_sales;
DROP MATERIALIZED VIEW IF EXISTS mv_top_customers;

-- 1) 建立物化視圖 (一次計算後存實體資料)
CREATE MATERIALIZED VIEW mv_category_sales AS
SELECT
    c.id AS category_id,
    c.name AS category,
    COUNT(DISTINCT o.id) AS orders,
    SUM(oi.quantity)     AS units_sold,
    COALESCE(SUM(oi.quantity * oi.unit_price), 0) AS revenue
FROM categories c
LEFT JOIN books       b  ON b.category_id = c.id
LEFT JOIN order_items oi ON oi.book_id    = b.id
LEFT JOIN orders      o  ON o.id          = oi.order_id
GROUP BY c.id, c.name
WITH DATA;

-- 建 UNIQUE INDEX 才能 REFRESH CONCURRENTLY
CREATE UNIQUE INDEX uq_mv_cat_sales ON mv_category_sales(category_id);

-- 額外建普通索引加速
CREATE INDEX ix_mv_cat_sales_rev ON mv_category_sales(revenue DESC);

-- 查詢
SELECT * FROM mv_category_sales ORDER BY revenue DESC;

-- 2) 模擬底表變動
INSERT INTO order_items (order_id, book_id, quantity, unit_price)
VALUES (1, 2, 10, 1200);

-- mv 還沒更新,看不到新資料
SELECT * FROM mv_category_sales ORDER BY revenue DESC;

-- 3) 刷新 (鎖讀)
REFRESH MATERIALIZED VIEW mv_category_sales;
SELECT * FROM mv_category_sales ORDER BY revenue DESC;

-- 4) 不鎖讀刷新 (需 UNIQUE INDEX,我們上面已建)
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_category_sales;

-- 5) 還原資料
DELETE FROM order_items
WHERE order_id = 1 AND book_id = 2 AND quantity = 10;
REFRESH MATERIALIZED VIEW mv_category_sales;

-- 6) 另一個 mv:Top 3 客戶
CREATE MATERIALIZED VIEW mv_top_customers AS
SELECT
    c.id AS customer_id,
    c.name,
    COUNT(o.id) AS order_count,
    COALESCE(SUM(o.total), 0) AS total_spent
FROM customers c
LEFT JOIN orders o ON o.customer_id = c.id AND o.status <> 'cancelled'
GROUP BY c.id, c.name
ORDER BY total_spent DESC
LIMIT 3;

SELECT * FROM mv_top_customers;

-- 7) 列出所有 materialized view
SELECT matviewname, ispopulated
FROM pg_matviews
WHERE schemaname = 'shop';

-- 清理
DROP MATERIALIZED VIEW mv_top_customers;
-- mv_category_sales 留下供後續章節使用
