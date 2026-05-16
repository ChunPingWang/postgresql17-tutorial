-- =====================================================================
-- 第 15 章 / JSONB 操作
-- =====================================================================
SET search_path TO shop, public;

\echo '── 1. 讀取 JSONB 欄位 ──'
SELECT
    title,
    metadata->>'language'      AS lang,
    metadata->'tags'           AS tags,
    (metadata->>'pages')::INT  AS pages,
    metadata ? 'edition'       AS has_edition
FROM books
ORDER BY id;

\echo '── 2. @> 包含查詢 ──'
SELECT title FROM books WHERE metadata @> '{"language":"en"}';
SELECT title FROM books WHERE metadata @> '{"tags":["classic"]}';

\echo '── 3. 路徑查詢 ──'
SELECT title, metadata #>> '{tags,0}' AS first_tag FROM books;

\echo '── 4. jsonb_each 展開 key-value ──'
SELECT title, key, value
FROM books, jsonb_each(metadata)
WHERE id = 1;

\echo '── 5. jsonb_array_elements 展開陣列 ──'
SELECT title, tag
FROM books, jsonb_array_elements_text(metadata->'tags') AS tag
ORDER BY title, tag;

\echo '── 6. 更新 JSONB ──'
BEGIN;
-- 新增欄位
UPDATE books SET metadata = metadata || '{"edition":4}'::jsonb WHERE id = 1;
-- 修改欄位
UPDATE books SET metadata = jsonb_set(metadata, '{pages}', '700') WHERE id = 1;
SELECT id, metadata FROM books WHERE id = 1;
-- 刪除欄位
UPDATE books SET metadata = metadata - 'edition' WHERE id = 1;
SELECT id, metadata FROM books WHERE id = 1;
ROLLBACK;

\echo '── 7. 聚合成 JSON ──'
SELECT
    c.name AS category,
    jsonb_agg(
        jsonb_build_object('id', b.id, 'title', b.title, 'price', b.price)
        ORDER BY b.price
    ) AS books_json
FROM books b
JOIN categories c ON c.id = b.category_id
GROUP BY c.name;
