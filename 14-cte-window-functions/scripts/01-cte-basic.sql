-- =====================================================================
-- 第 14 章 / CTE 基礎
-- =====================================================================
SET search_path TO shop, public;

\echo '── 1. 基本 CTE ──'
WITH category_stats AS (
    SELECT
        category_id,
        COUNT(*)              AS book_cnt,
        AVG(price)            AS avg_price,
        SUM(stock * price)    AS inventory_value
    FROM books
    GROUP BY category_id
)
SELECT
    c.name,
    cs.book_cnt,
    cs.avg_price::NUMERIC(10,2),
    cs.inventory_value::NUMERIC(12,2)
FROM category_stats cs
JOIN categories c ON c.id = cs.category_id
ORDER BY cs.book_cnt DESC;

\echo '── 2. 多個 CTE ──'
WITH
    paid AS (
        SELECT * FROM orders WHERE status IN ('paid','completed','shipped')
    ),
    revenue_by_cust AS (
        SELECT customer_id, SUM(total) AS revenue, COUNT(*) AS orders
        FROM paid GROUP BY customer_id
    )
SELECT
    c.name,
    r.orders,
    r.revenue
FROM revenue_by_cust r
JOIN customers c ON c.id = r.customer_id
ORDER BY r.revenue DESC;

\echo '── 3. CTE 搭配 INSERT (模擬歸檔 DML) ──'
CREATE TEMP TABLE archived_books (LIKE books);
WITH old_books AS (
    SELECT * FROM books WHERE published_at < '1990-01-01'
)
INSERT INTO archived_books
SELECT * FROM old_books
RETURNING id, title, published_at;

DROP TABLE archived_books;

\echo '── 4. CTE 的 MATERIALIZED 控制 ──'
-- 預設 PG 17 可能內聯 CTE (優化),加 MATERIALIZED 強制物化
WITH expensive AS MATERIALIZED (
    SELECT id, title, price FROM books WHERE stock > 0
)
SELECT * FROM expensive WHERE price > 500;
