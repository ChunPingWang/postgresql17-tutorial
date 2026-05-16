-- =====================================================================
-- 第 4 章 / 數值與字串
-- psql -d bookstore -f 01-numeric-string.sql
-- =====================================================================

-- 〔1〕浮點誤差展示 (為何金額要用 NUMERIC)
SELECT
    0.1::REAL + 0.2::REAL                AS real_sum,        -- 0.30000001...
    0.1::DOUBLE PRECISION + 0.2          AS double_sum,      -- 0.300000000...
    0.1::NUMERIC + 0.2                   AS numeric_sum;     -- 0.3 (精確)

-- 〔2〕NUMERIC(p, s) 精度與範圍
DROP TABLE IF EXISTS num_demo;
CREATE TABLE num_demo (
    n NUMERIC(5, 2)   -- 共 5 位數,小數 2 位 → 最大 999.99
);
INSERT INTO num_demo VALUES (999.99);     -- OK
-- INSERT INTO num_demo VALUES (1000.00); -- 會錯:numeric field overflow

-- 〔3〕SERIAL vs IDENTITY 比較
DROP TABLE IF EXISTS serial_demo;
DROP TABLE IF EXISTS identity_demo;

CREATE TABLE serial_demo   (id SERIAL PRIMARY KEY, name TEXT);
CREATE TABLE identity_demo (id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY, name TEXT);

INSERT INTO serial_demo   (name) VALUES ('a'), ('b');
INSERT INTO identity_demo (name) VALUES ('a'), ('b');

-- 嘗試手動指定 IDENTITY 的 id 會失敗:
-- INSERT INTO identity_demo (id, name) VALUES (99, 'c');   -- ERROR
-- 想覆蓋必須:
INSERT INTO identity_demo (id, name) OVERRIDING SYSTEM VALUE VALUES (99, 'c');
SELECT * FROM identity_demo;

-- 〔4〕字串長度:字元 vs 位元組
SELECT
    length('PostgreSQL 你好')        AS chars,    -- 14
    octet_length('PostgreSQL 你好')  AS bytes;   -- 17 (UTF-8 下中文每字 3 bytes)

-- 〔5〕常用字串函數
SELECT
    UPPER('hello'),                       -- HELLO
    LOWER('HELLO'),                       -- hello
    INITCAP('hello world'),               -- Hello World
    LENGTH('hello'),                      -- 5
    POSITION('LL' IN 'hello'),            -- 0 (大小寫敏感)
    SUBSTRING('hello world' FROM 7),      -- world
    SUBSTRING('hello world' FROM 1 FOR 5),-- hello
    REPLACE('hello world', 'world', 'PG'),-- hello PG
    TRIM('  spaces  '),                   -- 'spaces'
    LPAD('7', 3, '0'),                    -- '007'
    'a' || 'b' || 'c'                     -- 'abc'  (|| 是字串串接)
;

-- 〔6〕正規表達式
SELECT 'order-12345' ~ '^order-\d+$';       -- t  (匹配)
SELECT REGEXP_REPLACE('abc123def', '\d+', '###');  -- abc###def
SELECT REGEXP_MATCH('mailto:user@example.com', '([^@]+)@(.+)');  -- {user, example.com}

-- 清理
DROP TABLE num_demo;
DROP TABLE serial_demo;
DROP TABLE identity_demo;
