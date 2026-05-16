-- =====================================================================
-- 建立與探索資料庫 / Schema
-- 用法 (在 psql 預設 postgres 資料庫執行):
--   psql -d postgres -f 01-create-and-explore.sql
-- =====================================================================

-- 1. 建立一個練習資料庫
DROP DATABASE IF EXISTS demo_ch03;
CREATE DATABASE demo_ch03
    WITH ENCODING = 'UTF8'
         LC_COLLATE = 'en_US.UTF-8'
         LC_CTYPE = 'en_US.UTF-8'
         TEMPLATE = template0
         CONNECTION LIMIT = 50;

COMMENT ON DATABASE demo_ch03 IS '第 3 章示範用資料庫';

\connect demo_ch03

-- 2. 建立多個 schema 模擬模組劃分
CREATE SCHEMA app   AUTHORIZATION CURRENT_USER;
CREATE SCHEMA audit AUTHORIZATION CURRENT_USER;

COMMENT ON SCHEMA app   IS '應用業務表';
COMMENT ON SCHEMA audit IS '稽核紀錄';

-- 3. 在不同 schema 建立同名表 (展示命名空間隔離)
CREATE TABLE app.users (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL
);

CREATE TABLE audit.users (
    id SERIAL PRIMARY KEY,
    user_id INT NOT NULL,
    action  TEXT NOT NULL,
    occurred_at TIMESTAMPTZ DEFAULT NOW()
);

-- 4. 列出當前 db 內所有 schema
SELECT schema_name
FROM information_schema.schemata
WHERE schema_name NOT LIKE 'pg_%'
  AND schema_name <> 'information_schema'
ORDER BY schema_name;

-- 5. 列出指定 schema 下的所有表
SELECT schemaname, tablename
FROM pg_tables
WHERE schemaname IN ('app','audit')
ORDER BY schemaname, tablename;

-- 6. 資料庫與其大小
SELECT datname,
       pg_size_pretty(pg_database_size(datname)) AS size,
       pg_encoding_to_char(encoding) AS encoding
FROM pg_database
WHERE datistemplate = false
ORDER BY pg_database_size(datname) DESC;

-- 7. 清理 - 取消下方註解可以刪除整個資料庫
-- \connect postgres
-- DROP DATABASE demo_ch03;
