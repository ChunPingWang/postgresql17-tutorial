-- =====================================================================
-- 第 7 章 / 各種 JOIN
-- =====================================================================
SET search_path TO shop, public;

-- 1) INNER JOIN:書 + 作者 + 分類
SELECT b.id, b.title, a.name AS author, c.name AS category
FROM books b
INNER JOIN authors    a ON a.id = b.author_id
INNER JOIN categories c ON c.id = b.category_id
ORDER BY b.id
LIMIT 10;

-- 2) LEFT JOIN:列出所有作者及其書 (即使該作者沒書)
SELECT a.name AS author, COALESCE(b.title, '(無書籍)') AS title
FROM authors a
LEFT JOIN books b ON b.author_id = a.id
ORDER BY a.name;

-- 3) RIGHT JOIN:從 orders 角度看明細
SELECT o.id AS order_id, oi.book_id, oi.quantity
FROM order_items oi
RIGHT JOIN orders o ON o.id = oi.order_id
ORDER BY o.id;

-- 4) FULL JOIN
SELECT COALESCE(a.name,'(無作者)') AS author,
       COALESCE(b.title,'(沒書)')  AS title
FROM authors a
FULL JOIN books b ON b.author_id = a.id
ORDER BY a.name NULLS LAST;

-- 5) 自我 JOIN:員工與其主管
SELECT e.id, e.name AS employee, e.role, m.name AS manager
FROM employees e
LEFT JOIN employees m ON m.id = e.manager_id
ORDER BY e.id;

-- 6) 多表 JOIN:完整訂單明細視圖
SELECT
    o.id        AS order_id,
    c.name      AS customer,
    o.status,
    o.ordered_at::date AS ordered_on,
    b.title,
    oi.quantity,
    oi.unit_price,
    oi.quantity * oi.unit_price AS line_total
FROM orders o
JOIN customers   c  ON c.id = o.customer_id
JOIN order_items oi ON oi.order_id = o.id
JOIN books       b  ON b.id = oi.book_id
ORDER BY o.id, b.title;
