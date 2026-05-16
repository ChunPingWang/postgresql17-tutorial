-- =====================================================================
-- 第 7 章 / LATERAL JOIN 與集合運算
-- =====================================================================
SET search_path TO shop, public;

-- 1) LATERAL:每位客戶最近 2 筆訂單
SELECT c.id AS customer_id, c.name, t.order_id, t.ordered_at, t.total
FROM customers c
LEFT JOIN LATERAL (
    SELECT id AS order_id, ordered_at, total
    FROM orders
    WHERE customer_id = c.id
    ORDER BY ordered_at DESC
    LIMIT 2
) t ON TRUE
ORDER BY c.id, t.ordered_at DESC NULLS LAST;

-- 2) LATERAL:每本書的最高單價 (從 order_items 看)
SELECT b.title, t.max_price
FROM books b
LEFT JOIN LATERAL (
    SELECT MAX(unit_price) AS max_price
    FROM order_items
    WHERE book_id = b.id
) t ON TRUE;

-- 3) UNION (去重)
SELECT 'author'  AS kind, name FROM authors
UNION
SELECT 'customer', name FROM customers
ORDER BY kind, name;

-- 4) UNION ALL (不去重,更快)
SELECT id AS x FROM authors WHERE id <= 3
UNION ALL
SELECT id      FROM customers WHERE id <= 3;

-- 5) INTERSECT
SELECT name FROM authors
INTERSECT
SELECT name FROM customers;
-- (本範例資料應無交集,結果為空)

-- 6) EXCEPT:沒被賣過的書
SELECT id FROM books
EXCEPT
SELECT book_id FROM order_items
ORDER BY id;
