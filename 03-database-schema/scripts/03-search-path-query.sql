-- =====================================================================
-- search_path 查詢示範:三個層級的設定各存在哪、如何查
-- 在 bookstore 資料庫執行:psql -d bookstore -f 03-search-path-query.sql
-- =====================================================================

-- 1. 當前 session 生效的值
\echo '〔查詢 1〕當前 session 的 search_path'
SHOW search_path;

-- 同義寫法
SELECT current_setting('search_path');

-- 含隱含 schema (pg_catalog、pg_temp) 的完整生效清單
\echo '〔查詢 2〕實際生效的完整搜尋清單 (含隱含 schema)'
SELECT current_schemas(true);

-- 2. 先建立 DATABASE / ROLE 層級的設定,才有東西可查
\echo '〔準備〕建立 DATABASE 與 ROLE 層級的 search_path 設定'
ALTER DATABASE bookstore SET search_path TO shop, public;
ALTER ROLE CURRENT_USER SET search_path TO shop, public;

-- 3. 查 DATABASE / ROLE 層級的持久設定 (存在 pg_db_role_setting)
\echo '〔查詢 3〕pg_db_role_setting:所有持久設定'
SELECT COALESCE(d.datname, '(所有資料庫)') AS database,
       COALESCE(r.rolname, '(所有角色)')   AS role,
       s.setconfig
FROM pg_db_role_setting s
LEFT JOIN pg_database d ON d.oid = s.setdatabase
LEFT JOIN pg_roles    r ON r.oid = s.setrole;

-- psql 快捷指令,同樣的資訊一行看完
\echo '〔查詢 4〕\\drds 快捷指令'
\drds

-- 4. 當前值是從哪一層來的?
--    source: default / database / user / session
--    注意:ALTER 的設定要「新 session」才生效,所以此刻 source 仍是 default;
--    重新連線後再查,就會變成 user (ROLE 設定優先於 DATABASE 設定)
\echo '〔查詢 5〕pg_settings:當前值的來源層級'
SELECT name, setting, source
FROM pg_settings
WHERE name = 'search_path';

-- 5. session 內 SET 之後,source 立即變成 session
SET search_path TO shop, public;
\echo '〔查詢 6〕SET 之後 source 變為 session'
SELECT name, setting, source
FROM pg_settings
WHERE name = 'search_path';

-- 6. 清理:還原本示範建立的持久設定
\echo '〔清理〕RESET 還原 DATABASE 與 ROLE 設定'
ALTER DATABASE bookstore RESET search_path;
ALTER ROLE CURRENT_USER RESET search_path;

-- 確認已清空 (應回傳 0 筆)
SELECT count(*) AS remaining_settings FROM pg_db_role_setting;
