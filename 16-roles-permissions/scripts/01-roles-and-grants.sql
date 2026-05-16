-- =====================================================================
-- 第 16 章 / 角色與權限
-- 以超級使用者身份執行:psql -d bookstore -f 01-roles-and-grants.sql
-- =====================================================================
SET search_path TO shop, public;

-- 清理 (如果先前有殘留)
DROP ROLE IF EXISTS tutorial_readonly;
DROP ROLE IF EXISTS tutorial_readwrite;
DROP ROLE IF EXISTS tutorial_app;

-- 1) 建立群組角色
CREATE ROLE tutorial_readonly;
CREATE ROLE tutorial_readwrite;

-- 2) 建立應用使用者
CREATE ROLE tutorial_app
    LOGIN
    PASSWORD 'tutorial_pass'
    CONNECTION LIMIT 10;

-- 3) 授權 readonly 群組
GRANT CONNECT ON DATABASE bookstore TO tutorial_readonly;
GRANT USAGE ON SCHEMA shop TO tutorial_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA shop TO tutorial_readonly;

-- 4) 授權 readwrite 群組 (繼承 readonly)
GRANT tutorial_readonly TO tutorial_readwrite;
GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA shop TO tutorial_readwrite;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA shop TO tutorial_readwrite;

-- 5) 讓 app 用戶加入 readwrite 群組
GRANT tutorial_readwrite TO tutorial_app;

-- 6) 未來表也自動授予權限
ALTER DEFAULT PRIVILEGES IN SCHEMA shop
    GRANT SELECT ON TABLES TO tutorial_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA shop
    GRANT INSERT, UPDATE, DELETE ON TABLES TO tutorial_readwrite;

-- 7) 查看角色清單
\du

-- 8) 查看 shop schema 權限
\dp shop.books

-- 9) 驗證:以 tutorial_app 身份連線測試
-- (需要 trust/md5 設定或使用 -W 輸入密碼)
-- psql -d bookstore -U tutorial_app -c "SELECT id, title FROM shop.books LIMIT 3;"
-- psql -d bookstore -U tutorial_app -c "DELETE FROM shop.books;" -- 應成功
-- psql -d bookstore -U tutorial_app -c "CREATE TABLE t(id INT);" -- 應失敗

\echo '角色與權限設定完成'

-- 10) 清理
REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA shop FROM tutorial_readwrite, tutorial_readonly;
REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA shop FROM tutorial_readwrite, tutorial_readonly;
REVOKE USAGE ON SCHEMA shop FROM tutorial_readwrite, tutorial_readonly;
REVOKE CONNECT ON DATABASE bookstore FROM tutorial_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA shop REVOKE SELECT ON TABLES FROM tutorial_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA shop REVOKE INSERT, UPDATE, DELETE ON TABLES FROM tutorial_readwrite;
DROP ROLE tutorial_app;
DROP ROLE tutorial_readwrite;
DROP ROLE tutorial_readonly;
\echo '清理完成'
