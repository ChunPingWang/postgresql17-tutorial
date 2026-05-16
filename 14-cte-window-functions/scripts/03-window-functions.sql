-- =====================================================================
-- 第 14 章 / 視窗函數
-- =====================================================================
SET search_path TO shop, public;

\echo '── 1. 排名函數比較 ──'
SELECT
    title, category_id, price,
    ROW_NUMBER() OVER (PARTITION BY category_id ORDER BY price DESC) AS row_num,
    RANK()       OVER (PARTITION BY category_id ORDER BY price DESC) AS rank,
    DENSE_RANK() OVER (PARTITION BY category_id ORDER BY price DESC) AS dense_rank
FROM books
ORDER BY category_id, price DESC;

\echo '── 2. NTILE — 分 3 等份 ──'
SELECT
    title, price,
    NTILE(3) OVER (ORDER BY price) AS price_bucket
FROM books ORDER BY price;

\echo '── 3. 累積加總與移動平均 ──'
SELECT
    title,
    price,
    SUM(price)  OVER (ORDER BY price ROWS UNBOUNDED PRECEDING) AS running_sum,
    AVG(price)  OVER (ORDER BY price ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING)::NUMERIC(10,2) AS moving_avg
FROM books
ORDER BY price;

\echo '── 4. LAG / LEAD — 前後列對比 ──'
SELECT
    id,
    customer_id,
    ordered_at::date,
    total,
    LAG(total)  OVER (PARTITION BY customer_id ORDER BY ordered_at) AS prev_order_total,
    LEAD(total) OVER (PARTITION BY customer_id ORDER BY ordered_at) AS next_order_total,
    total - LAG(total) OVER (PARTITION BY customer_id ORDER BY ordered_at) AS diff
FROM orders
ORDER BY customer_id, ordered_at;

\echo '── 5. FIRST_VALUE / LAST_VALUE ──'
SELECT
    title, category_id, price,
    FIRST_VALUE(price) OVER w AS cat_cheapest,
    LAST_VALUE(price)  OVER (
        PARTITION BY category_id ORDER BY price
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS cat_priciest
FROM books
WINDOW w AS (PARTITION BY category_id ORDER BY price)
ORDER BY category_id, price;

\echo '── 6. 每分類最貴的書 (ROW_NUMBER 技巧) ──'
WITH ranked AS (
    SELECT
        b.title,
        c.name AS category,
        b.price,
        ROW_NUMBER() OVER (PARTITION BY b.category_id ORDER BY b.price DESC) AS rn
    FROM books b
    JOIN categories c ON c.id = b.category_id
)
SELECT category, title, price
FROM ranked
WHERE rn = 1
ORDER BY price DESC;

\echo '── 7. PERCENT_RANK — 百分位排名 ──'
SELECT
    title, price,
    PERCENT_RANK() OVER (ORDER BY price)::NUMERIC(5,2) AS pct_rank,
    CUME_DIST()    OVER (ORDER BY price)::NUMERIC(5,2) AS cume_dist
FROM books
ORDER BY price;
