-- =====================================================================
-- 第 9 章 / EXPLAIN ANALYZE 範例 (與資料量小有關,實際 plan 可能是 Seq Scan)
-- =====================================================================
SET search_path TO shop, public;

-- 提示:小表 planner 會選 Seq Scan,屬正常。要看到 Index Scan 可用大表。

\echo '── 條件 price > 500 ──'
EXPLAIN ANALYZE
SELECT * FROM books WHERE price > 500;

\echo '── 條件 isbn = (具體值) ──'
EXPLAIN ANALYZE
SELECT * FROM books WHERE isbn = '978-0201896831';

\echo '── 表達式索引被命中 (LOWER) ──'
EXPLAIN ANALYZE
SELECT * FROM books WHERE LOWER(title) = LOWER('SAPIENS');

\echo '── JSONB 包含查詢 (GIN) ──'
EXPLAIN ANALYZE
SELECT * FROM books WHERE metadata @> '{"language":"en"}';

\echo '── JSONB 陣列元素 ──'
EXPLAIN ANALYZE
SELECT * FROM books WHERE metadata->'tags' ? 'classic';

\echo '── 複合索引 (customer_id, status) ──'
EXPLAIN ANALYZE
SELECT * FROM orders WHERE customer_id = 1 AND status = 'completed';

\echo '── 觀察索引使用統計 ──'
SELECT
    relname AS table,
    indexrelname AS index,
    idx_scan,
    idx_tup_read,
    pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE schemaname = 'shop'
ORDER BY idx_scan DESC, pg_relation_size(indexrelid) DESC;

\echo '── 找出可能無用的索引 (idx_scan = 0) ──'
SELECT
    schemaname || '.' || relname AS table,
    indexrelname AS index,
    pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE schemaname = 'shop' AND idx_scan = 0;

-- 模擬大表觀察 (產生 100 萬列)
\echo '── 大表測試:產生 100 萬列觀察 Index Scan ──'
DROP TABLE IF EXISTS big_demo;
CREATE TABLE big_demo (
    id SERIAL PRIMARY KEY,
    val INT,
    label TEXT
);
INSERT INTO big_demo (val, label)
SELECT (random()*1000000)::INT, md5(random()::text)
FROM generate_series(1, 1000000);

\echo '── 沒索引時 ──'
EXPLAIN ANALYZE SELECT * FROM big_demo WHERE val = 12345;

CREATE INDEX idx_big_val ON big_demo(val);
ANALYZE big_demo;

\echo '── 有索引後 ──'
EXPLAIN ANALYZE SELECT * FROM big_demo WHERE val = 12345;

DROP TABLE big_demo;
