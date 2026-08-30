-- =====================================================================
-- 第 15 章 / 全文搜尋
-- =====================================================================
SET search_path TO shop, public;

CREATE EXTENSION IF NOT EXISTS pg_trgm;

\echo '── 1. tsvector / tsquery 基礎 ──'
SELECT to_tsvector('english', 'PostgreSQL is a powerful open-source database system');
SELECT to_tsquery('english', 'powerful & database');
SELECT plainto_tsquery('english', 'powerful database');
SELECT websearch_to_tsquery('english', '"art of computer" programming');

\echo '── 2. @@ 比對 ──'
SELECT
    to_tsvector('english', 'PostgreSQL is a powerful database')
    @@ to_tsquery('english', 'powerful') AS match1,
    to_tsvector('english', 'Hello World')
    @@ to_tsquery('english', 'powerful') AS match2;

SELECT title FROM books
WHERE to_tsvector('english', title) @@ websearch_to_tsquery('english', 'programming');

\echo '── 3. 加 Generated + GIN 索引 ──'
ALTER TABLE books
    ADD COLUMN IF NOT EXISTS tsv tsvector
    GENERATED ALWAYS AS (
        to_tsvector('english',
            COALESCE(title, '') || ' ' ||
            COALESCE((metadata->>'tags')::text, ''))
    ) STORED;

DROP INDEX IF EXISTS idx_books_tsv;
CREATE INDEX idx_books_tsv ON books USING gin(tsv);

SELECT title FROM books
WHERE tsv @@ websearch_to_tsquery('english', 'classic');

\echo '── 4. ts_rank 相關性排序 ──'
SELECT
    title,
    ts_rank(tsv, q) AS rank
FROM books, websearch_to_tsquery('english', 'programming') q
WHERE tsv @@ q
ORDER BY rank DESC;

\echo '── 5. ts_headline 關鍵字標示 ──'
SELECT
    title,
    ts_headline('english', title,
                websearch_to_tsquery('english', 'art programming'),
                'StartSel=[, StopSel=], MinWords=3, MaxWords=8') AS headline
FROM books
WHERE tsv @@ websearch_to_tsquery('english', 'art programming');

\echo '── 6. pg_trgm 模糊相似度 ──'
DROP INDEX IF EXISTS idx_books_title_trgm;
CREATE INDEX idx_books_title_trgm ON books USING gin(title gin_trgm_ops);

SELECT title, round(similarity(title, 'programing')::numeric, 3) AS sim
FROM books
ORDER BY sim DESC
LIMIT 5;

-- 清理加入的欄位 (避免影響後續章節)
ALTER TABLE books DROP COLUMN IF EXISTS tsv;
DROP INDEX IF EXISTS idx_books_tsv;
DROP INDEX IF EXISTS idx_books_title_trgm;
