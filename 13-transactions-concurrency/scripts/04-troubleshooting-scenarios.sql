-- =====================================================================
-- 第 13 章 / 問題排查情境模擬 (對應 README 13.11 節)
-- 用法:psql -d bookstore -f 04-troubleshooting-scenarios.sql
--
-- 並發問題需要「第二個 session」才能重現。本腳本用 contrib 的 dblink
-- 在同一支腳本裡開出 s1 / s2 兩條額外連線,模擬兩個並發的應用程式,
-- 所以不必開兩個終端機就能重現卡住、死鎖、lost update、重複處理。
--
-- 前提:
--   1. dblink 是 PostgreSQL contrib,官方 Docker image 與 Homebrew 都有,
--      下面會自動 CREATE EXTENSION (需要超級使用者或 CREATE 權限)。
--   2. 連線字串 'dbname=bookstore user=postgres' 走本機 socket、免密碼
--      (Docker image 的 pg_hba 對 local 是 trust)。Homebrew 使用者請把
--      user= 改成自己的帳號 (例如 user=rexwang),也是免密碼。
--      若你的環境要密碼,加上 password=...,或把 pg_hba 的 local 改為 trust。
--
-- 每個情境都用自己的 demo 表 (public.demo_*),不碰 shop.*,跑完會清掉。
-- 注意:情境 A-2 與 B 會刻意讓某條連線被終止/死鎖,但錯誤都被 DO 區塊接住
--       並印成 NOTICE,整支腳本預期 0 個 ERROR。
-- =====================================================================
\set ON_ERROR_STOP off
-- demo 表都建在 public;把 shop 也放進 search_path 是因為 dblink 這類 extension
-- 會裝在「建立當下 search_path 的第一個 schema」— 若你先跑過其他章節,它可能已經在 shop 裡
SET search_path TO public, shop;

CREATE EXTENSION IF NOT EXISTS dblink;

-- 讓變數化的連線字串只寫一次
\set conn 'dbname=bookstore user=postgres'

-- ---------------------------------------------------------------------
-- 共用:demo 表、helper
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS public.demo_job_log;
DROP TABLE IF EXISTS public.demo_jobs;
DROP TABLE IF EXISTS public.demo_books;

CREATE TABLE public.demo_books (
    id    INT PRIMARY KEY,
    title TEXT NOT NULL,
    stock INT  NOT NULL CHECK (stock >= 0)
);
INSERT INTO public.demo_books VALUES (1, 'Sapiens', 10), (2, 'Cosmos', 10);

-- 等 async 查詢跑完並收結果;遠端若出錯,錯誤會以同樣的 SQLSTATE 在這裡拋出
CREATE OR REPLACE FUNCTION public.demo_collect(conn TEXT) RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE r TEXT;
BEGIN
    WHILE dblink_is_busy(conn) = 1 LOOP PERFORM pg_sleep(0.05); END LOOP;
    BEGIN
        SELECT status INTO r FROM dblink_get_result(conn) AS t(status TEXT);
    EXCEPTION WHEN OTHERS THEN
        -- 遠端出錯時連線上還殘留著結尾的結果,不清掉的話這條連線之後每一句都會報
        -- "another command is already in progress" — 先清乾淨再把錯誤往上丟
        PERFORM * FROM dblink_get_result(conn) AS t(status TEXT);
        RAISE;
    END;
    PERFORM * FROM dblink_get_result(conn) AS t(status TEXT);   -- 清掉結尾的空結果
    RETURN r;
END $$;

-- 若上次執行中斷,把殘留的具名連線關掉 (每次 psql 都是新 session,通常不會有)
DO $$
DECLARE c TEXT;
BEGIN
    FOREACH c IN ARRAY COALESCE(dblink_get_connections(), '{}') LOOP
        PERFORM dblink_disconnect(c);
    END LOOP;
END $$;

SELECT dblink_connect('s1', :'conn');
SELECT dblink_connect('s2', :'conn');

-- 查「誰卡住誰」的標準查詢 (排查時第一個跑的東西)
CREATE OR REPLACE VIEW public.demo_lock_monitor AS
SELECT pid,
       state,
       wait_event_type,
       wait_event,
       pg_blocking_pids(pid)                       AS blocked_by,
       date_trunc('second', now() - xact_start)    AS xact_age,
       left(query, 45)                             AS query
FROM pg_stat_activity
WHERE datname = current_database()
  AND backend_type = 'client backend'
  AND pid <> pg_backend_pid()
ORDER BY pid;

-- =====================================================================
\echo ''
\echo '════ 情境 A:查詢卡住不動 (被 idle in transaction 的連線擋住) ════'
-- 症狀:應用程式的 UPDATE 沒報錯、也沒回來,CPU 卻很閒
-- =====================================================================

-- Session 1:某個 ORM 開了交易、改了一列,然後「忘了 COMMIT」(等使用者操作、或程式卡在別處)
SELECT dblink_exec('s1', 'BEGIN');
SELECT dblink_exec('s1', 'UPDATE public.demo_books SET stock = stock - 1 WHERE id = 1');

-- Session 2:另一個請求要改同一列 → 卡住 (async 送出,主 session 才能繼續觀察)
SELECT dblink_send_query('s2', 'UPDATE public.demo_books SET stock = stock - 1 WHERE id = 1');
SELECT pg_sleep(0.5);

\echo '── A 排查步驟 1:看誰在等、等什麼、被誰擋 (pg_stat_activity + pg_blocking_pids) ──'
SELECT * FROM public.demo_lock_monitor;

\echo '── A 排查步驟 2:擋人的那條連線在做什麼?(state = idle in transaction,query 是它最後一句) ──'
SELECT pid, state, date_trunc('second', now() - state_change) AS idle_for, left(query, 60) AS last_query
FROM pg_stat_activity
WHERE pid = ANY (
    SELECT unnest(pg_blocking_pids(pid)) FROM pg_stat_activity WHERE wait_event_type = 'Lock'
);

\echo '── A 排查步驟 3:鎖的細節 — 等的是 transactionid (等對方交易結束),不是表鎖 ──'
SELECT l.pid, l.locktype, l.mode, l.granted
FROM pg_locks l JOIN pg_stat_activity a ON a.pid = l.pid
WHERE a.wait_event_type = 'Lock' AND l.granted = false;

-- 根因:Session 1 的交易還開著,它改過的列被鎖到 COMMIT/ROLLBACK 為止;
--       Session 2 要改同一列,只能等。「idle in transaction」= 交易開著但沒在做事,最典型的元兇。

\echo '── A 修正 (緊急):結束擋人的交易 — 這裡用 ROLLBACK;生產環境沒辦法碰那條連線時用 pg_terminate_backend(pid) ──'
SELECT dblink_exec('s1', 'ROLLBACK');
SELECT public.demo_collect('s2') AS session2_result;   -- 立刻通了

\echo '── A 驗證:沒有人在等鎖了 ──'
SELECT count(*) AS waiting FROM pg_stat_activity WHERE wait_event_type = 'Lock';

\echo ''
\echo '── A-2 修正 (治本):idle_in_transaction_session_timeout 自動砍掉忘記 COMMIT 的交易 ──'
SELECT dblink_exec('s1', $$SET idle_in_transaction_session_timeout = '500ms'$$);
SELECT dblink_exec('s1', 'BEGIN');
SELECT dblink_exec('s1', 'UPDATE public.demo_books SET stock = stock - 1 WHERE id = 1');
SELECT dblink_send_query('s2', 'UPDATE public.demo_books SET stock = stock - 1 WHERE id = 1');
SELECT pg_sleep(1);   -- 超過 500ms 沒動作,Session 1 被伺服器終止

DO $$
BEGIN
    PERFORM dblink_exec('s1', 'SELECT 1');   -- 連線已被終止,這裡會拋錯 (預期)
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '✅ Session 1 已被伺服器終止:%', split_part(SQLERRM, E'\n', 1);
END $$;
SELECT public.demo_collect('s2') AS session2_result;   -- Session 2 不再被擋

SELECT stock AS stock_after_A FROM public.demo_books WHERE id = 1;   -- 10 - 1 (A) - 1 (A-2) = 8

-- 重新建立 Session 1 給後面的情境用
SELECT dblink_disconnect('s1');
SELECT dblink_connect('s1', :'conn');

-- =====================================================================
\echo ''
\echo '════ 情境 B:deadlock detected ════'
-- 症狀:兩個批次同時跑,其中一個隨機失敗,錯誤訊息是 "deadlock detected"
-- =====================================================================
UPDATE public.demo_books SET stock = 10;

\echo '── B 重現:兩個交易以相反順序鎖同兩列 (s1: 1→2,s2: 2→1) ──'
SELECT dblink_exec('s1', 'BEGIN');
SELECT dblink_exec('s2', 'BEGIN');
SELECT dblink_exec('s1', 'UPDATE public.demo_books SET stock = stock - 1 WHERE id = 1');
SELECT dblink_exec('s2', 'UPDATE public.demo_books SET stock = stock - 1 WHERE id = 2');

DO $$
DECLARE detail TEXT;
BEGIN
    -- s1 要 id=2 → 等 s2
    PERFORM dblink_send_query('s1', 'UPDATE public.demo_books SET stock = stock - 1 WHERE id = 2');
    PERFORM pg_sleep(0.3);
    -- s2 要 id=1 → 等 s1 → 互相等待;deadlock_timeout (預設 1s) 後偵測到,其中一方被中止
    BEGIN
        PERFORM dblink_exec('s2', 'UPDATE public.demo_books SET stock = stock - 1 WHERE id = 1');
        RAISE NOTICE 'Session 2 的 UPDATE 成功 (它是活下來的那個)';
    EXCEPTION WHEN deadlock_detected THEN
        GET STACKED DIAGNOSTICS detail = PG_EXCEPTION_DETAIL;
        RAISE NOTICE '❌ Session 2 被中止:% | DETAIL: %', SQLERRM, detail;
    END;
    BEGIN
        RAISE NOTICE 'Session 1 的結果:%', public.demo_collect('s1');
    EXCEPTION WHEN deadlock_detected THEN
        GET STACKED DIAGNOSTICS detail = PG_EXCEPTION_DETAIL;
        RAISE NOTICE '❌ Session 1 被中止:% | DETAIL: %', SQLERRM, detail;
    END;
END $$;

\echo '── B 排查步驟 1:讀 DETAIL — 它直接告訴你「誰等誰、各自卡在哪一句」(也會寫進伺服器 log) ──'
\echo '── B 排查步驟 2:對照兩邊程式碼的加鎖順序;log_lock_waits = on 可以事先看到等超過 deadlock_timeout 的鎖 ──'
SELECT dblink_exec('s1', 'ROLLBACK');
SELECT dblink_exec('s2', 'ROLLBACK');

-- 根因:s1 先鎖 1 再要 2,s2 先鎖 2 再要 1 — 只要兩邊順序相反就有機會互相等待。
--       PostgreSQL 會自動偵測並中止其中一方 (另一方繼續),但被中止的那方資料沒寫進去,必須重試。

\echo '── B 修正:所有交易依同一順序 (id 由小到大) 加鎖 → 只會排隊,不會互鎖 ──'
UPDATE public.demo_books SET stock = 10;
DO $$
BEGIN
    PERFORM dblink_exec('s1', 'BEGIN');
    PERFORM dblink_exec('s2', 'BEGIN');
    PERFORM dblink_exec('s1', 'UPDATE public.demo_books SET stock = stock - 1 WHERE id = 1');
    -- s2 也先要 id=1 → 排隊等 s1 (不是死鎖,只是等待)
    PERFORM dblink_send_query('s2', 'UPDATE public.demo_books SET stock = stock - 1 WHERE id = 1');
    PERFORM dblink_exec('s1', 'UPDATE public.demo_books SET stock = stock - 1 WHERE id = 2');
    PERFORM dblink_exec('s1', 'COMMIT');
    RAISE NOTICE 's1 COMMIT 後,s2 的第一句:%', public.demo_collect('s2');
    PERFORM dblink_exec('s2', 'UPDATE public.demo_books SET stock = stock - 1 WHERE id = 2');
    PERFORM dblink_exec('s2', 'COMMIT');
    RAISE NOTICE '✅ 兩個交易都成功,沒有死鎖';
END $$;

\echo '── B 驗證:兩列都被扣了兩次 (10 → 8) ──'
SELECT id, stock FROM public.demo_books ORDER BY id;

-- =====================================================================
\echo ''
\echo '════ 情境 C:庫存扣錯 — Lost Update ════'
-- 症狀:兩個人同時下單各買一本,庫存卻只少了一本;沒有任何錯誤
-- =====================================================================
UPDATE public.demo_books SET stock = 10;

\echo '── C 重現:兩邊都「先 SELECT 讀庫存,在程式裡算完再 UPDATE 寫回」(READ COMMITTED) ──'
DO $$
DECLARE s1_stock INT; s2_stock INT;
BEGIN
    PERFORM dblink_exec('s1', 'BEGIN');
    PERFORM dblink_exec('s2', 'BEGIN');
    SELECT stock INTO s1_stock FROM dblink('s1', 'SELECT stock FROM public.demo_books WHERE id = 1') AS t(stock INT);
    SELECT stock INTO s2_stock FROM dblink('s2', 'SELECT stock FROM public.demo_books WHERE id = 1') AS t(stock INT);
    RAISE NOTICE 's1 讀到 %,s2 讀到 % — 兩邊都算出 %', s1_stock, s2_stock, s1_stock - 1;
    PERFORM dblink_exec('s1', format('UPDATE public.demo_books SET stock = %s WHERE id = 1', s1_stock - 1));
    PERFORM dblink_exec('s1', 'COMMIT');
    PERFORM dblink_exec('s2', format('UPDATE public.demo_books SET stock = %s WHERE id = 1', s2_stock - 1));
    PERFORM dblink_exec('s2', 'COMMIT');
END $$;
SELECT stock AS stock_should_be_8 FROM public.demo_books WHERE id = 1;

\echo '── C 排查步驟 1:對帳 — 訂單數與庫存變化對不上 (這是唯一的線索,DB 不會報錯) ──'
\echo '── C 排查步驟 2:找程式裡「SELECT 後在程式計算再 UPDATE 絕對值」的寫法 ──'
-- 根因:READ COMMITTED 下,兩個交易各自讀到 10,各自寫回 9;後寫的蓋掉先寫的。
--       DB 完全按規格運作 — 問題在「讀」與「寫」之間的計算沒有被保護。

\echo '── C 修正 1:把計算搬進 UPDATE (stock = stock - 1),讓 DB 在列鎖下用最新值算 ──'
UPDATE public.demo_books SET stock = 10;
DO $$
BEGIN
    PERFORM dblink_exec('s1', 'BEGIN');
    PERFORM dblink_exec('s1', 'UPDATE public.demo_books SET stock = stock - 1 WHERE id = 1');
    -- s2 同時做同樣的事 → 等 s1 的列鎖;s1 COMMIT 後 s2 會重新讀最新值 (9) 再減 1
    PERFORM dblink_send_query('s2', 'UPDATE public.demo_books SET stock = stock - 1 WHERE id = 1');
    PERFORM pg_sleep(0.2);
    PERFORM dblink_exec('s1', 'COMMIT');
    RAISE NOTICE 's2:%', public.demo_collect('s2');
END $$;
SELECT stock AS stock_is_8 FROM public.demo_books WHERE id = 1;

\echo '── C 修正 2:REPEATABLE READ — 讀寫之間若有人改過,UPDATE 會報 serialization failure,程式要重試 ──'
UPDATE public.demo_books SET stock = 10;
DO $$
DECLARE s2_stock INT;
BEGIN
    PERFORM dblink_exec('s2', 'BEGIN ISOLATION LEVEL REPEATABLE READ');
    SELECT stock INTO s2_stock FROM dblink('s2', 'SELECT stock FROM public.demo_books WHERE id = 1') AS t(stock INT);
    -- s1 在 s2 讀完之後改了並 COMMIT
    PERFORM dblink_exec('s1', 'UPDATE public.demo_books SET stock = stock - 1 WHERE id = 1');
    BEGIN
        PERFORM dblink_exec('s2', format('UPDATE public.demo_books SET stock = %s WHERE id = 1', s2_stock - 1));
        RAISE NOTICE '(不該到這裡)';
    EXCEPTION WHEN serialization_failure THEN
        RAISE NOTICE '✅ s2 被擋下 (SQLSTATE %):%', SQLSTATE, SQLERRM;
    END;
    PERFORM dblink_exec('s2', 'ROLLBACK');
    -- 重試:重新開交易、重新讀、再寫
    PERFORM dblink_exec('s2', 'BEGIN ISOLATION LEVEL REPEATABLE READ');
    SELECT stock INTO s2_stock FROM dblink('s2', 'SELECT stock FROM public.demo_books WHERE id = 1') AS t(stock INT);
    PERFORM dblink_exec('s2', format('UPDATE public.demo_books SET stock = %s WHERE id = 1', s2_stock - 1));
    PERFORM dblink_exec('s2', 'COMMIT');
    RAISE NOTICE '重試後 s2 讀到 % 並寫回 %', s2_stock, s2_stock - 1;
END $$;
SELECT stock AS stock_is_8 FROM public.demo_books WHERE id = 1;

-- =====================================================================
\echo ''
\echo '════ 情境 D:任務佇列 — 同一個任務被兩個 worker 各做一次 ════'
-- 症狀:客戶收到兩封一樣的通知信;job 表看起來正常
-- =====================================================================
CREATE TABLE public.demo_jobs (
    id     SERIAL PRIMARY KEY,
    type   TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending'
);
CREATE TABLE public.demo_job_log (job_id INT, worker TEXT);
INSERT INTO public.demo_jobs (type) VALUES ('email'), ('sms'), ('push'), ('webhook'), ('report');

\echo '── D 重現:worker 先 SELECT 挑任務,再 UPDATE 標記 — 兩個 worker 幾乎同時取件 ──'
DO $$
DECLARE j1 INT; j2 INT;
BEGIN
    PERFORM dblink_exec('s1', 'BEGIN');
    PERFORM dblink_exec('s2', 'BEGIN');
    SELECT id INTO j1 FROM dblink('s1', $q$SELECT id FROM public.demo_jobs WHERE status = 'pending' ORDER BY id LIMIT 1$q$) AS t(id INT);
    SELECT id INTO j2 FROM dblink('s2', $q$SELECT id FROM public.demo_jobs WHERE status = 'pending' ORDER BY id LIMIT 1$q$) AS t(id INT);
    RAISE NOTICE 'worker1 拿到 job %,worker2 拿到 job %', j1, j2;
    PERFORM dblink_exec('s1', format($q$UPDATE public.demo_jobs SET status = 'done' WHERE id = %s$q$, j1));
    PERFORM dblink_exec('s1', format($q$INSERT INTO public.demo_job_log VALUES (%s, 'worker1')$q$, j1));
    PERFORM dblink_exec('s1', 'COMMIT');
    PERFORM dblink_exec('s2', format($q$UPDATE public.demo_jobs SET status = 'done' WHERE id = %s$q$, j2));
    PERFORM dblink_exec('s2', format($q$INSERT INTO public.demo_job_log VALUES (%s, 'worker2')$q$, j2));
    PERFORM dblink_exec('s2', 'COMMIT');
END $$;

\echo '── D 排查步驟 1:從執行紀錄找「同一個 job 被處理超過一次」 ──'
SELECT job_id, count(*) AS times, array_agg(worker) AS workers
FROM public.demo_job_log GROUP BY job_id HAVING count(*) > 1;

\echo '── D 排查步驟 2:確認取件 SQL 有沒有鎖 — 沒有 FOR UPDATE 的 SELECT 不會阻止別人選到同一列 ──'
-- 根因:SELECT 不加鎖,兩個 worker 在對方 UPDATE 之前都看到 job 1 是 pending。
--       UPDATE ... WHERE id = 1 各自都成功 (只是把 done 再寫成 done),DB 不會警告。

\echo '── D 修正:SELECT ... FOR UPDATE SKIP LOCKED — 鎖住自己選到的列,別人直接跳過 ──'
TRUNCATE public.demo_job_log;
UPDATE public.demo_jobs SET status = 'pending';
DO $$
DECLARE j1 INT; j2 INT; t0 TIMESTAMPTZ;
BEGIN
    PERFORM dblink_exec('s1', 'BEGIN');
    PERFORM dblink_exec('s2', 'BEGIN');
    SELECT id INTO j1 FROM dblink('s1', $q$SELECT id FROM public.demo_jobs WHERE status = 'pending' ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED$q$) AS t(id INT);
    t0 := clock_timestamp();
    SELECT id INTO j2 FROM dblink('s2', $q$SELECT id FROM public.demo_jobs WHERE status = 'pending' ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED$q$) AS t(id INT);
    RAISE NOTICE 'worker1 拿到 job %,worker2 拿到 job % (worker2 沒有等待:% ms)',
                 j1, j2, round(EXTRACT(MILLISECONDS FROM clock_timestamp() - t0)::numeric, 1);
    PERFORM dblink_exec('s1', format($q$UPDATE public.demo_jobs SET status = 'done' WHERE id = %s$q$, j1));
    PERFORM dblink_exec('s1', format($q$INSERT INTO public.demo_job_log VALUES (%s, 'worker1')$q$, j1));
    PERFORM dblink_exec('s1', 'COMMIT');
    PERFORM dblink_exec('s2', format($q$UPDATE public.demo_jobs SET status = 'done' WHERE id = %s$q$, j2));
    PERFORM dblink_exec('s2', format($q$INSERT INTO public.demo_job_log VALUES (%s, 'worker2')$q$, j2));
    PERFORM dblink_exec('s2', 'COMMIT');
END $$;

\echo '── D 驗證:每個 job 只被處理一次 ──'
SELECT job_id, count(*) AS times, array_agg(worker) AS workers
FROM public.demo_job_log GROUP BY job_id ORDER BY job_id;

-- ---------------------------------------------------------------------
-- 清理
-- ---------------------------------------------------------------------
SELECT dblink_disconnect('s1');
SELECT dblink_disconnect('s2');
DROP VIEW  IF EXISTS public.demo_lock_monitor;
DROP FUNCTION IF EXISTS public.demo_collect(TEXT);
DROP TABLE IF EXISTS public.demo_job_log;
DROP TABLE IF EXISTS public.demo_jobs;
DROP TABLE IF EXISTS public.demo_books;
\echo ''
\echo '✅ 情境模擬完成 (demo 物件已清除;dblink extension 保留)'
