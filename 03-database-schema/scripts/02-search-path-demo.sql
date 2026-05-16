-- =====================================================================
-- search_path 行為展示
-- 在 bookstore 資料庫執行:psql -d bookstore -f 02-search-path-demo.sql
-- =====================================================================

-- 重設 search_path 到預設值
SET search_path TO "$user", public;

-- 1. 查看當前 search_path
SHOW search_path;

-- 2. 試著查 books → 失敗,因為 books 在 shop schema,不在 search_path 內
\echo '〔測試 1〕未指定 schema 直接查 books (預期失敗)'
DO $$
BEGIN
    PERFORM 1 FROM books LIMIT 1;
EXCEPTION WHEN undefined_table THEN
    RAISE NOTICE '✅ 預期錯誤被捕獲: books 不在 search_path';
END$$;

-- 3. 用完整路徑就 OK
\echo '〔測試 2〕用 shop.books 完整路徑 (預期成功)'
SELECT count(*) AS book_count FROM shop.books;

-- 4. 加入 shop 到 search_path 後即可短名稱使用
SET search_path TO shop, public;
\echo '〔測試 3〕加入 shop 到 search_path 後使用短名 (預期成功)'
SELECT count(*) AS book_count FROM books;

-- 5. 新建物件會建在 search_path 第一個 schema (除非明確指定)
CREATE TABLE IF NOT EXISTS temp_demo (id INT);
SELECT schemaname, tablename
FROM pg_tables
WHERE tablename = 'temp_demo';

-- 6. 觀察 pg_catalog 永遠隱含在最前
SELECT current_schemas(true);

-- 7. 清理
DROP TABLE IF EXISTS temp_demo;
