-- =====================================================================
-- 第 11 章 / 問題排查情境模擬 (對應 README 11.13 節)
-- 用法:psql -d bookstore -f 04-troubleshooting-scenarios.sql
--
-- 每個情境都用自己的 demo 物件,跑完會清掉,不動 shop.* 既有資料。
-- 建議搭配 README 11.13 的「排查順序」逐段執行、對照輸出。
-- 注意:情境 A / A-2 / C 會刻意各出現一個 ERROR,那是情境的一部分,
--       不是腳本壞掉 (下面都有標「← 預期的 ERROR」)。
-- =====================================================================
SET search_path TO shop, public;

-- =====================================================================
\echo ''
\echo '════ 情境 A:structure of query does not match function result type ════'
-- 症狀:RETURNS TABLE 的函數,單獨跑裡面那句 SELECT 沒事,一包成函數呼叫就報錯
-- =====================================================================

\echo '── A 重現:宣告 title 為 TEXT,但 books.title 是 VARCHAR(200) ──'
CREATE OR REPLACE FUNCTION shop.demo_mismatch(c_name TEXT)
RETURNS TABLE (id INT, title TEXT)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN QUERY
    SELECT b.id, b.title            -- b.title 是 varchar(200),不是 text
    FROM shop.books b
    JOIN shop.categories c ON c.id = b.category_id
    WHERE c.name = c_name;
END;$$;

\echo '── A 排查步驟 1:呼叫它 (← 預期的 ERROR,請讀 DETAIL 那一行) ──'
DO $$
BEGIN
    PERFORM * FROM shop.demo_mismatch('Database');
EXCEPTION WHEN datatype_mismatch THEN
    RAISE NOTICE '攔到 SQLSTATE=% : %', SQLSTATE, SQLERRM;
END;$$;
-- DETAIL 會明講:Returned type character varying(200) does not match
--               expected type text in column 2. → 第 2 欄型別對不上

-- 根因:RETURN QUERY 會把查詢每一欄的型別,和 RETURNS TABLE 宣告的型別做「嚴格」比對;
--       varchar(200) 與 text 是不同型別,不會自動放行。

\echo '── A 修正:把回傳欄位明確轉成宣告的型別 (b.title::TEXT) ──'
CREATE OR REPLACE FUNCTION shop.demo_mismatch(c_name TEXT)
RETURNS TABLE (id INT, title TEXT)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN QUERY
    SELECT b.id, b.title::TEXT       -- ← 修正點
    FROM shop.books b
    JOIN shop.categories c ON c.id = b.category_id
    WHERE c.name = c_name;
END;$$;

\echo '── A 驗證:現在正常回傳 ──'
SELECT * FROM shop.demo_mismatch('Database');

\echo ''
\echo '── A-2 同類問題:function xxx(text) does not exist (引數型別對不上) ──'
CREATE OR REPLACE FUNCTION shop.tax(amount NUMERIC)
RETURNS NUMERIC LANGUAGE sql IMMUTABLE AS $$ SELECT amount * 0.05; $$;

\echo '── A-2 排查步驟 1:傳進來的是 text 欄位 (← 預期的 ERROR) ──'
DO $$
BEGIN
    PERFORM shop.tax(text '100');    -- 模擬「把字串欄位直接丟進數值參數」
EXCEPTION WHEN undefined_function THEN
    RAISE NOTICE '攔到:% (HINT:加上明確型別轉換)', SQLERRM;
END;$$;

\echo '── A-2 排查步驟 2:用 \df 看實際簽章,確認參數型別 ──'
SELECT p.proname, pg_get_function_arguments(p.oid) AS args
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'shop' AND p.proname = 'tax';

\echo '── A-2 修正:呼叫端明確轉型 (::NUMERIC),或修正來源欄位型別 ──'
SELECT shop.tax('100'::NUMERIC) AS ok;

-- =====================================================================
\echo ''
\echo '════ 情境 B:查詢突然變慢 — 函數標成 VOLATILE 無法被摺疊 ════'
-- 症狀:WHERE 用了一個「引數是常數」的函數,卻每一列都重算一次
-- =====================================================================
DROP TABLE IF EXISTS demo_nums;
CREATE TABLE demo_nums AS SELECT g AS n FROM generate_series(1, 200000) g;

-- 同一段邏輯,只差 volatility 標籤
CREATE OR REPLACE FUNCTION shop.slow_square(x INT) RETURNS INT
LANGUAGE plpgsql VOLATILE  AS $$ BEGIN RETURN x * x; END; $$;   -- 預設就是 VOLATILE
CREATE OR REPLACE FUNCTION shop.fast_square(x INT) RETURNS INT
LANGUAGE plpgsql IMMUTABLE AS $$ BEGIN RETURN x * x; END; $$;

\echo '── B 排查步驟 1:VOLATILE 版 — 看 Filter 那行是「函數呼叫」,每列重算 ──'
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT count(*) FROM demo_nums WHERE n = shop.slow_square(500);
-- Filter: (n = slow_square(500))  → 20 萬列各呼叫一次,約 28 ms

-- 根因:planner 不敢對 VOLATILE 函數做常數摺疊 (它「可能每次結果不同」),
--       即使引數是常數 500,也只能保留成函數呼叫,逐列執行。

\echo '── B 修正 + 驗證:改標 IMMUTABLE,planner 把它摺成常數 250000 ──'
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT count(*) FROM demo_nums WHERE n = shop.fast_square(500);
-- Filter: (n = 250000)  → 直接比常數,約 4 ms (快約 7 倍)
-- 提醒:volatility 是「承諾」,標錯 (對其實會變的邏輯標 IMMUTABLE) 會拿到過期結果。

DROP TABLE demo_nums;

-- =====================================================================
\echo ''
\echo '════ 情境 C:PROCEDURE 裡 COMMIT 報 invalid transaction termination ════'
-- 症狀:單獨 CALL 沒問題,一旦包在交易 (或某些工具的 auto-transaction) 裡就爆
-- =====================================================================
CREATE OR REPLACE PROCEDURE shop.demo_commit()
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE shop.books SET stock = stock WHERE id = 1;   -- no-op,不改資料
    COMMIT;
END;$$;

\echo '── C 排查步驟 1:模擬「被外層交易包住」再 CALL (← 預期的 ERROR) ──'
DO $$
BEGIN
    -- 用一個 sub-block 承接;真實情況是 BEGIN; CALL ...; 或工具的交易模式
    RAISE NOTICE '(說明) 在 BEGIN; ... ; 內 CALL 這支 procedure 會得到:';
END;$$;
BEGIN;
CALL shop.demo_commit();     -- ← 預期的 ERROR: invalid transaction termination
ROLLBACK;

-- 根因:PROCEDURE 內部要 COMMIT,必須自己是「頂層交易」。外面已經 BEGIN 開了一個
--       交易,procedure 就無權結束它 → invalid transaction termination。

\echo '── C 修正:不要用外層 BEGIN 包它,直接 CALL (它自成頂層交易) ──'
CALL shop.demo_commit();
\echo '   (上面這句沒有被 BEGIN 包住,COMMIT 成功,無 ERROR)'

-- =====================================================================
\echo ''
\echo '════ 情境 D:SECURITY DEFINER 函數被 search_path 劫持 ════'
-- 症狀:一支以擁有者權限執行的函數,結果隨呼叫者的 search_path 而變
-- =====================================================================
CREATE OR REPLACE FUNCTION shop.vulnerable_count() RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE n BIGINT;
BEGIN
    SELECT count(*) INTO n FROM books;   -- 未加 schema 前綴的 "books"
    RETURN n;
END;$$;

\echo '── D 排查步驟 1:正常呼叫 — search_path 指向 shop,拿到 shop.books = 8 ──'
SET search_path TO shop, public;
SELECT shop.vulnerable_count() AS normal_count;

\echo '── D 排查步驟 2:呼叫者在自己可寫的 schema 放一張同名 books,前置到 search_path ──'
CREATE SCHEMA IF NOT EXISTS demo_evil;
CREATE TABLE demo_evil.books AS SELECT 1 WHERE false;   -- 0 列 (真實攻擊會回傳假資料/竊取)
SET search_path TO demo_evil, shop, public;
SELECT shop.vulnerable_count() AS hijacked_count;
-- 未加前綴的 "books" 現在解析到 demo_evil.books → 回 0,函數行為被外部改變

-- 根因:SECURITY DEFINER 用「定義者」權限執行,但物件名稱仍照「呼叫者」的
--       search_path 解析;未固定 search_path + 未加 schema 前綴 = 可被劫持。

\echo '── D 修正:函數固定 search_path,名稱不再受呼叫者影響 ──'
CREATE OR REPLACE FUNCTION shop.safe_count() RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = shop, pg_temp          -- ← 修正點:釘死解析路徑
AS $$
DECLARE n BIGINT;
BEGIN
    SELECT count(*) INTO n FROM books;
    RETURN n;
END;$$;

\echo '── D 驗證:即使呼叫者 search_path 有 demo_evil,仍解析到 shop.books = 8 ──'
SELECT shop.safe_count() AS safe_count;   -- search_path 仍是 demo_evil,shop,public

-- 清理
RESET search_path;
SET search_path TO shop, public;
DROP SCHEMA demo_evil CASCADE;

-- ---------------------------------------------------------------------
-- 清理所有 demo 物件
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS shop.demo_mismatch(TEXT);
DROP FUNCTION IF EXISTS shop.tax(NUMERIC);
DROP FUNCTION IF EXISTS shop.slow_square(INT);
DROP FUNCTION IF EXISTS shop.fast_square(INT);
DROP PROCEDURE IF EXISTS shop.demo_commit();
DROP FUNCTION IF EXISTS shop.vulnerable_count();
DROP FUNCTION IF EXISTS shop.safe_count();
\echo ''
\echo '✅ 情境模擬完成 (demo 物件已清除)'
