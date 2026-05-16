-- =====================================================================
-- 第 7 章 / 子查詢的三種位置
-- =====================================================================
SET search_path TO shop, public;

-- 1) SELECT 子句 (純量子查詢)
SELECT
    b.id,
    b.title,
    (SELECT name FROM authors  WHERE id = b.author_id)   AS author,
    (SELECT name FROM categories WHERE id = b.category_id) AS category
FROM books b
ORDER BY b.id
LIMIT 5;

-- 2) FROM 子句 (派生表)
SELECT t.category, t.cnt
FROM (
    SELECT c.name AS category, COUNT(*) AS cnt
    FROM books b
    JOIN categories c ON c.id = b.category_id
    GROUP BY c.name
) t
WHERE t.cnt >= 2
ORDER BY t.cnt DESC;

-- 3) WHERE 子句 - IN
SELECT title FROM books
WHERE category_id IN (
    SELECT id FROM categories WHERE name IN ('Database','Programming')
);

-- 4) EXISTS:有訂過書的客戶
SELECT name FROM customers c
WHERE EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.id);

-- 5) NOT EXISTS:從未下訂單的客戶
SELECT name FROM customers c
WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.id);

-- 6) 相關子查詢:每位作者書數
SELECT
    a.name,
    (SELECT COUNT(*) FROM books b WHERE b.author_id = a.id) AS book_count
FROM authors a
ORDER BY book_count DESC, a.name;

-- 7) ANY / ALL 與比較
SELECT title, price FROM books
WHERE price > ALL (
    SELECT price FROM books WHERE category_id = 3  -- 比所有小說都貴
);
