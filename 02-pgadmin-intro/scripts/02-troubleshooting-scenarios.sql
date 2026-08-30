-- =====================================================================
-- 第 2 章 / 問題排查情境模擬 (對應 README 2.13 節)
-- 用法:psql -d bookstore -f 02-troubleshooting-scenarios.sql
--
-- 本章的情境大多發生在 pgAdmin 的 GUI 裡,這支腳本重現「能用 SQL 重現」的三個:
--   C) 在 Query Tool 貼 psql 指令 (\d、\c) 的真實錯誤訊息,以及 SQL 版的替代品
--   D) Query Tool 關了 autocommit,UPDATE 沒 COMMIT 就去做別的事 → 其他連線卡住
--   E) 對大表 SELECT * 讓結果格「跑不完」
-- A (connection refused)、B (認證失敗)、F (master password) 需要環境故障才能重現,
-- README 只列診斷指令與正常/異常輸出。
--
-- 情境 D 用 contrib 的 dblink 模擬「另一個 pgAdmin 連線」,需要能免密碼連本機
-- (容器與 Homebrew 預設皆可;若你的 pg_hba 要密碼,在下方 conn 字串加 password=...)。
-- 所有 demo 物件以 ts_ 開頭,跑完會清掉;不會動到 shop.* 的資料。
-- =====================================================================
SET search_path TO shop, public;
CREATE EXTENSION IF NOT EXISTS dblink;

-- =====================================================================
\echo ''
\echo '════ 情境 C:在 Query Tool 貼 psql 指令 (\\d、\\c) 卻報 syntax error ════'
-- 症狀:從教學/網路複製 `\d books` 或 `\c bookstore` 貼到 Query Tool,按 F5 就噴錯
-- =====================================================================
\echo '── C 重現:把 \\d / \\c 當成 SQL 送給伺服器 (pgAdmin 就是這樣送的) ──'
DO $$
DECLARE cmd TEXT;
BEGIN
    FOREACH cmd IN ARRAY ARRAY[E'\\d books', E'\\c bookstore', E'\\dt shop.*']
    LOOP
        BEGIN
            EXECUTE cmd;
        EXCEPTION WHEN syntax_error THEN
            RAISE NOTICE '輸入 [%] → SQLSTATE % : %', cmd, SQLSTATE, SQLERRM;
        END;
    END LOOP;
END$$;

-- 根因:\d、\c、\dt 是 psql 這個「客戶端程式」自己解析的指令,不是 SQL;
--       pgAdmin 把整段文字原封不動送給伺服器,伺服器看到反斜線就是語法錯誤。

\echo '── C 修正 1:\\d books 的 SQL 版 (欄位、型別、NULL、預設值) ──'
SELECT column_name, data_type, character_maximum_length AS len,
       is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'shop' AND table_name = 'books'
ORDER BY ordinal_position;

\echo '── C 修正 2:\\dt shop.* 的 SQL 版 (列出 schema 內的表) ──'
SELECT schemaname, tablename, tableowner
FROM pg_tables
WHERE schemaname = 'shop'
ORDER BY tablename;

\echo '── C 修正 3:\\d 看索引與約束的 SQL 版 ──'
SELECT conname, contype, pg_get_constraintdef(oid) AS definition
FROM pg_constraint
WHERE conrelid = 'shop.books'::regclass
ORDER BY contype, conname;

-- \c bookstore 沒有 SQL 版:pgAdmin 的一個 Query Tool 分頁 = 一條固定連到某個 DB 的連線,
-- 要換資料庫就對另一個 DB 節點再開一個 Query Tool。
\echo '── C 驗證:目前這條連線連到哪個 DB、用哪個角色 ──'
SELECT current_database(), current_user, coalesce(inet_server_port()::text, '(unix socket)') AS port;

-- =====================================================================
\echo ''
\echo '════ 情境 D:Query Tool 關了 autocommit,UPDATE 沒 COMMIT → 其他人全卡住 ════'
-- 症狀:同事在 pgAdmin 改了一筆資料就去開會;之後應用程式對同一張表的更新全部逾時
-- =====================================================================
DROP TABLE IF EXISTS ts_books;
CREATE TABLE ts_books AS SELECT id, title, price, stock FROM shop.books;
ALTER TABLE ts_books ADD PRIMARY KEY (id);

\echo '── D 重現:模擬 pgAdmin 連線 (autocommit off) 執行 UPDATE 後就放著 ──'
SELECT dblink_connect('pgadmin',
       'dbname=' || current_database() || ' user=' || current_user ||
       ' application_name=''pgAdmin 4 - CONN:1234''');
SELECT dblink_exec('pgadmin', 'BEGIN');
SELECT dblink_exec('pgadmin', 'UPDATE shop.ts_books SET stock = stock - 1 WHERE id = 1');
-- ...然後那個分頁就被晾在那裡,沒有 COMMIT,也沒有 ROLLBACK

\echo '── D 症狀:應用程式 (這個 session) 更新同一列,等 1 秒就逾時 (錯誤被包在 DO 裡,以 NOTICE 顯示) ──'
SET lock_timeout = '1s';
DO $$
BEGIN
    UPDATE ts_books SET stock = stock - 1 WHERE id = 1;
    RAISE NOTICE '??? 沒有被擋住';
EXCEPTION WHEN lock_not_available THEN
    RAISE NOTICE 'SQLSTATE % : %  ← 應用程式看到的就是這個', SQLSTATE, SQLERRM;
END$$;
RESET lock_timeout;

\echo '── D 排查步驟 1:誰在 idle in transaction?看 application_name 就知道是哪個工具 ──'
SELECT pid, application_name, state,
       date_trunc('second', now() - xact_start) AS xact_age,
       left(query, 50) AS last_query
FROM pg_stat_activity
WHERE datname = current_database()
  AND state = 'idle in transaction';

\echo '── D 排查步驟 2:確認它就是擋住我們的那一個 (pg_blocking_pids) ──'
-- 再開一個等待中的更新 (dblink 非同步送出),然後從本 session 查誰擋誰
SELECT dblink_connect('app', 'dbname=' || current_database() || ' user=' || current_user ||
                              ' application_name=''my-app''');
SELECT dblink_send_query('app', 'UPDATE shop.ts_books SET stock = stock - 1 WHERE id = 1');
SELECT pg_sleep(0.3);
SELECT a.pid AS waiting_pid, a.application_name AS waiting_app, a.wait_event_type,
       pg_blocking_pids(a.pid) AS blocked_by,
       b.application_name AS blocker_app, b.state AS blocker_state
FROM pg_stat_activity a
JOIN pg_stat_activity b ON b.pid = ANY (pg_blocking_pids(a.pid))
WHERE a.application_name = 'my-app';

-- 根因:pgAdmin Query Tool 的 autocommit 關掉後,每一段 SQL 都在同一個交易裡,
--       UPDATE 取得的列鎖會一直握到 COMMIT/ROLLBACK 為止;分頁沒關、人走了,鎖就一直在。

\echo '── D 修正:請對方 COMMIT/ROLLBACK;找不到人就 pg_terminate_backend ──'
SELECT pg_terminate_backend(pid) AS terminated
FROM pg_stat_activity
WHERE application_name = 'pgAdmin 4 - CONN:1234' AND state = 'idle in transaction';

\echo '── D 驗證:被擋住的應用程式更新立刻完成 ──'
SELECT dblink_get_result('app') AS app_result;   -- 取回剛才卡住的 UPDATE 結果
SELECT id, stock FROM ts_books WHERE id = 1;     -- 只少 1:pgAdmin 那筆 (未 commit) 被回滾了
SELECT count(*) AS still_idle_in_txn
FROM pg_stat_activity WHERE state = 'idle in transaction' AND datname = current_database();

SELECT dblink_disconnect('app');
-- pgadmin 連線已被 terminate;若還在就關掉
DO $$
BEGIN
    PERFORM dblink_disconnect('pgadmin');
EXCEPTION WHEN OTHERS THEN NULL;
END$$;

-- =====================================================================
\echo ''
\echo '════ 情境 E:一個 SELECT 在 pgAdmin「跑不完」,結果格一直轉圈 ════'
-- 症狀:對大表按 F5 後畫面卡住幾十秒,甚至 pgAdmin 記憶體暴增
-- =====================================================================
DROP TABLE IF EXISTS ts_events;
CREATE TABLE ts_events AS
SELECT g AS id, now() - (g * INTERVAL '1 second') AS created_at,
       md5(g::text) AS payload
FROM generate_series(1, 200000) g;
ANALYZE ts_events;

\echo '── E 排查步驟 1:先問表有多大 (別直接 SELECT *) ──'
SELECT pg_size_pretty(pg_total_relation_size('ts_events')) AS size,
       (SELECT reltuples::bigint FROM pg_class WHERE relname = 'ts_events') AS est_rows;

\echo '── E 排查步驟 2:EXPLAIN ANALYZE 看伺服器端其實花多久 ──'
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT * FROM ts_events;

-- 根因:伺服器端 Seq Scan 200k 列只要幾十毫秒;慢的是「把 200k 列傳到 pgAdmin、
--       再渲染成表格」— 網路 + 前端渲染 + 瀏覽器記憶體,這段 EXPLAIN 看不到。

\echo '── E 修正:加 LIMIT,或用聚合把「看資料」和「算數字」分開 ──'
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT * FROM ts_events ORDER BY id LIMIT 100;

SELECT count(*) AS total_rows,
       min(created_at) AS oldest, max(created_at) AS newest
FROM ts_events;

-- ---------------------------------------------------------------------
-- 清理
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS ts_events;
DROP TABLE IF EXISTS ts_books;
\echo ''
\echo '✅ 情境模擬完成 (demo 表已清除)'
