-- =====================================================================
-- 第 9 章 / 建立各種索引
-- =====================================================================
SET search_path TO shop, public;

-- 先清掉之前可能存在的測試索引
DROP INDEX IF EXISTS idx_books_price;
DROP INDEX IF EXISTS idx_books_category;
DROP INDEX IF EXISTS idx_books_isbn;
DROP INDEX IF EXISTS idx_books_lower_title;
DROP INDEX IF EXISTS idx_books_meta_gin;
DROP INDEX IF EXISTS idx_books_meta_tags;
DROP INDEX IF EXISTS idx_active_orders;
DROP INDEX IF EXISTS idx_orders_customer_status;
DROP INDEX IF EXISTS idx_orders_cover;

-- 1) B-Tree (單欄)
CREATE INDEX idx_books_price    ON books(price);
CREATE INDEX idx_books_category ON books(category_id);

-- 2) UNIQUE 索引
-- (isbn 欄位 CREATE TABLE 時已是 UNIQUE,這裡示範手動建立)
CREATE UNIQUE INDEX idx_books_isbn_explicit ON books(isbn);

-- 3) 多欄複合索引 (順序重要)
CREATE INDEX idx_orders_customer_status
    ON orders(customer_id, status);

-- 4) 表達式索引 (大小寫不敏感搜尋)
CREATE INDEX idx_books_lower_title ON books (LOWER(title));

-- 5) 部分索引:只索引「在售中」的書 (stock > 0)
CREATE INDEX idx_books_in_stock ON books(category_id) WHERE stock > 0;

-- 6) GIN 對 JSONB
CREATE INDEX idx_books_meta_gin ON books USING gin (metadata);

-- 7) GIN 對特定 JSONB path (tags 陣列)
CREATE INDEX idx_books_meta_tags
    ON books USING gin ((metadata->'tags'));

-- 8) 包含欄位 (Covering Index)
CREATE INDEX idx_orders_cover
    ON orders(customer_id) INCLUDE (status, total);

-- 9) 查看索引清單與大小
SELECT
    indexname,
    pg_size_pretty(pg_relation_size(indexname::regclass)) AS size
FROM pg_indexes
WHERE schemaname = 'shop' AND tablename = 'books'
ORDER BY pg_relation_size(indexname::regclass) DESC;

-- 10) 跑 ANALYZE 讓 planner 有最新統計
ANALYZE books;
ANALYZE orders;

\echo '✅ 索引已建立。可執行 02-explain-analyze.sql 觀察 planner 行為'
