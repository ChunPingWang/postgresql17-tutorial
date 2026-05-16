-- =====================================================================
-- 第 8 章 / FILTER 子句、ROLLUP、CUBE、GROUPING SETS
-- =====================================================================
SET search_path TO shop, public;

-- 1) FILTER:同一查詢做多種條件統計
SELECT
    COUNT(*)                                          AS orders_total,
    COUNT(*) FILTER (WHERE status = 'completed')      AS completed,
    COUNT(*) FILTER (WHERE status = 'paid')           AS paid,
    COUNT(*) FILTER (WHERE status = 'cancelled')      AS cancelled,
    SUM(total)                                         AS revenue_all,
    SUM(total) FILTER (WHERE status = 'completed')    AS revenue_completed,
    AVG(total) FILTER (WHERE status = 'completed')::NUMERIC(10,2) AS avg_completed
FROM orders;

-- 2) ROLLUP - 逐層彙總 (category × status,加上 category 小計與總計)
SELECT
    COALESCE(c.name, '〔全部〕')     AS category,
    COALESCE(o.status::text, '〔小計〕') AS status,
    COUNT(*) AS cnt,
    SUM(oi.quantity * oi.unit_price) AS revenue
FROM books b
JOIN categories c    ON c.id = b.category_id
JOIN order_items oi  ON oi.book_id = b.id
JOIN orders o        ON o.id = oi.order_id
GROUP BY ROLLUP (c.name, o.status)
ORDER BY c.name NULLS LAST, o.status NULLS LAST;

-- 3) CUBE - 所有維度組合
SELECT
    COALESCE(c.name, '〔ALL CAT〕')   AS category,
    COALESCE(o.status::text, '〔ALL STATUS〕') AS status,
    COUNT(*) AS cnt
FROM books b
JOIN categories c    ON c.id = b.category_id
JOIN order_items oi  ON oi.book_id = b.id
JOIN orders o        ON o.id = oi.order_id
GROUP BY CUBE (c.name, o.status)
ORDER BY c.name NULLS LAST, o.status NULLS LAST;

-- 4) GROUPING SETS - 自由組合 (相當於 union 多個 GROUP BY)
SELECT
    COALESCE(c.name, '〔ALL〕') AS category,
    COALESCE(o.status::text, '〔ALL〕') AS status,
    COUNT(*) AS cnt
FROM books b
JOIN categories c    ON c.id = b.category_id
JOIN order_items oi  ON oi.book_id = b.id
JOIN orders o        ON o.id = oi.order_id
GROUP BY GROUPING SETS ((c.name, o.status), (c.name), ());

-- 5) 用 GROUPING() 標示哪些欄位被「彙總掉」
SELECT
    GROUPING(c.name)   AS g_cat,    -- 1 表示這列把 cat 維度彙總掉
    GROUPING(o.status) AS g_status,
    c.name, o.status::text, COUNT(*)
FROM books b
JOIN categories c    ON c.id = b.category_id
JOIN order_items oi  ON oi.book_id = b.id
JOIN orders o        ON o.id = oi.order_id
GROUP BY ROLLUP (c.name, o.status);
