-- =====================================================================
-- 第 4 章 / 問題排查情境模擬 (對應 README 4.15 節)
-- 用法:psql -d bookstore -f 04-troubleshooting-scenarios.sql
--
-- 每個情境都用自己的 demo 表 (落在 public schema),跑完會清掉。
-- 建議搭配 README 4.15 的「排查順序」逐段執行、對照輸出。
-- 情境中「預期的錯誤」都包在 DO … EXCEPTION 裡,腳本本身不會中斷。
-- =====================================================================
SET search_path TO public;

-- =====================================================================
\echo ''
\echo '════ 情境 A:月結報表金額跟財務系統對不上,差了幾分錢 ════'
-- 症狀:每筆訂單金額看起來都正確,但 SUM 起來的總額跟財務系統差 0.0x 元
-- =====================================================================
DROP TABLE IF EXISTS ledger_float, ledger_numeric;
CREATE TABLE ledger_float   (id SERIAL PRIMARY KEY, amount DOUBLE PRECISION);
CREATE TABLE ledger_numeric (id SERIAL PRIMARY KEY, amount NUMERIC(12,2));

-- 20 萬筆「看起來很正常」的金額:0.10、19.99、3.30 循環
INSERT INTO ledger_float (amount)
SELECT (ARRAY[0.10, 19.99, 3.30])[1 + (g % 3)] FROM generate_series(1, 200000) g;
INSERT INTO ledger_numeric (amount)
SELECT (ARRAY[0.10, 19.99, 3.30])[1 + (g % 3)] FROM generate_series(1, 200000) g;

\echo '── A 排查步驟 1:先確認欄位型別 (float 就是嫌疑犯) ──'
SELECT table_name, column_name, data_type, numeric_precision, numeric_scale
FROM information_schema.columns
WHERE table_name IN ('ledger_float', 'ledger_numeric') AND column_name = 'amount'
ORDER BY table_name;

\echo '── A 排查步驟 2:同樣的資料,兩種型別 SUM 的結果 ──'
SELECT
    (SELECT sum(amount) FROM ledger_float)   AS float_sum,
    (SELECT sum(amount) FROM ledger_numeric) AS numeric_sum,
    (SELECT sum(amount) FROM ledger_float) - (SELECT sum(amount) FROM ledger_numeric)::float8 AS diff;

\echo '── A 排查步驟 3:最小重現 — 0.1 + 0.2 ──'
SELECT 0.1::float8 + 0.2::float8 AS float_result,
       0.1::numeric + 0.2::numeric AS numeric_result,
       (0.1::float8 + 0.2::float8) = 0.3 AS float_equals_0_3;

-- 根因:DOUBLE PRECISION 是二進位浮點數,0.1 / 19.99 這類十進位小數無法精確表示,
--       每筆都帶著極小的誤差,20 萬筆累加後就變成看得見的差額。

\echo '── A 修正:欄位改成 NUMERIC;既有的 float 值要先 ROUND 到正確位數 ──'
ALTER TABLE ledger_float
    ALTER COLUMN amount TYPE NUMERIC(12,2) USING ROUND(amount::numeric, 2);

\echo '── A 驗證:改型後兩邊總額一致 ──'
SELECT
    (SELECT sum(amount) FROM ledger_float)   AS fixed_sum,
    (SELECT sum(amount) FROM ledger_numeric) AS numeric_sum,
    (SELECT sum(amount) FROM ledger_float) = (SELECT sum(amount) FROM ledger_numeric) AS equal;

-- =====================================================================
\echo ''
\echo '════ 情境 B:伺服器搬到 UTC 之後,所有訂單時間都「提早了 8 小時」 ════'
-- 症狀:原本在台北機房的 App 搬到雲端 (UTC),舊資料的時間顯示全錯,新舊資料混在一起無法比較
-- =====================================================================
DROP TABLE IF EXISTS orders_ts;
CREATE TABLE orders_ts (
    id           SERIAL PRIMARY KEY,
    ordered_at   TIMESTAMP,      -- 沒有時區 (問題所在)
    ordered_tz   TIMESTAMPTZ     -- 有時區 (對照組)
);

-- 舊機房:session 時區是台北,App 寫入「本地時間」
SET timezone = 'Asia/Taipei';
INSERT INTO orders_ts (ordered_at, ordered_tz)
VALUES ('2026-03-01 09:30:00', '2026-03-01 09:30:00');

\echo '── B 在台北時區讀:兩欄看起來一樣,問題被掩蓋 ──'
SELECT id, ordered_at, ordered_tz FROM orders_ts;

-- 搬家:新環境 session 時區是 UTC
SET timezone = 'UTC';
\echo '── B 排查步驟 1:換到 UTC 讀同一列 — TIMESTAMP 數字沒變 (它不知道自己是哪個時區),TIMESTAMPTZ 正確換算成 01:30 UTC ──'
SELECT id, ordered_at, ordered_tz FROM orders_ts;

\echo '── B 排查步驟 2:確認欄位型別與目前 session 時區 ──'
SELECT column_name, data_type FROM information_schema.columns
WHERE table_name = 'orders_ts' AND column_name LIKE 'ordered%' ORDER BY column_name;
SHOW timezone;

\echo '── B 排查步驟 3:「同一個瞬間」比較 — TIMESTAMP 被當成 UTC 09:30,實際上是台北 09:30 (UTC 01:30),差 8 小時 ──'
SELECT ordered_at::timestamptz AS timestamp_assumed_utc,
       ordered_tz              AS real_instant,
       ordered_at::timestamptz - ordered_tz AS drift
FROM orders_ts;

-- 根因:TIMESTAMP (無時區) 只存「牆上的數字」,不記錄那是哪裡的時間;
--       寫入時靠 session 時區隱含約定,一旦環境時區改變,約定就破了。

\echo '── B 修正:改成 TIMESTAMPTZ,並用 AT TIME ZONE 告訴 PostgreSQL 舊數字是台北時間 ──'
ALTER TABLE orders_ts
    ALTER COLUMN ordered_at TYPE TIMESTAMPTZ
    USING ordered_at AT TIME ZONE 'Asia/Taipei';

\echo '── B 驗證:UTC 下兩欄一致;切回台北也一致 ──'
SELECT id, ordered_at, ordered_tz, ordered_at = ordered_tz AS same_instant FROM orders_ts;
SET timezone = 'Asia/Taipei';
SELECT id, ordered_at, ordered_tz FROM orders_ts;
RESET timezone;

-- =====================================================================
\echo ''
\echo '════ 情境 C:同一個查詢有時報錯、有時慢 — 型別不符與隱含轉型 ════'
-- 症狀:customer_code 有索引,App 查詢卻走 Seq Scan;另一個版本的 App 直接報 operator does not exist
-- =====================================================================
DROP TABLE IF EXISTS customers_code;
CREATE TABLE customers_code (
    id            SERIAL PRIMARY KEY,
    customer_code TEXT NOT NULL,   -- 存的是數字字串 '000042',但型別是 TEXT
    name          TEXT
);
INSERT INTO customers_code (customer_code, name)
SELECT lpad(g::text, 6, '0'), 'customer ' || g FROM generate_series(1, 100000) g;
CREATE INDEX idx_customers_code ON customers_code (customer_code);
ANALYZE customers_code;

\echo '── C-1 排查步驟 1:App 用整數參數查 → 直接報錯 (SQLSTATE 42883,預期的錯誤) ──'
DO $$
BEGIN
    PERFORM * FROM customers_code WHERE customer_code = 42;
EXCEPTION WHEN undefined_function THEN
    RAISE NOTICE '❌ 預期錯誤 [%]: %', SQLSTATE, SQLERRM;
END$$;

\echo '── C-2 排查步驟 2:另一版 App「修好了」— 把欄位轉成整數再比:不報錯,但 Seq Scan ──'
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM customers_code WHERE customer_code::int = 42;

\echo '── C 排查步驟 3:確認欄位型別 vs 參數型別 ──'
SELECT column_name, data_type FROM information_schema.columns
WHERE table_name = 'customers_code' AND column_name = 'customer_code';

-- 根因:欄位是 TEXT,參數是 INTEGER。PostgreSQL 不會偷偷把 text 轉成 int (C-1 報錯);
--       把「欄位」轉型去遷就參數 (C-2) 等於對欄位套函數,索引存的是原值,用不上。
--       正確做法永遠是「把參數轉成欄位的型別」。

\echo '── C 修正:參數改成欄位的型別 (TEXT),並符合儲存格式 ──'
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM customers_code WHERE customer_code = lpad('42', 6, '0');

\echo '── C 驗證:計畫變 Index Scan;順便檢查資料是否真的都是數字,才考慮長期改型別 ──'
SELECT count(*) AS non_numeric_codes FROM customers_code WHERE customer_code !~ '^[0-9]+$';

-- =====================================================================
\echo ''
\echo '════ 情境 D:上線後偶發 value too long / 想刪掉 ENUM 的值卻刪不掉 ════'
-- 症狀 D-1:註冊功能偶爾失敗,錯誤 value too long for type character varying(30)
-- 症狀 D-2:產品下架某個狀態,ALTER TYPE ... DROP VALUE 不存在
-- =====================================================================
DROP TABLE IF EXISTS members;
CREATE TABLE members (
    id    SERIAL PRIMARY KEY,
    name  VARCHAR(30) NOT NULL,
    email TEXT
);
INSERT INTO members (name, email) VALUES ('王小明', 'ming@example.com');

\echo '── D-1 重現:一位名字很長的使用者註冊 (預期錯誤 SQLSTATE 22001) ──'
DO $$
BEGIN
    INSERT INTO members (name, email)
    VALUES ('Maria de los Ángeles Fernández-Rodríguez', 'maria@example.com');
EXCEPTION WHEN string_data_right_truncation THEN
    RAISE NOTICE '❌ 預期錯誤 [%]: %', SQLSTATE, SQLERRM;
END$$;

\echo '── D-1 排查步驟 1:看錯誤碼 22001 → 找出哪個欄位有長度限制 ──'
SELECT column_name, data_type, character_maximum_length
FROM information_schema.columns
WHERE table_name = 'members' AND character_maximum_length IS NOT NULL;

\echo '── D-1 排查步驟 2:那個 30 是業務規則還是隨手寫的?看既有資料的實際長度分布 ──'
SELECT max(length(name)) AS max_len, avg(length(name))::numeric(5,1) AS avg_len FROM members;

-- 根因:VARCHAR(30) 不是效能設定,是一條「超過就拒絕」的約束。
--       沒有業務上限的欄位 (人名、地址、備註) 用 VARCHAR(n) 只是埋雷。

\echo '── D-1 修正:沒有業務上限就改 TEXT (或放大 n)。放大 VARCHAR / 改 TEXT 不會重寫表,瞬間完成 ──'
ALTER TABLE members ALTER COLUMN name TYPE TEXT;

\echo '── D-1 驗證:同一筆資料再插一次成功 ──'
INSERT INTO members (name, email)
VALUES ('Maria de los Ángeles Fernández-Rodríguez', 'maria@example.com')
RETURNING id, length(name) AS name_len;

\echo '── D-2 重現:ENUM 想刪掉一個值 (預期錯誤 SQLSTATE 0A000:not implemented) ──'
DROP TYPE IF EXISTS ticket_status CASCADE;
CREATE TYPE ticket_status AS ENUM ('open', 'wip', 'closed', 'legacy');
DROP TABLE IF EXISTS tickets;
CREATE TABLE tickets (id SERIAL PRIMARY KEY, status ticket_status NOT NULL);
INSERT INTO tickets (status) VALUES ('open'), ('closed'), ('legacy');

DO $$
BEGIN
    EXECUTE 'ALTER TYPE ticket_status DROP VALUE ''legacy''';
EXCEPTION WHEN feature_not_supported THEN
    RAISE NOTICE '❌ 預期錯誤 [%]: %', SQLSTATE, SQLERRM;
END$$;

\echo '── D-2 排查步驟 1:確認 ENUM 目前有哪些值、被哪些表用到、還有沒有資料在用 ──'
SELECT enumlabel, enumsortorder FROM pg_enum
WHERE enumtypid = 'ticket_status'::regtype ORDER BY enumsortorder;
SELECT table_name, column_name FROM information_schema.columns WHERE udt_name = 'ticket_status';
SELECT status, count(*) FROM tickets GROUP BY status ORDER BY status;

-- 根因:ENUM 的值是型別定義的一部分,PostgreSQL 只提供 ADD VALUE / RENAME VALUE,
--       沒有 DROP VALUE (要保證沒有任何列、索引、預設值還在用它,成本太高)。

\echo '── D-2 修正 (務實作法):先把資料遷移掉,再把值改名標記為棄用;真要移除得重建型別 ──'
UPDATE tickets SET status = 'closed' WHERE status = 'legacy';
ALTER TYPE ticket_status RENAME VALUE 'legacy' TO '_deprecated_legacy';

\echo '── D-2 驗證:沒有列再用舊值;值仍存在但已標記 ──'
SELECT enumlabel FROM pg_enum WHERE enumtypid = 'ticket_status'::regtype ORDER BY enumsortorder;
SELECT status, count(*) FROM tickets GROUP BY status ORDER BY status;

-- ---------------------------------------------------------------------
-- 清理
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS ledger_float, ledger_numeric, orders_ts, customers_code, members, tickets;
DROP TYPE IF EXISTS ticket_status;
\echo ''
\echo '✅ 情境模擬完成 (demo 表已清除)'
