-- =====================================================================
-- 第 18 章 / 問題排查情境模擬 (對應 README 18.12 節)
-- 用法:psql -d bookstore -f 04-troubleshooting-scenarios.sql
--
-- 前提:
--   * pg_stat_statements 已在 shared_preload_libraries (18.7 節);沒有的話情境 A 的
--     統計查詢會回「pg_stat_statements must be loaded via shared_preload_libraries」
--   * pgstattuple、dblink 是 contrib 內建 extension (官方 image / Homebrew 都有)
--   * 情境 D 用 dblink 開本機連線;容器與 Homebrew 的本機連線預設不需密碼,
--     若你的 pg_hba 要密碼,在 demo_conninfo() 的字串尾端加上 password=...
--
-- 每個情境都用自己的 demo 表 (前綴 perf_),跑完會清掉;所有 SET 都用 SET LOCAL 包在交易內。
-- 本腳本沒有預期中的 ERROR;若看到 ERROR 就是環境問題。
-- =====================================================================
SET search_path TO shop, public;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pgstattuple;
CREATE EXTENSION IF NOT EXISTS dblink;

-- ---------------------------------------------------------------------
-- 共用測試資料:20 萬筆訂單 (2000 個客戶、隨機時間與備註) + 2000 個客戶
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS perf_orders;
DROP TABLE IF EXISTS perf_customers;
CREATE TABLE perf_orders (
    id          SERIAL PRIMARY KEY,
    customer_id INT NOT NULL,
    amount      NUMERIC(10,2) NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL,
    note        TEXT NOT NULL
);
INSERT INTO perf_orders (customer_id, amount, created_at, note)
SELECT (random() * 1999)::INT + 1,
       round((random() * 5000)::numeric, 2),
       TIMESTAMPTZ '2025-01-01' + (random() * INTERVAL '180 days'),
       md5(g::text) || CASE WHEN g % 40000 = 0 THEN ' urgent-refund' ELSE '' END
FROM generate_series(1, 200000) g;
CREATE INDEX idx_perf_orders_customer ON perf_orders (customer_id);
CREATE TABLE perf_customers AS
SELECT g AS id, 'customer-' || g AS name, g % 20 AS region
FROM generate_series(1, 2000) g;
ALTER TABLE perf_customers ADD PRIMARY KEY (id);
ANALYZE perf_orders;
ANALYZE perf_customers;

-- =====================================================================
\echo ''
\echo '════ 情境 A:「整個資料庫都變慢」,其實是一條查詢在吃資源 ════'
-- 症狀:CPU 飆高、所有請求延遲上升;沒有人知道是哪條 SQL
-- =====================================================================
\echo '── A 排查步驟 1:清空統計視窗,只看接下來這段時間 ──'
SELECT pg_stat_statements_reset() IS NOT NULL AS reset_ok;

-- 模擬混合工作負載:\gexec 把每一列結果當成獨立的頂層 SQL 執行
-- (pg_stat_statements 預設 track = top,DO 區塊裡的 EXECUTE 不會被統計);\o 把輸出丟掉
\echo '── A 模擬工作負載:50 次客戶查詢 + 200 次主鍵查詢 + 5 次「客服搜尋備註」──'
\o /dev/null
SELECT format('SELECT count(*) FROM perf_orders WHERE customer_id = %s', g)
FROM generate_series(1, 50) g \gexec
SELECT format('SELECT amount FROM perf_orders WHERE id = %s', g * 37)
FROM generate_series(1, 200) g \gexec
SELECT 'SELECT id, amount FROM perf_orders WHERE note ILIKE ''%urgent-refund%'''
FROM generate_series(1, 5) g \gexec
\o

\echo '── A 排查步驟 2:依「總耗時」排序 — 誰吃掉最多時間? ──'
SELECT left(query, 58)                                        AS query,
       calls,
       round(mean_exec_time::numeric, 2)                      AS mean_ms,
       round(total_exec_time::numeric, 1)                     AS total_ms,
       round((100 * total_exec_time / sum(total_exec_time) OVER ())::numeric, 1) AS pct,
       shared_blks_hit + shared_blks_read                     AS blks
FROM pg_stat_statements
WHERE query ILIKE '%perf_orders%'
ORDER BY total_exec_time DESC
LIMIT 3;

\echo '── A 排查步驟 3:對照「呼叫次數」排序 — 最常跑的不等於最貴的 ──'
SELECT left(query, 58) AS query, calls, round(mean_exec_time::numeric, 3) AS mean_ms
FROM pg_stat_statements
WHERE query ILIKE '%perf_orders%'
ORDER BY calls DESC
LIMIT 3;

\echo '── A 排查步驟 4:拿到元凶 SQL,看計畫 ──'
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, amount FROM perf_orders WHERE note ILIKE '%urgent-refund%';

-- 根因:前置 % 的 ILIKE 無法用 B-Tree,每次都 Seq Scan 20 萬列;
--       它只跑 5 次,但每次的成本是主鍵查詢的上萬倍,總耗時佔比反而最高。
\echo '── A 修正:pg_trgm GIN 索引 (第 9 章 9.11 情境 A-2) ──'
CREATE INDEX idx_perf_orders_note_trgm ON perf_orders USING gin (note gin_trgm_ops);
ANALYZE perf_orders;

\echo '── A 驗證:重置統計、重跑同樣負載,再看總耗時排名 ──'
SELECT pg_stat_statements_reset() IS NOT NULL AS reset_ok;
\o /dev/null
SELECT format('SELECT count(*) FROM perf_orders WHERE customer_id = %s', g)
FROM generate_series(1, 50) g \gexec
SELECT format('SELECT amount FROM perf_orders WHERE id = %s', g * 37)
FROM generate_series(1, 200) g \gexec
SELECT 'SELECT id, amount FROM perf_orders WHERE note ILIKE ''%urgent-refund%'''
FROM generate_series(1, 5) g \gexec
\o
SELECT left(query, 58) AS query, calls,
       round(mean_exec_time::numeric, 2) AS mean_ms,
       round(total_exec_time::numeric, 1) AS total_ms,
       round((100 * total_exec_time / sum(total_exec_time) OVER ())::numeric, 1) AS pct
FROM pg_stat_statements
WHERE query ILIKE '%perf_orders%'
ORDER BY total_exec_time DESC
LIMIT 3;
DROP INDEX idx_perf_orders_note_trgm;

-- =====================================================================
\echo ''
\echo '════ 情境 B:表越來越大、全表掃描越來越慢 (dead tuples 與 bloat) ════'
-- 症狀:資料量沒變,但表檔案大小翻了幾倍,報表查詢跟著變慢
-- =====================================================================
DROP TABLE IF EXISTS perf_bloat;
CREATE TABLE perf_bloat AS SELECT id, customer_id, amount, note FROM perf_orders;
-- 只為了穩定重現:關掉這張 demo 表的 autovacuum,模擬「autovacuum 追不上寫入」
ALTER TABLE perf_bloat SET (autovacuum_enabled = false);
VACUUM ANALYZE perf_bloat;

\echo '── B 基準線:大小與全表掃描 (關掉平行查詢,讓前後可比較) ──'
SELECT pg_size_pretty(pg_relation_size('perf_bloat')) AS table_size,
       n_live_tup, n_dead_tup
FROM pg_stat_user_tables WHERE relname = 'perf_bloat';
BEGIN;
SET LOCAL max_parallel_workers_per_gather = 0;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM perf_bloat;
COMMIT;

-- 模擬批次作業:全表 UPDATE 三次 (MVCC:每次 UPDATE 都留下一份舊版本)
UPDATE perf_bloat SET amount = amount * 1.01;
UPDATE perf_bloat SET amount = amount * 1.01;
UPDATE perf_bloat SET amount = amount * 1.01;

\echo '── B 排查步驟 1:資料筆數沒變,表卻變成 4 倍;統計視圖的 n_dead_tup 是估計值 ──'
SELECT pg_size_pretty(pg_relation_size('perf_bloat')) AS table_size,
       n_live_tup, n_dead_tup,
       round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 1) AS dead_pct_est,
       last_autovacuum
FROM pg_stat_user_tables WHERE relname = 'perf_bloat';

\echo '── B 排查步驟 2:pgstattuple 精確量測 (會掃整張表,大表慎用) ──'
-- dead + free 才是全部浪費:頁內的 HOT pruning 已把部分舊版本轉成 free space
SELECT pg_size_pretty(table_len) AS table_len,
       tuple_count, dead_tuple_count,
       dead_tuple_percent, free_percent,
       dead_tuple_percent + free_percent AS wasted_percent
FROM pgstattuple('perf_bloat');

\echo '── B 排查步驟 3:同樣的 count(*),讀的 Buffers 變 4 倍 ──'
BEGIN;
SET LOCAL max_parallel_workers_per_gather = 0;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM perf_bloat;
COMMIT;

\echo '── B 排查步驟 4:為什麼 autovacuum 沒處理?看這張表的設定 ──'
SELECT relname, reloptions FROM pg_class WHERE relname = 'perf_bloat';

-- 根因:每次 UPDATE 都寫新版本,舊版本 (dead tuple) 要等 VACUUM 回收;
--       autovacuum 被關掉 (或門檻太高、追不上),浪費空間堆到 70%,
--       Seq Scan 得把這些空頁面全部讀過一遍。
\echo '── B 修正 1:VACUUM 回收 dead tuples (不鎖表) ──'
VACUUM (VERBOSE) perf_bloat;
SELECT pg_size_pretty(pg_relation_size('perf_bloat')) AS table_size_after_vacuum,
       n_live_tup, n_dead_tup
FROM pg_stat_user_tables WHERE relname = 'perf_bloat';
SELECT dead_tuple_percent, free_percent FROM pgstattuple('perf_bloat');

-- 注意:VACUUM 只把空間標成「可重用」,檔案不會縮 (free_percent 變高、table_size 不變)。
--       要真的還給 OS 得用 VACUUM FULL (鎖表、重寫) 或 pg_repack。
\echo '── B 修正 2:VACUUM FULL 重寫表 (AccessExclusiveLock,生產環境用 pg_repack) ──'
VACUUM FULL perf_bloat;
SELECT pg_size_pretty(pg_relation_size('perf_bloat')) AS table_size_after_full
FROM pg_stat_user_tables WHERE relname = 'perf_bloat';

\echo '── B 驗證:全表掃描回到基準線 ──'
BEGIN;
SET LOCAL max_parallel_workers_per_gather = 0;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM perf_bloat;
COMMIT;

\echo '── B 治本:對高寫入表把 autovacuum 門檻調低 ──'
ALTER TABLE perf_bloat SET (autovacuum_enabled = true,
                            autovacuum_vacuum_scale_factor = 0.02,
                            autovacuum_vacuum_threshold = 1000);
SELECT reloptions FROM pg_class WHERE relname = 'perf_bloat';

-- =====================================================================
\echo ''
\echo '════ 情境 C:temp 檔案暴增、報表查詢在忙碌時段變慢 (work_mem 與外部排序) ════'
-- 症狀:監控看到 temp_bytes 一直長;報表平常還好,尖峰時段跟著其他查詢一起慢
-- =====================================================================
\echo '── C 排查步驟 1:資料庫層的 temp 檔統計 (累計值,先記下來) ──'
SELECT pg_stat_force_next_flush();
CREATE TEMP TABLE temp_before AS
SELECT temp_files, temp_bytes FROM pg_stat_database WHERE datname = current_database();

\echo '── C 排查步驟 2:用低 work_mem 跑報表,看 Sort 節點的 Sort Method ──'
BEGIN;
SET LOCAL work_mem = '1MB';
EXPLAIN (ANALYZE, BUFFERS)
SELECT customer_id, amount, note FROM perf_orders ORDER BY note;
COMMIT;

\echo '── C 排查步驟 3:這一條查詢寫了多少 temp? ──'
-- PG 15+ 的統計是非同步寫入共用記憶體,先強制 flush 再讀才看得到剛才那筆
SELECT pg_stat_force_next_flush();
SELECT d.temp_files - b.temp_files AS temp_files_delta,
       pg_size_pretty(d.temp_bytes - b.temp_bytes) AS temp_bytes_delta
FROM pg_stat_database d, temp_before b
WHERE d.datname = current_database();
SELECT left(query, 50) AS query, calls, temp_blks_written,
       pg_size_pretty(temp_blks_written * 8192::bigint) AS temp_written
FROM pg_stat_statements
WHERE query ILIKE '%ORDER BY note%' AND query NOT ILIKE '%pg_stat%'
ORDER BY temp_blks_written DESC LIMIT 1;

-- 根因:work_mem 是「每個排序/雜湊節點」的記憶體上限,超過就寫 temp 檔做外部排序。
--       預設 4MB 對報表型查詢 (幾十萬列排序、大表 hash join) 常常不夠。
\echo '── C 修正:只對這條查詢/這個 session 放大 work_mem ──'
BEGIN;
SET LOCAL work_mem = '64MB';
EXPLAIN (ANALYZE, BUFFERS)
SELECT customer_id, amount, note FROM perf_orders ORDER BY note;
COMMIT;

-- 誠實的觀察:在這個規模、temp 檔還在 OS page cache 裡時,兩者執行時間差不多
-- (甚至外部排序略快)。「Disk」是訊號,不是罪證 — 真正的代價出現在 temp 檔超過 cache、
-- 落到實體磁碟,或幾十個報表同時排序互搶 I/O 的時候。判斷依據是 temp_bytes 的量與磁碟 I/O。
\echo '── C 為什麼不能直接把全域 work_mem 設很大?算一下最壞情況 ──'
SELECT current_setting('work_mem')        AS work_mem_now,
       current_setting('max_connections') AS max_conn,
       pg_size_pretty(64::bigint * 1024 * 1024 * current_setting('max_connections')::int * 3)
           AS worst_case_if_64mb_global;   -- 每連線 3 個排序/雜湊節點同時用滿
-- 建議:全域保守 (4~16MB);報表/批次 role 用 ALTER ROLE reporter SET work_mem = '256MB';
--       單次查詢用 SET LOCAL。
DROP TABLE temp_before;

-- =====================================================================
\echo ''
\echo '════ 情境 D:連線數逼近上限,新請求連不進來 ════'
-- 症狀:應用端偶發 "FATAL: sorry, too many clients already";DB 主機記憶體吃緊
-- =====================================================================
-- 模擬:應用程式開了 20 條連線後放著不用 (連線池設太大、或忘了關)
CREATE OR REPLACE FUNCTION demo_conninfo() RETURNS text LANGUAGE sql STABLE AS
$$ SELECT 'dbname=' || current_database() || ' user=' || current_user || ' application_name=leaky_app' $$;

SELECT count(dblink_connect('leak_' || g, demo_conninfo())) AS opened
FROM generate_series(1, 20) g;
-- 讓其中 5 條停在交易裡不 commit (ORM 常見:開了交易忘了結束)
SELECT count(dblink_exec('leak_' || g, 'BEGIN')) AS left_in_transaction
FROM generate_series(1, 5) g;

\echo '── D 排查步驟 1:連線用了幾成?保留給誰? ──'
SELECT current_setting('max_connections')::int                         AS max_conn,
       current_setting('superuser_reserved_connections')::int          AS reserved,
       (SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'client backend') AS in_use;

\echo '── D 排查步驟 2:連線都在做什麼?按 state / 應用程式分組 ──'
SELECT application_name, state, count(*),
       max(now() - state_change)::interval(0) AS oldest_in_state
FROM pg_stat_activity
WHERE backend_type = 'client backend'
GROUP BY application_name, state
ORDER BY count DESC;

-- 根因:20 條連線裡 15 條 idle、5 條 idle in transaction;每條 backend 是一個 process
--       (常駐數 MB + work_mem),連線只是「佔著」,不是在做事。真正在跑的只有 1 條。
--       idle in transaction 更糟:它持有鎖、擋住 VACUUM 回收。
\echo '── D 緊急處置:砍掉 idle in transaction 的連線 (先用 application_name 確認是誰) ──'
SELECT pid, application_name, state,
       pg_terminate_backend(pid) AS terminated
FROM pg_stat_activity
WHERE application_name = 'leaky_app'
  AND state = 'idle in transaction';

SELECT state, count(*) FROM pg_stat_activity
WHERE application_name = 'leaky_app' GROUP BY state;

\echo '── D 治本:idle_in_transaction_session_timeout + 連線池 (PgBouncer,18.8 節) ──'
-- ALTER SYSTEM SET idle_in_transaction_session_timeout = '60s';  SELECT pg_reload_conf();
-- PgBouncer transaction pooling:應用端開 200 條,DB 端只用 20 條
SELECT name, setting, unit FROM pg_settings
WHERE name IN ('idle_in_transaction_session_timeout', 'idle_session_timeout', 'max_connections');

-- 收拾:關閉剩下的 dblink 連線 (被 terminate 的 5 條 disconnect 會報錯,所以逐條容錯)
DO $$
DECLARE n text;
BEGIN
    FOREACH n IN ARRAY dblink_get_connections() LOOP
        BEGIN
            PERFORM dblink_disconnect(n);
        EXCEPTION WHEN OTHERS THEN
            NULL;
        END;
    END LOOP;
END$$;
DROP FUNCTION demo_conninfo();

-- =====================================================================
\echo ''
\echo '════ 情境 E:SSD 主機卻沿用 HDD 的 random_page_cost,planner 不愛用索引 ════'
-- 症狀:明明有索引、選擇度也不差,EXPLAIN 卻選 Seq Scan + Hash Join;
--       手動 enable_seqscan = off 反而更快
-- =====================================================================
\echo '── E 排查步驟 1:目前的 planner 成本參數 ──'
SELECT name, setting FROM pg_settings
WHERE name IN ('random_page_cost', 'seq_page_cost', 'effective_cache_size');

\echo '── E 排查步驟 2:預設 random_page_cost = 4 (HDD 假設) 的計畫:Seq Scan 20 萬列 + Hash Join ──'
BEGIN;
SET LOCAL random_page_cost = 4;
SET LOCAL max_parallel_workers_per_gather = 0;   -- 只為了讓計畫好讀
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*), sum(o.amount)
FROM perf_orders o
JOIN perf_customers c ON c.id = o.customer_id
WHERE c.region = 7;
COMMIT;

\echo '── E 排查步驟 3:強制不用 Seq Scan,看實際時間是否更好 (只用來診斷,不要留在生產) ──'
BEGIN;
SET LOCAL random_page_cost = 4;
SET LOCAL max_parallel_workers_per_gather = 0;
SET LOCAL enable_seqscan = off;
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*), sum(o.amount)
FROM perf_orders o
JOIN perf_customers c ON c.id = o.customer_id
WHERE c.region = 7;
COMMIT;

-- 根因:random_page_cost 告訴 planner「隨機讀一頁比循序讀貴 4 倍」,這是機械硬碟的假設;
--       SSD 上隨機讀幾乎不比循序貴,planner 因此高估索引 (隨機讀) 的成本,偏向全表掃描。
\echo '── E 修正:SSD 把 random_page_cost 設 1.1,planner 自己改選 Nested Loop + Index Scan ──'
BEGIN;
SET LOCAL random_page_cost = 1.1;
SET LOCAL max_parallel_workers_per_gather = 0;
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*), sum(o.amount)
FROM perf_orders o
JOIN perf_customers c ON c.id = o.customer_id
WHERE c.region = 7;
COMMIT;
-- 持久化:ALTER SYSTEM SET random_page_cost = 1.1; SELECT pg_reload_conf();
-- 或只對某個 tablespace:ALTER TABLESPACE fast_ssd SET (random_page_cost = 1.1);

-- ---------------------------------------------------------------------
-- 清理
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS perf_bloat;
DROP TABLE IF EXISTS perf_orders;
DROP TABLE IF EXISTS perf_customers;
SELECT pg_stat_statements_reset() IS NOT NULL AS reset_ok;
\echo ''
\echo '✅ 情境模擬完成 (demo 表已清除)'
