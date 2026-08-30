-- =====================================================================
-- 第 3 章 / 問題排查情境模擬 (對應 README 3.10 節)
-- 用法:psql -d bookstore -f 04-troubleshooting-scenarios.sql
--
-- 每個情境都用自己的 demo 物件 (schema / role / database),跑完會清掉,
-- 不影響 bookstore 其他章節。建議搭配 README 3.10 的「排查順序」逐段執行。
-- 注意:情境 D 會刻意出現 2 個 ERROR,那是情境的一部分,不是腳本壞掉。
-- 情境 D 需要超級使用者 (建立 dblink extension、DROP DATABASE)。
-- =====================================================================

-- =====================================================================
\echo ''
\echo '════ 情境 A:relation "books" does not exist — 但表明明在 ════'
-- 症狀:同事的 SQL 在他機器上能跑,在你這裡卻報 relation does not exist
-- =====================================================================
SET search_path TO "$user", public;   -- 模擬「剛連線、什麼都沒設」的狀態

\echo '── A-1 排查步驟 1:重現錯誤 (用 DO 攔下來,方便看訊息) ──'
DO $$
BEGIN
    PERFORM 1 FROM books LIMIT 1;
EXCEPTION WHEN undefined_table THEN
    RAISE NOTICE '錯誤訊息:%', SQLERRM;
END$$;

\echo '── A-1 排查步驟 2:表到底在不在?在哪個 schema? ──'
SELECT schemaname, tablename FROM pg_tables WHERE tablename = 'books';

\echo '── A-1 排查步驟 3:那我現在從哪些 schema 找? ──'
SHOW search_path;
SELECT current_schemas(true) AS effective_search_order;

-- 根因:表在 shop,search_path 只有 "$user", public → 短名 books 找不到。
--       錯誤訊息說的「does not exist」是「在我找的範圍內不存在」,不是表真的不在。

\echo '── A-1 修正 (擇一):寫全名,或把 shop 加進 search_path ──'
SELECT count(*) AS via_full_name FROM shop.books;
SET search_path TO shop, public;
SELECT count(*) AS via_search_path FROM books;

\echo ''
\echo '── A-2 同樣的錯誤訊息,另一個根因:對 schema 沒有 USAGE 權限 ──'
DROP ROLE IF EXISTS ch03_reader;
CREATE ROLE ch03_reader NOLOGIN;
SET ROLE ch03_reader;
SET search_path TO shop, public;      -- search_path 明明是對的

\echo '── A-2 排查步驟 1:重現 — 短名報 does not exist,全名卻報 permission denied ──'
DO $$
BEGIN
    PERFORM 1 FROM books LIMIT 1;
EXCEPTION WHEN undefined_table THEN
    RAISE NOTICE '短名 books → %', SQLERRM;
END$$;
DO $$
BEGIN
    PERFORM 1 FROM shop.books LIMIT 1;
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE '全名 shop.books → %', SQLERRM;
END$$;

\echo '── A-2 排查步驟 2:search_path 有 shop,但實際生效清單裡沒有它 ──'
SHOW search_path;
SELECT current_schemas(true) AS effective_search_order;   -- shop 被靜默跳過

\echo '── A-2 排查步驟 3:直接問權限 (以 DBA 身份替該 role 查,避免自己也被擋) ──'
RESET ROLE;
SELECT has_schema_privilege('ch03_reader', 'shop', 'USAGE')       AS schema_usage,
       has_table_privilege('ch03_reader', 'shop.books', 'SELECT') AS table_select;

-- 根因:沒有 USAGE 權限的 schema 在名稱解析時會被「靜默跳過」,不會報權限錯誤,
--       所以你看到的是 does not exist。這是最容易誤判成 search_path 問題的情況。

\echo '── A-2 修正:授與 schema USAGE + 表 SELECT ──'
GRANT USAGE ON SCHEMA shop TO ch03_reader;
GRANT SELECT ON shop.books TO ch03_reader;

\echo '── A-2 驗證:同一個 role、同一個 search_path,現在找得到了 ──'
SET ROLE ch03_reader;
SELECT current_schemas(true) AS effective_search_order;
SELECT count(*) AS books_visible FROM books;
RESET ROLE;
DROP OWNED BY ch03_reader;   -- 先收回權限,否則 DROP ROLE 會因「有物件依賴」失敗
DROP ROLE ch03_reader;

-- =====================================================================
\echo ''
\echo '════ 情境 B:表建好了,卻建到別的 schema ════'
-- 症狀:migration 跑完沒報錯,程式卻找不到新表 shop.orders_archive
-- =====================================================================
SET search_path TO "$user", public;   -- 一個忘了設 search_path 的 migration session
DROP TABLE IF EXISTS public.orders_archive;
DROP TABLE IF EXISTS shop.orders_archive;

CREATE TABLE orders_archive (id INT PRIMARY KEY, archived_at TIMESTAMPTZ DEFAULT now());

\echo '── B 排查步驟 1:程式端的錯誤 ──'
DO $$
BEGIN
    PERFORM 1 FROM shop.orders_archive LIMIT 1;
EXCEPTION WHEN undefined_table THEN
    RAISE NOTICE '程式看到的錯誤:%', SQLERRM;
END$$;

\echo '── B 排查步驟 2:表跑去哪了? ──'
SELECT schemaname, tablename FROM pg_tables WHERE tablename = 'orders_archive';

\echo '── B 排查步驟 3:當時的「落點」是哪個 schema?為什麼? ──'
SHOW search_path;                 -- "$user", public
SELECT current_user, current_schema();   -- 落點是 public,不是 "$user"
SELECT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = current_user) AS user_schema_exists;

-- 根因:CREATE TABLE 未指定 schema 時,建在 search_path 中「第一個實際存在」的 schema。
--       "$user" 展開後的同名 schema 不存在 → 被跳過 → 落到 public。

\echo '── B 修正:把表搬到正確的 schema (資料一起搬,不用重建) ──'
ALTER TABLE public.orders_archive SET SCHEMA shop;

\echo '── B 驗證 ──'
SELECT schemaname, tablename FROM pg_tables WHERE tablename = 'orders_archive';
SELECT count(*) FROM shop.orders_archive;
DROP TABLE shop.orders_archive;

\echo ''
\echo '── B-2 反向陷阱:有人替你建了同名 schema,落點會默默改變 ──'
DO $$
BEGIN
    EXECUTE format('CREATE SCHEMA %I', current_user);
END$$;
SELECT current_schema();          -- 變成你的使用者名稱了
CREATE TABLE silently_moved (id INT);
SELECT schemaname, tablename FROM pg_tables WHERE tablename = 'silently_moved';
DO $$
BEGIN
    EXECUTE format('DROP SCHEMA %I CASCADE', current_user);
END$$;

-- =====================================================================
\echo ''
\echo '════ 情境 C:查詢回傳「錯的資料」— 同名物件遮蔽 ════'
-- 症狀:SELECT * FROM items 回來的列數不對,DROP TABLE 刪錯表
-- =====================================================================
DROP SCHEMA IF EXISTS demo_a CASCADE;
DROP SCHEMA IF EXISTS demo_b CASCADE;
CREATE SCHEMA demo_a;
CREATE SCHEMA demo_b;
CREATE TABLE demo_a.items (id INT, note TEXT);
CREATE TABLE demo_b.items (id INT, note TEXT);
INSERT INTO demo_a.items SELECT g, 'from demo_a' FROM generate_series(1, 100) g;
INSERT INTO demo_b.items SELECT g, 'from demo_b' FROM generate_series(1, 3) g;

SET search_path TO demo_b, demo_a, public;

\echo '── C 排查步驟 1:重現 — 以為在查 demo_a.items (100 列),實際只有 3 列 ──'
SELECT count(*) AS row_count, min(note) AS which_table FROM items;

\echo '── C 排查步驟 2:短名 items 到底解析成哪一張? ──'
SELECT 'items'::regclass AS displayed_name,        -- 顯示短名,看不出來
       n.nspname AS resolved_schema
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.oid = 'items'::regclass;

\echo '── C 排查步驟 3:有幾個同名表?各在哪? ──'
SELECT schemaname, tablename FROM pg_tables WHERE tablename = 'items' ORDER BY 1;

-- 根因:search_path 的順序決定「第一個找到的」贏;demo_b 排在 demo_a 前面。

\echo '── C-2 更隱蔽的遮蔽:暫時表永遠排最前,而且 SHOW search_path 看不到它 ──'
CREATE TEMP TABLE items (id INT, note TEXT);
SHOW search_path;                                    -- 沒有 pg_temp
SELECT current_schemas(true) AS effective_search_order;   -- pg_temp_N 排第一
SELECT count(*) AS row_count FROM items;             -- 0 列:查到暫時表了

\echo '── C-2 陷阱:DROP TABLE items 刪的是哪一張? ──'
DROP TABLE items;                                    -- 刪掉的是暫時表
SELECT schemaname, tablename FROM pg_tables WHERE tablename = 'items' ORDER BY 1;  -- 兩張都還在

\echo '── C 修正:多 schema 同名時一律寫全名;DDL (DROP/ALTER) 更要寫全名 ──'
SELECT count(*) AS demo_a_rows FROM demo_a.items;
SELECT count(*) AS demo_b_rows FROM demo_b.items;
DROP SCHEMA demo_a CASCADE;
DROP SCHEMA demo_b CASCADE;
SET search_path TO shop, public;

-- =====================================================================
\echo ''
\echo '════ 情境 D:DROP DATABASE 失敗 — is being accessed by other users ════'
-- 症狀:要重建測試資料庫,DROP DATABASE 一直報錯,但你「明明沒開別的連線」
-- =====================================================================
CREATE EXTENSION IF NOT EXISTS dblink;   -- 用來在同一個腳本裡模擬「另一個連線」
DROP DATABASE IF EXISTS ch03_drop_demo WITH (FORCE);
CREATE DATABASE ch03_drop_demo;

-- 模擬:某個 pgAdmin 視窗 / 應用程式連線池還連著這個資料庫
SELECT dblink_connect('other_session', 'dbname=ch03_drop_demo');

\echo '── D 重現 (下面這個 ERROR 是預期的) ──'
DROP DATABASE ch03_drop_demo;

\echo '── D 排查步驟 1:誰連著它?pg_stat_activity 直接告訴你 ──'
SELECT pid, usename, application_name, client_addr, state, backend_start
FROM pg_stat_activity
WHERE datname = 'ch03_drop_demo';

-- 根因:DROP DATABASE 需要沒有任何 session 連著目標資料庫。
--       常見的「隱形連線」:pgAdmin 的 Object Explorer、應用程式連線池、忘記關的 psql。

\echo '── D 修正 (擇一):逐一 pg_terminate_backend(pid),或直接 WITH (FORCE) ──'
DROP DATABASE ch03_drop_demo WITH (FORCE);

\echo '── D 驗證:資料庫已不存在,連線也被踢掉了 ──'
SELECT count(*) AS still_exists FROM pg_database WHERE datname = 'ch03_drop_demo';
SELECT count(*) AS remaining_sessions FROM pg_stat_activity WHERE datname = 'ch03_drop_demo';
SELECT dblink_disconnect('other_session');

\echo ''
\echo '── D-2 同一家族的錯誤:CREATE DATABASE cannot run inside a transaction block ──'
\echo '   (pgAdmin 一次執行多條語句、或腳本用 psql -1 時最常見;下面的 ERROR 是預期的)'
BEGIN;
CREATE DATABASE ch03_in_txn;
ROLLBACK;
-- 修正:CREATE / DROP DATABASE 單獨執行,不要包在 BEGIN ... COMMIT 或 psql -1 裡

-- ---------------------------------------------------------------------
-- 清理
-- ---------------------------------------------------------------------
DROP EXTENSION IF EXISTS dblink;
SET search_path TO shop, public;
\echo ''
\echo '✅ 情境模擬完成 (demo 物件已清除)'
