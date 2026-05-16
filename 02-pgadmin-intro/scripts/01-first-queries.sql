-- =====================================================================
-- 在 pgAdmin Query Tool 內練習的查詢範例
-- 連線到 bookstore 後執行
-- =====================================================================

SET search_path TO shop, public;

-- 1) 看一下我們有什麼書
SELECT id, title, price, stock
FROM books
ORDER BY price DESC;

-- 2) 加上作者與分類資訊
SELECT
    b.title,
    a.name        AS author,
    c.name        AS category,
    b.price,
    b.stock
FROM books b
LEFT JOIN authors    a ON a.id = b.author_id
LEFT JOIN categories c ON c.id = b.category_id
ORDER BY b.title;

-- 3) 每個狀態的訂單數量
SELECT
    status,
    COUNT(*)               AS order_count,
    SUM(total)             AS total_amount,
    AVG(total)::numeric(10,2) AS avg_amount
FROM orders
GROUP BY status
ORDER BY order_count DESC;

-- 4) 銷售量最高的前 3 本書 (預覽聚合 + Join)
SELECT
    b.title,
    SUM(oi.quantity) AS total_sold,
    SUM(oi.quantity * oi.unit_price) AS revenue
FROM books b
JOIN order_items oi ON oi.book_id = b.id
JOIN orders o       ON o.id = oi.order_id
WHERE o.status <> 'cancelled'
GROUP BY b.title
ORDER BY total_sold DESC
LIMIT 3;

-- 5) 物件大小 (在 pgAdmin Statistics 看不出的資訊)
SELECT
    relname AS table_name,
    pg_size_pretty(pg_total_relation_size(relid)) AS total_size
FROM pg_catalog.pg_statio_user_tables
WHERE schemaname = 'shop'
ORDER BY pg_total_relation_size(relid) DESC;

-- 提示:在 Query Tool 內選取單一條 SQL 後按 F5 可單獨執行
