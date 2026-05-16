-- =====================================================================
-- 第 18 章 / pg_stat_statements — 慢查詢分析
-- =====================================================================
SET search_path TO shop, public;

-- 啟用 extension (需要超級使用者)
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- 執行一些查詢讓統計有資料
SELECT COUNT(*) FROM books;
SELECT * FROM orders JOIN customers c ON c.id = orders.customer_id;
SELECT b.title, a.name FROM books b JOIN authors a ON a.id = b.author_id;

\echo '── 1. 執行最多次的查詢 ──'
SELECT
    left(query, 80) AS query,
    calls,
    round(mean_exec_time::numeric, 2) AS avg_ms,
    round(total_exec_time::numeric, 2) AS total_ms
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat%'
ORDER BY calls DESC
LIMIT 10;

\echo '── 2. 平均最慢的查詢 ──'
SELECT
    left(query, 80) AS query,
    calls,
    round(mean_exec_time::numeric, 2) AS avg_ms
FROM pg_stat_statements
WHERE calls > 1
  AND query NOT LIKE '%pg_stat%'
ORDER BY mean_exec_time DESC
LIMIT 10;

\echo '── 3. 總耗時最多的查詢 ──'
SELECT
    left(query, 80) AS query,
    calls,
    round(total_exec_time::numeric, 2) AS total_ms
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat%'
ORDER BY total_exec_time DESC
LIMIT 10;

\echo '── 4. 重置統計 ──'
SELECT pg_stat_statements_reset();
\echo '統計已重置'
