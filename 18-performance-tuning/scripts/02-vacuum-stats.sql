-- =====================================================================
-- 第 18 章 / VACUUM、ANALYZE 與統計視圖
-- =====================================================================
SET search_path TO shop, public;

\echo '── 1. 手動 VACUUM ANALYZE ──'
VACUUM ANALYZE books;
VACUUM ANALYZE orders;
VACUUM ANALYZE order_items;

\echo '── 2. 查看各表的 vacuum 狀態 ──'
SELECT
    relname              AS table,
    n_live_tup          AS live,
    n_dead_tup          AS dead,
    round(n_dead_tup::numeric * 100 / NULLIF(n_live_tup + n_dead_tup, 0), 1) AS dead_pct,
    last_vacuum::date   AS last_vacuum,
    last_autovacuum::date AS last_autovacuum,
    last_analyze::date  AS last_analyze
FROM pg_stat_user_tables
WHERE schemaname = 'shop'
ORDER BY n_dead_tup DESC;

\echo '── 3. 製造 dead tuples (模擬高寫入場景) ──'
BEGIN;
UPDATE books SET stock = stock + 0;  -- 實際上更新了,製造舊版本
ROLLBACK;

VACUUM books;

\echo '── 4. 索引使用統計 ──'
SELECT
    indexrelname AS index,
    idx_scan     AS scans,
    idx_tup_read AS rows_read,
    pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE schemaname = 'shop'
ORDER BY idx_scan DESC;

\echo '── 5. Table 大小統計 ──'
SELECT
    relname AS table,
    pg_size_pretty(pg_relation_size(relid))        AS table_size,
    pg_size_pretty(pg_indexes_size(relid))         AS indexes_size,
    pg_size_pretty(pg_total_relation_size(relid))  AS total_size
FROM pg_stat_user_tables
WHERE schemaname = 'shop'
ORDER BY pg_total_relation_size(relid) DESC;

\echo '── 6. autovacuum 設定 ──'
SELECT name, setting, unit, short_desc
FROM pg_settings
WHERE name LIKE 'autovacuum%'
ORDER BY name;

\echo '── 7. postgresql.conf 效能相關設定 ──'
SELECT name, setting, unit
FROM pg_settings
WHERE name IN (
    'shared_buffers', 'work_mem', 'maintenance_work_mem',
    'effective_cache_size', 'wal_buffers', 'max_connections',
    'random_page_cost', 'effective_io_concurrency'
);
