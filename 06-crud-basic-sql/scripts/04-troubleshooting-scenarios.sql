-- =====================================================================
-- 第 6 章 / 問題排查情境模擬 (對應 README 6.9 節)
-- 用法:psql -d bookstore -f 04-troubleshooting-scenarios.sql
--
-- 每個情境都用自己的 demo 表 (從 shop.* 複製出來),跑完會清掉,
-- 不會改動 bookstore 的範例資料。
-- 注意:情境 B、C、D 會刻意出現 ERROR,那是情境的一部分,不是腳本壞掉;
--       能包進 DO … EXCEPTION 的都包了,只有 D 的鎖等待逾時是直接呈現。
-- 情境 D 用 dblink 模擬「另一個 session」;若你的環境本機連線需要密碼,
-- 把 conninfo 改成 'dbname=bookstore user=<你的帳號> password=<密碼>'。
-- =====================================================================
SET search_path TO shop, public;

DROP TABLE IF EXISTS crud_books, crud_customers, crud_stage, crud_big;

-- 從範例資料複製一份可以隨便弄壞的表
CREATE TABLE crud_books AS SELECT id, title, price, stock, updated_at FROM books;
CREATE TABLE crud_customers AS SELECT id, name, email, phone FROM customers;
ALTER TABLE crud_books ADD PRIMARY KEY (id);
ALTER TABLE crud_customers ADD PRIMARY KEY (id);

-- =====================================================================
\echo ''
\echo '════ 情境 A:UPDATE 忘了 WHERE,一句話改掉整張表 ════'
-- 症狀:本來只想把 id=1 那本書降價,執行後全店所有書都變成同一個價格
-- =====================================================================

\echo '── A 重現:少了 WHERE 的 UPDATE (先開交易,才有後悔的機會) ──'
BEGIN;
UPDATE crud_books SET price = 99;
-- ↑ 看命令回應:「UPDATE 8」— 預期只改 1 列,卻改了 8 列,這就是第一個線索

\echo '── A 排查步驟 1:交易還沒 COMMIT,先看災情範圍 ──'
SELECT count(*) AS rows_changed FROM crud_books WHERE price = 99;

\echo '── A 排查步驟 2:確認交易仍開著 (xact_start 有值),就還救得回來 ──'
SELECT xact_start IS NOT NULL AS in_transaction, state
FROM pg_stat_activity WHERE pid = pg_backend_pid();

\echo '── A 修正:ROLLBACK,一切回到原狀 ──'
ROLLBACK;
SELECT count(*) AS still_99 FROM crud_books WHERE price = 99;

\echo '── A 正確做法:先用同樣的 WHERE 數一次,再在交易裡 UPDATE ... RETURNING 核對 ──'
SELECT count(*) AS will_affect FROM crud_books WHERE id = 1;
BEGIN;
UPDATE crud_books SET price = 99 WHERE id = 1
RETURNING id, title, price;
-- 回傳列數 = 預期列數 → 才 COMMIT;不對就 ROLLBACK
COMMIT;

\echo '── A-2 反過來的情況:以為改到了,其實是「UPDATE 0」 ──'
-- 資料裡混進了 NULL、尾端空白與大小寫不一致 (匯入資料常見)
UPDATE crud_customers SET phone = NULL WHERE id = 1;
UPDATE crud_customers SET email = 'Mei@Example.com ' WHERE id = 2;

-- 想刪掉「沒有電話的客戶」:= NULL 永遠不成立,DELETE 0
DELETE FROM crud_customers WHERE phone = NULL;
-- 想刪掉 mei@example.com:大小寫與尾端空白讓等號對不上,DELETE 0
DELETE FROM crud_customers WHERE email = 'mei@example.com';

\echo '── A-2 排查:把「條件」拆開,一項一項看資料到底長什麼樣 ──'
SELECT id, email, length(email) AS len, email = 'mei@example.com' AS eq,
       phone, phone IS NULL AS phone_is_null
FROM crud_customers WHERE id IN (1, 2);

\echo '── A-2 修正:NULL 用 IS NULL;字串比對先正規化 (lower + btrim) ──'
DELETE FROM crud_customers WHERE phone IS NULL RETURNING id, name;
DELETE FROM crud_customers WHERE lower(btrim(email)) = 'mei@example.com' RETURNING id, email;

-- =====================================================================
\echo ''
\echo '════ 情境 B:ON CONFLICT 報錯 — no unique or exclusion constraint ════'
-- 症狀:UPSERT 語法明明照文件寫,卻回
--       ERROR: there is no unique or exclusion constraint matching the ON CONFLICT specification
-- =====================================================================

\echo '── B 重現 (預期錯誤,已包在 DO 內) ──'
DO $$
BEGIN
    INSERT INTO crud_customers (id, name, email)
    VALUES (100, 'Alice', 'alice@x.com')
    ON CONFLICT (email) DO UPDATE SET name = EXCLUDED.name;
EXCEPTION WHEN invalid_column_reference THEN
    RAISE NOTICE '❌ SQLSTATE=% : %', SQLSTATE, SQLERRM;
END$$;

\echo '── B 排查步驟 1:這張表的 email 上到底有沒有 UNIQUE? ──'
SELECT conname, contype, pg_get_constraintdef(oid) AS definition
FROM pg_constraint WHERE conrelid = 'crud_customers'::regclass;
SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'crud_customers';

-- 根因:crud_customers 是用 CREATE TABLE ... AS SELECT 從 customers 複製的,
--       CREATE TABLE AS / INSERT ... SELECT 只複製「資料」,不複製 UNIQUE、FK、DEFAULT。
--       ON CONFLICT (email) 需要 email 上有 UNIQUE 約束或唯一索引作為「衝突判定依據」,
--       沒有的話 PostgreSQL 無法知道什麼叫「衝突」。

\echo '── B 修正:補上 UNIQUE (或建唯一索引),UPSERT 立刻可用 ──'
ALTER TABLE crud_customers ADD CONSTRAINT crud_customers_email_key UNIQUE (email);
INSERT INTO crud_customers (id, name, email)
VALUES (100, 'Alice', 'alice@x.com')
ON CONFLICT (email) DO UPDATE SET name = EXCLUDED.name
RETURNING id, name, email;

\echo '── B 驗證:再 UPSERT 一次同 email,應是 UPDATE 而不是報錯或新增 ──'
INSERT INTO crud_customers (id, name, email)
VALUES (101, 'Alice v2', 'alice@x.com')
ON CONFLICT (email) DO UPDATE SET name = EXCLUDED.name
RETURNING id, name, email;   -- id 仍是 100
SELECT count(*) AS alice_rows FROM crud_customers WHERE email = 'alice@x.com';

-- =====================================================================
\echo ''
\echo '════ 情境 C:批次匯入 1000 筆,結果少了 10 筆 / 或整批失敗 ════'
-- 症狀 1:ON CONFLICT DO NOTHING 沒報錯,但 count 對不上
-- 症狀 2:改成 DO UPDATE 後反而整批失敗:
--         ERROR: ON CONFLICT DO UPDATE command cannot affect row a second time
-- =====================================================================
CREATE TABLE crud_stage (name TEXT, email TEXT, phone TEXT);
INSERT INTO crud_stage
SELECT 'user' || g, 'user' || g || '@example.com', '09' || lpad(g::text, 8, '0')
FROM generate_series(1, 1000) g;
-- 來源檔裡有 10 筆重複的 email (同一人出現兩次,第二次的電話較新)
INSERT INTO crud_stage
SELECT 'user' || g || ' (dup)', 'user' || g || '@example.com', '0999999999'
FROM generate_series(1, 10) g;

\echo '── C 症狀 1:DO NOTHING 靜靜地丟掉 10 筆 ──'
SELECT count(*) AS source_rows FROM crud_stage;
INSERT INTO crud_customers (id, name, email, phone)
SELECT 1000 + row_number() OVER (), name, email, phone FROM crud_stage
ON CONFLICT (email) DO NOTHING;
-- ↑ 命令回應「INSERT 0 1000」,來源 1010 筆 → 少了 10 筆,但沒有任何錯誤
SELECT count(*) AS inserted_rows FROM crud_customers WHERE id > 1000;

\echo '── C 排查步驟 1:來源 vs 目的數量對帳 (匯入作業一定要做) ──'
SELECT (SELECT count(*) FROM crud_stage) AS source_rows,
       (SELECT count(*) FROM crud_customers WHERE id > 1000) AS target_rows;

\echo '── C 排查步驟 2:來源本身有沒有重複 key? ──'
SELECT email, count(*) FROM crud_stage GROUP BY email HAVING count(*) > 1 ORDER BY email LIMIT 3;

DELETE FROM crud_customers WHERE id > 1000;   -- 重設,示範症狀 2

\echo '── C 症狀 2:改用 DO UPDATE 想「以後者為準」,整批直接失敗 (預期錯誤) ──'
DO $$
BEGIN
    INSERT INTO crud_customers (id, name, email, phone)
    SELECT 1000 + row_number() OVER (), name, email, phone FROM crud_stage
    ON CONFLICT (email) DO UPDATE SET phone = EXCLUDED.phone;
EXCEPTION WHEN cardinality_violation THEN
    RAISE NOTICE '❌ SQLSTATE=% : %', SQLSTATE, SQLERRM;
END$$;

-- 根因:ON CONFLICT 處理的是「新列 vs 表中既有列」的衝突;
--       同一個 INSERT 裡兩列撞同一個 key,PostgreSQL 拒絕在一個敘述內對同一列改兩次。
--       DO NOTHING 版本則是把第二筆默默丟掉 — 兩種行為都不是你要的「後者為準」。

\echo '── C 修正:先在來源端去重 (DISTINCT ON 指定保留哪一筆),再 UPSERT ──'
INSERT INTO crud_customers (id, name, email, phone)
SELECT 1000 + row_number() OVER (), name, email, phone
FROM (
    SELECT DISTINCT ON (email) name, email, phone
    FROM crud_stage
    ORDER BY email, (name LIKE '%(dup)') DESC     -- 後來的那筆排前面 → 被保留
) dedup
ON CONFLICT (email) DO UPDATE SET phone = EXCLUDED.phone;

\echo '── C 驗證:1000 個不同 email 全進了,重複者保留較新的電話 ──'
SELECT count(*) AS target_rows, count(DISTINCT email) AS distinct_emails
FROM crud_customers WHERE id > 1000;
SELECT name, phone FROM crud_customers WHERE email = 'user3@example.com';

-- =====================================================================
\echo ''
\echo '════ 情境 D:一個「跑很久的 UPDATE」讓整個系統的寫入都卡住 ════'
-- 症狀:後台批次在改 20 萬列,前台所有對同一張表的 UPDATE 都停在那裡不動,
--       應用程式 timeout,但資料庫 CPU 很閒
-- =====================================================================
CREATE TABLE crud_big AS
SELECT g AS id, 'pending' AS status, now() AS updated_at
FROM generate_series(1, 200000) g;
ALTER TABLE crud_big ADD PRIMARY KEY (id);

-- 用 dblink 模擬「另一個 session」(後台批次),它開了交易、改了全部列、還沒 COMMIT
CREATE EXTENSION IF NOT EXISTS dblink;
SELECT dblink_connect('batch', 'dbname=' || current_database());
SELECT dblink_exec('batch', 'BEGIN');
SELECT dblink_exec('batch', 'UPDATE shop.crud_big SET status = ''done''') AS batch_result;

\echo '── D 重現:前台只想改 1 列,卻等到逾時 (預期錯誤:lock timeout) ──'
SET lock_timeout = '2s';
UPDATE crud_big SET status = 'cancelled' WHERE id = 42;
RESET lock_timeout;

\echo '── D 排查步驟 1:誰在等、在等誰?(pg_stat_activity + pg_blocking_pids) ──'
-- 再開一次同樣的更新讓它在背景等著,好觀察 (用 dblink_send_query 非同步送出)
SELECT dblink_connect('frontend', 'dbname=' || current_database());
SELECT dblink_send_query('frontend', 'UPDATE shop.crud_big SET status = ''cancelled'' WHERE id = 42');
SELECT pg_sleep(0.5);
SELECT pid, state, wait_event_type, wait_event,
       pg_blocking_pids(pid) AS blocked_by,
       left(query, 60) AS query
FROM pg_stat_activity
WHERE datname = current_database()
  AND (wait_event_type = 'Lock' OR state = 'idle in transaction')
ORDER BY pid;

\echo '── D 排查步驟 2:擋人的那個 session 已經閒置多久?(idle in transaction 是警訊) ──'
SELECT pid, state, now() - xact_start AS xact_age, left(query, 60) AS last_query
FROM pg_stat_activity
WHERE datname = current_database() AND state = 'idle in transaction';

-- 根因:UPDATE 對每一列取得 row lock,直到交易 COMMIT/ROLLBACK 才釋放;
--       一次改 20 萬列 = 20 萬個 row lock 一直握著,任何要碰這些列的人都得排隊。
--       批次程式「開了交易做別的事 (idle in transaction)」會讓情況更糟。

\echo '── D 修正 (當下止血):讓批次 COMMIT 或直接終止它 ──'
SELECT dblink_exec('batch', 'ROLLBACK');       -- 這裡示範 ROLLBACK;正式環境視情況 COMMIT 或 pg_terminate_backend(pid)
SELECT dblink_get_result('frontend') AS frontend_result;   -- 前台的 UPDATE 立刻完成
SELECT dblink_disconnect('frontend');

\echo '── D 修正 (長期):批次改成小批量、各自 COMMIT,鎖只握幾毫秒 ──'
-- 每批一個短交易;psql 預設 autocommit,下面每句就是一個交易
UPDATE crud_big SET status = 'done' WHERE id BETWEEN 1      AND 50000;
UPDATE crud_big SET status = 'done' WHERE id BETWEEN 50001  AND 100000;
UPDATE crud_big SET status = 'done' WHERE id BETWEEN 100001 AND 150000;
UPDATE crud_big SET status = 'done' WHERE id BETWEEN 150001 AND 200000;

\echo '── D 驗證:批次進行中前台不再被擋 (這次沒有 lock timeout) ──'
SELECT dblink_exec('batch', 'BEGIN');
SELECT dblink_exec('batch', 'UPDATE shop.crud_big SET status = ''archived'' WHERE id BETWEEN 1 AND 50000');
SET lock_timeout = '2s';
UPDATE crud_big SET status = 'cancelled' WHERE id = 150042 RETURNING id, status;
RESET lock_timeout;
SELECT dblink_exec('batch', 'COMMIT');
SELECT dblink_disconnect('batch');

-- ---------------------------------------------------------------------
-- 清理
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS crud_books, crud_customers, crud_stage, crud_big;
\echo ''
\echo '✅ 情境模擬完成 (demo 表已清除,bookstore 範例資料未變動)'
