-- =====================================================================
-- 第 16 章 / 問題排查情境模擬 (對應 README 16.8 節)
-- 用法 (以超級使用者執行):psql -d bookstore -f 03-troubleshooting-scenarios.sql
--
-- 角色是整個 cluster 共用的,本腳本的 demo 角色一律以 ts_ 開頭、
-- 物件放在 ts_perm schema,跑完會用 DROP OWNED + DROP ROLE 清乾淨。
-- 用 SET ROLE 在同一個 session 裡「扮演」受限角色,不必另開連線。
-- 所有預期會失敗的操作都包在 DO ... EXCEPTION 裡,腳本本身不會出現 ERROR。
-- =====================================================================
SET search_path TO shop, public;

-- ---------------------------------------------------------------------
-- 前置:清掉上次殘留 (讓腳本可重複執行)
-- ---------------------------------------------------------------------
RESET ROLE;
DO $$
DECLARE r TEXT;
BEGIN
    FOR r IN SELECT rolname FROM pg_roles WHERE rolname LIKE 'ts\_%' LOOP
        EXECUTE format('DROP OWNED BY %I CASCADE', r);
        EXECUTE format('DROP ROLE %I', r);
    END LOOP;
END$$;
DROP SCHEMA IF EXISTS ts_perm CASCADE;

-- 共用角色與 schema
CREATE ROLE ts_owner  NOLOGIN;                       -- 擁有物件的「migration」角色
CREATE ROLE ts_app    LOGIN PASSWORD 'ts_app_pw';    -- 應用程式連線角色
CREATE SCHEMA ts_perm AUTHORIZATION ts_owner;

-- =====================================================================
\echo ''
\echo '════ 情境 A:上週授權過了,新加的表卻 permission denied ════'
-- 症狀:上線初期 GRANT SELECT ON ALL TABLES 一切正常;
--       這週 migration 新增一張表,應用程式立刻報 permission denied for table
-- =====================================================================
SET ROLE ts_owner;
CREATE TABLE ts_perm.products (id INT PRIMARY KEY, name TEXT);
INSERT INTO ts_perm.products VALUES (1, 'widget');
RESET ROLE;

-- 上週的授權
GRANT USAGE ON SCHEMA ts_perm TO ts_app;
GRANT SELECT ON ALL TABLES IN SCHEMA ts_perm TO ts_app;

-- 這週 migration 新增一張表
SET ROLE ts_owner;
CREATE TABLE ts_perm.coupons (id INT PRIMARY KEY, code TEXT);
INSERT INTO ts_perm.coupons VALUES (1, 'WELCOME10');
RESET ROLE;

\echo '── A 排查步驟 1:以應用角色重現 (舊表 OK、新表失敗) ──'
DO $$
DECLARE n INT;
BEGIN
    SET ROLE ts_app;
    SELECT count(*) INTO n FROM ts_perm.products;
    RAISE NOTICE 'products (上週就有的表): 可讀, % 列', n;
    BEGIN
        SELECT count(*) INTO n FROM ts_perm.coupons;
        RAISE NOTICE 'coupons: 可讀 (不應發生)';
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE '❌ coupons (新表): % (SQLSTATE %)', SQLERRM, SQLSTATE;
    END;
    RESET ROLE;
END$$;

\echo '── A 排查步驟 2:比對兩張表的 ACL — 新表的 relacl 是空的 ──'
SELECT c.relname, c.relacl,
       has_table_privilege('ts_app', c.oid, 'SELECT') AS app_can_select
FROM pg_class c
WHERE c.relnamespace = 'ts_perm'::regnamespace AND c.relkind = 'r'
ORDER BY c.relname;

\echo '── A 排查步驟 3:有沒有設定預設權限?對哪個角色設的? ──'
SELECT defaclrole::regrole AS for_role, defaclnamespace::regnamespace AS in_schema,
       defaclobjtype AS objtype, defaclacl
FROM pg_default_acl;

-- 根因:GRANT ... ON ALL TABLES 只作用在「執行當下已存在」的表,
--       之後建立的表不會自動繼承。要用 ALTER DEFAULT PRIVILEGES。

\echo '── A 修正 (錯誤示範):超級使用者自己下 ALTER DEFAULT PRIVILEGES ──'
-- 沒寫 FOR ROLE → 只對「執行者 (postgres) 建立的表」生效;
-- 但表是 ts_owner 建的,所以等於沒設
ALTER DEFAULT PRIVILEGES IN SCHEMA ts_perm GRANT SELECT ON TABLES TO ts_app;

SET ROLE ts_owner;
CREATE TABLE ts_perm.shipments (id INT PRIMARY KEY);
RESET ROLE;

SELECT c.relname, has_table_privilege('ts_app', c.oid, 'SELECT') AS app_can_select
FROM pg_class c WHERE c.relnamespace = 'ts_perm'::regnamespace AND c.relkind = 'r'
ORDER BY c.relname;

\echo '── A 修正 (正確):FOR ROLE 指定「建表的那個角色」 ──'
ALTER DEFAULT PRIVILEGES FOR ROLE ts_owner IN SCHEMA ts_perm GRANT SELECT ON TABLES TO ts_app;
-- 已存在的表還是要補一次
GRANT SELECT ON ALL TABLES IN SCHEMA ts_perm TO ts_app;

SET ROLE ts_owner;
CREATE TABLE ts_perm.returns (id INT PRIMARY KEY);
RESET ROLE;

\echo '── A 驗證:新舊表都可讀,pg_default_acl 出現 for_role = ts_owner ──'
SELECT c.relname, has_table_privilege('ts_app', c.oid, 'SELECT') AS app_can_select
FROM pg_class c WHERE c.relnamespace = 'ts_perm'::regnamespace AND c.relkind = 'r'
ORDER BY c.relname;
SELECT defaclrole::regrole AS for_role, defaclnamespace::regnamespace AS in_schema, defaclacl
FROM pg_default_acl WHERE defaclnamespace = 'ts_perm'::regnamespace;

-- =====================================================================
\echo ''
\echo '════ 情境 B:表明明 GRANT 了,還是 permission denied for schema ════'
-- 症狀:GRANT SELECT ON 表 之後,查詢報的是 schema 的錯,不是表的錯
-- =====================================================================
CREATE ROLE ts_report NOLOGIN;
GRANT SELECT ON ts_perm.products TO ts_report;     -- 只給了表,忘了 schema

\echo '── B 排查步驟 1:重現,看清楚錯誤訊息講的是 schema 還是 table ──'
DO $$
DECLARE n INT;
BEGIN
    SET ROLE ts_report;
    BEGIN
        SELECT count(*) INTO n FROM ts_perm.products;
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE '❌ %', SQLERRM;
    END;
    RESET ROLE;
END$$;

\echo '── B 排查步驟 2:分層檢查 — 資料庫 CONNECT / schema USAGE / 表 SELECT ──'
SELECT has_database_privilege('ts_report', 'bookstore', 'CONNECT') AS db_connect,
       has_schema_privilege('ts_report', 'ts_perm', 'USAGE')        AS schema_usage,
       has_table_privilege('ts_report', 'ts_perm.products', 'SELECT') AS table_select;

-- 根因:權限是分層的,要「走進」schema 需要 USAGE,少了它表的權限根本用不到。
--       錯誤訊息會精確指出卡在哪一層,先看訊息裡的物件類型。

\echo '── B 修正:補 schema USAGE ──'
GRANT USAGE ON SCHEMA ts_perm TO ts_report;

\echo '── B 驗證 ──'
DO $$
DECLARE n INT;
BEGIN
    SET ROLE ts_report;
    SELECT count(*) INTO n FROM ts_perm.products;
    RAISE NOTICE '✅ ts_report 可讀 products: % 列', n;
    RESET ROLE;
END$$;

-- =====================================================================
\echo ''
\echo '════ 情境 C:RLS 政策「沒有作用」— 一下什麼都看不到,一下全看到 ════'
-- 症狀:C-1 應用角色查詢回 0 列,沒有任何錯誤
--       C-2 測試時用 owner 連線,每個租戶都看到全部資料
-- =====================================================================
SET ROLE ts_owner;
CREATE TABLE ts_perm.tenant_orders (id INT PRIMARY KEY, tenant_id INT NOT NULL, amount NUMERIC);
INSERT INTO ts_perm.tenant_orders VALUES (1, 1, 100), (2, 1, 200), (3, 2, 300);
ALTER TABLE ts_perm.tenant_orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON ts_perm.tenant_orders
    USING (tenant_id = current_setting('app.tenant_id', true)::INT);
RESET ROLE;
GRANT SELECT ON ts_perm.tenant_orders TO ts_app;

\echo '── C-1 排查步驟 1:應用角色查詢 → 0 列、沒有錯誤 (這個 session 從未設定 app.tenant_id) ──'
SET ROLE ts_app;
SELECT count(*) AS rows_seen_by_app FROM ts_perm.tenant_orders;
RESET ROLE;

\echo '── C-1 排查步驟 2:看 policy 的條件,再看參數目前的值與條件的結果 ──'
SELECT policyname, cmd, qual FROM pg_policies WHERE tablename = 'tenant_orders';
SELECT current_setting('app.tenant_id', true) AS tenant_setting,
       current_setting('app.tenant_id', true) IS NULL AS setting_is_null,
       (1 = current_setting('app.tenant_id', true)::INT) AS condition_result;

-- 根因:current_setting(..., true) 在參數不存在時回 NULL,「tenant_id = NULL」的結果是 NULL,
--       USING 條件不為 true → 每一列都被過濾掉,而且完全不報錯。
--       常見於連線池重用連線、或應用程式忘了在交易開頭 SET。

\echo '── C-1 修正:讓「沒設定」變成明確的錯誤,而不是靜默的 0 列 ──'
CREATE OR REPLACE FUNCTION ts_perm.current_tenant() RETURNS INT
LANGUAGE plpgsql STABLE AS $$
DECLARE v TEXT := current_setting('app.tenant_id', true);
BEGIN
    -- 注意兩種「沒設定」:從未設定 → NULL;設定過又 RESET → 空字串 ''
    IF v IS NULL OR v = '' THEN
        RAISE EXCEPTION 'app.tenant_id 未設定 — 應用程式必須在每個交易開頭 SET LOCAL app.tenant_id'
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN v::INT;
END$$;
GRANT EXECUTE ON FUNCTION ts_perm.current_tenant() TO ts_app;
SET ROLE ts_owner;
DROP POLICY tenant_isolation ON ts_perm.tenant_orders;
CREATE POLICY tenant_isolation ON ts_perm.tenant_orders
    USING (tenant_id = ts_perm.current_tenant());
RESET ROLE;

\echo '── C-1 驗證:沒設定 → 明確報錯;設定租戶 1 → 剛好 2 列 ──'
DO $$
DECLARE n INT;
BEGIN
    SET ROLE ts_app;
    BEGIN
        SELECT count(*) INTO n FROM ts_perm.tenant_orders;
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE '❌ (預期) %', SQLERRM;
    END;
    PERFORM set_config('app.tenant_id', '1', true);   -- true = 只在本交易內有效
    SELECT count(*) INTO n FROM ts_perm.tenant_orders;
    RAISE NOTICE '✅ tenant 1 看到 % 列', n;
    RESET ROLE;
END$$;

\echo '── C-1 補充:RESET 之後參數不是 NULL 而是空字串 — 修正函數兩種都擋得住 ──'
SET app.tenant_id = '1';
RESET app.tenant_id;
SELECT current_setting('app.tenant_id', true) AS after_reset,
       current_setting('app.tenant_id', true) IS NULL AS is_null;

\echo '── C-2 排查步驟 1:以 owner 身份設定租戶 1,卻看到 3 列 ──'
SET ROLE ts_owner;
SET app.tenant_id = '1';
SELECT count(*) AS rows_seen_by_owner FROM ts_perm.tenant_orders;
RESET ROLE;

\echo '── C-2 排查步驟 2:誰會繞過 RLS?owner / superuser / BYPASSRLS ──'
SELECT c.relname, c.relrowsecurity AS rls_enabled, c.relforcerowsecurity AS rls_forced,
       c.relowner::regrole AS owner
FROM pg_class c WHERE c.oid = 'ts_perm.tenant_orders'::regclass;
SELECT rolname, rolsuper, rolbypassrls FROM pg_roles
WHERE rolname IN ('ts_owner', 'ts_app', current_user) ORDER BY 1;

-- 根因:RLS 預設「不約束表的擁有者」,superuser 與 BYPASSRLS 角色也一律略過。
--       用 owner 測 RLS 永遠測不出來;應用程式也不該用 owner 連線。

\echo '── C-2 修正:FORCE ROW LEVEL SECURITY (並且改用非 owner 角色測試) ──'
ALTER TABLE ts_perm.tenant_orders FORCE ROW LEVEL SECURITY;

\echo '── C-2 驗證:owner 也只剩 2 列 ──'
SET ROLE ts_owner;
SELECT count(*) AS rows_seen_by_owner_after_force FROM ts_perm.tenant_orders;
RESET ROLE;
RESET app.tenant_id;

-- =====================================================================
\echo ''
\echo '════ 情境 D:離職同事的帳號刪不掉 — role cannot be dropped ════'
-- 症狀:DROP ROLE 報 "role ... cannot be dropped because some objects depend on it"
-- =====================================================================
CREATE ROLE ts_leaver LOGIN PASSWORD 'bye';
GRANT USAGE, CREATE ON SCHEMA ts_perm TO ts_leaver;
GRANT SELECT ON ts_perm.products TO ts_leaver;
SET ROLE ts_leaver;
CREATE TABLE ts_perm.leaver_notes (id INT);        -- 他建過的表 (他是 owner)
CREATE VIEW ts_perm.v_products AS SELECT * FROM ts_perm.products;
RESET ROLE;

\echo '── D 排查步驟 1:重現,讀 DETAIL — 它會列出依賴的物件 ──'
DO $$
DECLARE d TEXT;
BEGIN
    DROP ROLE ts_leaver;
EXCEPTION WHEN dependent_objects_still_exist THEN
    GET STACKED DIAGNOSTICS d = PG_EXCEPTION_DETAIL;
    RAISE NOTICE '❌ %', SQLERRM;
    RAISE NOTICE '   DETAIL: %', d;
END$$;

\echo '── D 排查步驟 2:列出他擁有的物件與被授予的權限 ──'
SELECT c.relname, c.relkind, c.relowner::regrole AS owner
FROM pg_class c
WHERE c.relowner = 'ts_leaver'::regrole;
SELECT c.relname, c.relacl FROM pg_class c
WHERE c.relnamespace = 'ts_perm'::regnamespace AND c.relacl::text LIKE '%ts_leaver%';

-- 根因:角色是 cluster 層級,但它「擁有」的物件與「被授予」的權限散在各資料庫;
--       任何一個還在,DROP ROLE 就會失敗。物件不能沒有 owner,要先轉手。

\echo '── D 修正:先 REASSIGN OWNED (轉移擁有權) 再 DROP OWNED (清掉授權),然後才 DROP ROLE ──'
-- 注意:這兩句要在「每一個」該角色有物件的資料庫裡各跑一次
REASSIGN OWNED BY ts_leaver TO ts_owner;
DROP OWNED BY ts_leaver;          -- 此時只剩 GRANT 授權,清掉
DROP ROLE ts_leaver;

\echo '── D 驗證:物件還在、owner 已換人、角色已刪除 ──'
SELECT c.relname, c.relowner::regrole AS owner
FROM pg_class c WHERE c.relname IN ('leaver_notes', 'v_products');
SELECT count(*) AS leaver_role_exists FROM pg_roles WHERE rolname = 'ts_leaver';

-- =====================================================================
\echo ''
\echo '════ 情境 E:SECURITY DEFINER 函數被 search_path 劫持 ════'
-- 症狀:一個以 owner 權限執行的函數,被低權限使用者「換掉」它呼叫的函數
-- (第 3 章 search_path 節、第 11 章也有提到,這裡實際演一次)
-- =====================================================================
SET ROLE ts_owner;
SET search_path TO ts_perm, public;   -- owner 寫函數時,search_path 裡有 ts_perm,所以「mask(name)」沒寫 schema
CREATE OR REPLACE FUNCTION ts_perm.mask(t TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$ SELECT left(t, 2) || '***' $$;
-- 沒有固定 search_path 的 SECURITY DEFINER 函數
CREATE OR REPLACE FUNCTION ts_perm.masked_products() RETURNS SETOF TEXT
LANGUAGE sql SECURITY DEFINER AS $$ SELECT mask(name) FROM ts_perm.products $$;
RESET ROLE;
RESET search_path;
GRANT EXECUTE ON FUNCTION ts_perm.masked_products() TO ts_app;
GRANT CREATE ON SCHEMA public TO ts_app;   -- 模擬 PG14 以前 public 人人可建物件的環境

\echo '── E 排查步驟 1:正常呼叫 ──'
SET ROLE ts_app;
SET search_path TO public, ts_perm;
SELECT ts_perm.masked_products() AS normal_result;

\echo '── E 排查步驟 2:低權限使用者在 public 放一個同名函數 → 結果被換掉 ──'
CREATE FUNCTION public.mask(t TEXT) RETURNS TEXT LANGUAGE sql AS $$ SELECT t || ' (leaked!)' $$;
SELECT ts_perm.masked_products() AS hijacked_result;
RESET ROLE;

\echo '── E 排查步驟 3:找出所有「沒固定 search_path 的 SECURITY DEFINER 函數」 ──'
SELECT p.oid::regprocedure AS func, p.proconfig
FROM pg_proc p
WHERE p.prosecdef AND (p.proconfig IS NULL OR NOT p.proconfig::text LIKE '%search_path%')
  AND p.pronamespace = 'ts_perm'::regnamespace;

-- 根因:SECURITY DEFINER 以 owner 權限執行,但 search_path 沿用「呼叫者」的設定;
--       呼叫者能在 search_path 前面的 schema 放同名物件,就能讓函數執行他的程式碼。

\echo '── E 修正:函數定義固定 search_path (第 3 章 3.7 節的建議) ──'
SET ROLE ts_owner;
ALTER FUNCTION ts_perm.masked_products() SET search_path = ts_perm, pg_temp;
RESET ROLE;

\echo '── E 驗證:同樣的劫持函數還在,結果已恢復正常 ──'
SET ROLE ts_app;
SET search_path TO public, ts_perm;
SELECT ts_perm.masked_products() AS fixed_result;
RESET ROLE;
RESET search_path;
DROP FUNCTION public.mask(TEXT);
REVOKE CREATE ON SCHEMA public FROM ts_app;

-- ---------------------------------------------------------------------
-- 清理 (角色是 cluster 共用的,一定要清)
-- ---------------------------------------------------------------------
RESET ROLE;
DO $$
DECLARE r TEXT;
BEGIN
    FOR r IN SELECT rolname FROM pg_roles WHERE rolname LIKE 'ts\_%' LOOP
        EXECUTE format('DROP OWNED BY %I CASCADE', r);
        EXECUTE format('DROP ROLE %I', r);
    END LOOP;
END$$;
DROP SCHEMA IF EXISTS ts_perm CASCADE;
SELECT count(*) AS leftover_ts_roles FROM pg_roles WHERE rolname LIKE 'ts\_%';
\echo ''
\echo '✅ 情境模擬完成 (demo 角色與 schema 已清除)'
