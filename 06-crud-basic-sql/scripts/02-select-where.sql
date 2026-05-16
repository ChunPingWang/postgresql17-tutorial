-- =====================================================================
-- 第 6 章 / SELECT、WHERE、ORDER BY、LIMIT
-- =====================================================================
SET search_path TO shop, public;

-- 1) 基本 + 別名
SELECT
    id,
    title,
    price,
    price * 0.9        AS discount_price,
    stock * price      AS inventory_value
FROM books
ORDER BY price DESC
LIMIT 5;

-- 2) WHERE 範圍與 IN
SELECT title, price, category_id
FROM books
WHERE price BETWEEN 300 AND 800
  AND category_id IN (1, 2, 3)
ORDER BY price;

-- 3) LIKE / ILIKE
SELECT title FROM books WHERE title ILIKE '%programming%';

-- 4) NULL 處理
SELECT id, title, author_id FROM books WHERE author_id IS NOT NULL;

-- 5) DISTINCT ON (每國取一位作者)
SELECT DISTINCT ON (country) country, name, birth_date
FROM authors
WHERE country IS NOT NULL
ORDER BY country, birth_date;

-- 6) CASE
SELECT
    title,
    price,
    CASE
        WHEN price < 400  THEN '便宜'
        WHEN price < 1000 THEN '一般'
        ELSE '昂貴'
    END AS tier
FROM books
ORDER BY price;

-- 7) COALESCE / NULLIF
SELECT
    name,
    COALESCE(email, '無 email') AS contact_email
FROM authors;

-- 8) 分頁示範
SELECT id, title FROM books ORDER BY id OFFSET 2 LIMIT 3;
