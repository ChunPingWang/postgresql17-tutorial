-- =====================================================================
-- 第 18 章 / EXPLAIN ANALYZE 實戰
-- =====================================================================
SET search_path TO shop, public;

\echo '── 1. 基本 EXPLAIN ──'
EXPLAIN SELECT * FROM books WHERE price > 500;

\echo '── 2. EXPLAIN ANALYZE (實際執行) ──'
EXPLAIN ANALYZE SELECT * FROM books WHERE price > 500;

\echo '── 3. 完整版:BUFFERS + VERBOSE ──'
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT b.title, a.name AS author, b.price
FROM books b
JOIN authors a ON a.id = b.author_id
WHERE b.price > 500
ORDER BY b.price DESC;

\echo '── 4. JSON 格式輸出 ──'
EXPLAIN (ANALYZE, FORMAT JSON)
SELECT * FROM orders o
JOIN customers c ON c.id = o.customer_id
WHERE o.status = 'completed';

\echo '── 5. 大表測試:建立 100 萬列 ──'
DROP TABLE IF EXISTS perf_test;
CREATE TABLE perf_test (
    id    SERIAL PRIMARY KEY,
    val   INT,
    cat   INT,
    label TEXT
);
INSERT INTO perf_test (val, cat, label)
SELECT
    (random() * 100000)::INT,
    (random() * 10)::INT + 1,
    md5(random()::text)
FROM generate_series(1, 500000);
ANALYZE perf_test;

\echo '── 6. 無索引 Seq Scan ──'
EXPLAIN ANALYZE SELECT * FROM perf_test WHERE val = 42000;

\echo '── 7. 加索引後 Index Scan ──'
CREATE INDEX idx_perf_val ON perf_test(val);
ANALYZE perf_test;
EXPLAIN ANALYZE SELECT * FROM perf_test WHERE val = 42000;

\echo '── 8. 低選擇度欄位 (planner 可能選 Seq Scan) ──'
EXPLAIN ANALYZE SELECT * FROM perf_test WHERE cat = 5;

\echo '── 9. Covering Index ──'
CREATE INDEX idx_perf_cat_label ON perf_test(cat) INCLUDE (label);
EXPLAIN ANALYZE SELECT cat, label FROM perf_test WHERE cat = 5 LIMIT 100;

\echo '── 10. Keyset 分頁 vs OFFSET ──'
EXPLAIN ANALYZE
SELECT * FROM perf_test ORDER BY id LIMIT 10 OFFSET 100000;    -- 慢

EXPLAIN ANALYZE
SELECT * FROM perf_test WHERE id > 100000 ORDER BY id LIMIT 10;  -- 快

DROP TABLE perf_test;
