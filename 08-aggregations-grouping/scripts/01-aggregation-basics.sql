-- =====================================================================
-- 第 8 章 / 聚合函數基本應用
-- =====================================================================
SET search_path TO shop, public;

-- 1) 基本五大聚合
SELECT
    COUNT(*)        AS total_books,
    AVG(price)::NUMERIC(10,2)  AS avg_price,
    MIN(price)      AS min_price,
    MAX(price)      AS max_price,
    SUM(stock)      AS total_stock
FROM books;

-- 2) GROUP BY:依分類統計
SELECT c.name AS category,
       COUNT(*) AS books,
       AVG(b.price)::NUMERIC(10,2) AS avg_price,
       SUM(b.stock) AS stock
FROM books b
JOIN categories c ON c.id = b.category_id
GROUP BY c.name
ORDER BY books DESC;

-- 3) HAVING
SELECT category_id, COUNT(*) AS cnt
FROM books
GROUP BY category_id
HAVING COUNT(*) >= 2;

-- 4) COUNT(*) vs COUNT(col) vs COUNT(DISTINCT col)
SELECT
    COUNT(*)             AS rows_total,
    COUNT(email)         AS rows_with_email,
    COUNT(DISTINCT country) AS distinct_countries
FROM authors;

-- 5) STRING_AGG / ARRAY_AGG / JSON_AGG
SELECT
    c.name AS category,
    STRING_AGG(b.title, ' / ' ORDER BY b.title) AS titles,
    ARRAY_AGG(b.id ORDER BY b.id)              AS ids,
    JSON_AGG(JSON_BUILD_OBJECT('id', b.id, 'title', b.title) ORDER BY b.id) AS books_json
FROM books b
JOIN categories c ON c.id = b.category_id
GROUP BY c.name
ORDER BY c.name;

-- 6) BOOL_AND / BOOL_OR
SELECT BOOL_AND(stock > 0)  AS all_in_stock,
       BOOL_OR(stock = 0)   AS any_out_of_stock
FROM books;
