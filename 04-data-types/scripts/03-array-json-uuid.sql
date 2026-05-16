-- =====================================================================
-- 第 4 章 / 陣列、JSON、UUID、Enum
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============== 陣列 ==============
DROP TABLE IF EXISTS arr_demo;
CREATE TABLE arr_demo (
    id   SERIAL PRIMARY KEY,
    name TEXT,
    tags TEXT[]
);
INSERT INTO arr_demo (name, tags) VALUES
    ('PostgreSQL', ARRAY['db','open-source','rdbms']),
    ('Rust',       '{"lang","systems","memory-safe"}'),
    ('Vue',        ARRAY['frontend','spa']);

-- 包含特定值
SELECT name FROM arr_demo WHERE 'db' = ANY(tags);

-- 陣列包含關係
SELECT name FROM arr_demo WHERE tags @> ARRAY['lang'];

-- 陣列重疊
SELECT name FROM arr_demo WHERE tags && ARRAY['spa','db'];  -- 至少一個元素相同

-- 展開 unnest
SELECT name, unnest(tags) AS tag FROM arr_demo;

-- 聚合成陣列
SELECT array_agg(name ORDER BY id) FROM arr_demo;

-- ============== JSONB ==============
DROP TABLE IF EXISTS json_demo;
CREATE TABLE json_demo (
    id   SERIAL PRIMARY KEY,
    info JSONB
);
INSERT INTO json_demo (info) VALUES
    ('{"name":"Alice","age":30,"roles":["admin","editor"],"addr":{"city":"Taipei"}}'),
    ('{"name":"Bob","age":25,"roles":["user"],"addr":{"city":"Tokyo"}}');

-- 取值
SELECT
    info->>'name'           AS name,
    (info->>'age')::INT     AS age,
    info->'roles'           AS roles_json,
    info#>>'{addr,city}'    AS city,
    info ? 'age'            AS has_age,
    info @> '{"age":30}'    AS is_age_30
FROM json_demo;

-- 修改 (jsonb_set)
UPDATE json_demo
SET info = jsonb_set(info, '{age}', '31')
WHERE info->>'name' = 'Alice';

-- 新增欄位
UPDATE json_demo
SET info = info || '{"vip":true}'::jsonb
WHERE info->>'name' = 'Alice';

-- 刪除 key
UPDATE json_demo SET info = info - 'vip' WHERE info->>'name' = 'Alice';

SELECT * FROM json_demo;

-- ============== UUID ==============
DROP TABLE IF EXISTS uuid_demo;
CREATE TABLE uuid_demo (
    id   UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    note TEXT
);
INSERT INTO uuid_demo (note) VALUES ('a'), ('b'), ('c');
SELECT * FROM uuid_demo;

-- ============== ENUM ==============
DROP TYPE IF EXISTS priority CASCADE;
CREATE TYPE priority AS ENUM ('low', 'medium', 'high', 'critical');

DROP TABLE IF EXISTS task_demo;
CREATE TABLE task_demo (
    id    SERIAL PRIMARY KEY,
    title TEXT,
    prio  priority NOT NULL
);
INSERT INTO task_demo (title, prio) VALUES
    ('Fix login bug',     'high'),
    ('Refactor billing',  'medium'),
    ('Update README',     'low'),
    ('Production outage', 'critical');

-- ENUM 可比較大小,順序依宣告
SELECT * FROM task_demo WHERE prio >= 'high' ORDER BY prio DESC;

-- 清理
DROP TABLE arr_demo, json_demo, uuid_demo, task_demo;
DROP TYPE priority;
