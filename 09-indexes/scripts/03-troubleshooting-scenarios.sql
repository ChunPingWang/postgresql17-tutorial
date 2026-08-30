-- =====================================================================
-- 第 9 章 / 問題排查情境模擬 (對應 README 9.11 節)
-- 用法:psql -d bookstore -f 03-troubleshooting-scenarios.sql
--
-- 每個情境都用自己的 demo 表,跑完會清掉,不影響 bookstore 其他章節。
-- 建議搭配 README 9.11 的「排查順序」逐段執行、對照輸出。
-- 注意:情境 D 會刻意出現一個 ERROR,那是情境的一部分,不是腳本壞掉。
-- =====================================================================
SET search_path TO shop, public;

-- ---------------------------------------------------------------------
-- 共用測試資料:50 萬筆事件,每 30 秒一筆 (約 173 天)
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS ts_events;
CREATE TABLE ts_events (
    id          BIGSERIAL PRIMARY KEY,
    created_at  TIMESTAMPTZ NOT NULL,
    kind        TEXT NOT NULL,
    payload     TEXT
);
INSERT INTO ts_events (created_at, kind, payload)
SELECT TIMESTAMPTZ '2025-01-01 00:00:00+00' + (g * INTERVAL '30 seconds'),
       (ARRAY['click', 'view', 'buy'])[1 + (g % 3)],
       md5(g::text)
FROM generate_series(1, 500000) g;

CREATE INDEX idx_events_created ON ts_events (created_at);
ANALYZE ts_events;

-- =====================================================================
\echo ''
\echo '════ 情境 A:明明有索引,查詢還是 Seq Scan ════'
-- 症狀:created_at 上有索引,但「查某一天的事件」跑了全表掃描
-- =====================================================================

\echo '── A-1 排查步驟 1:確認索引真的存在 ──'
SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'ts_events';

\echo '── A-1 排查步驟 2:看執行計畫 (注意 Seq Scan 與 Filter 那一行) ──'
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM ts_events
WHERE created_at::date = DATE '2025-03-01';

-- 根因:條件對「欄位」做了轉型 (created_at::date),索引存的是 timestamptz 的原值,
--       planner 無法用索引比對轉型後的值 → 只能全表掃描後逐列 Filter。
--       而且 timestamptz→date 依賴 session 時區,不是 IMMUTABLE,連表達式索引都建不了。

\echo '── A-1 修正:改寫成對欄位原值的範圍條件 (sargable) ──'
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM ts_events
WHERE created_at >= TIMESTAMPTZ '2025-03-01 00:00:00+00'
  AND created_at <  TIMESTAMPTZ '2025-03-02 00:00:00+00';

\echo '── A-2 同類問題:LIKE 前置萬用字元 ──'
CREATE INDEX idx_events_payload ON ts_events (payload);
ANALYZE ts_events;
-- B-Tree 是排序結構,只能從「開頭」比對;'%abc%' 沒有開頭可比 → Seq Scan
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM ts_events WHERE payload LIKE '%abc%';

\echo '── A-2 修正:模糊比對要用 pg_trgm 的 GIN 索引 (setup 已啟用 pg_trgm) ──'
DROP INDEX idx_events_payload;
CREATE INDEX idx_events_payload_trgm ON ts_events USING gin (payload gin_trgm_ops);
ANALYZE ts_events;
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM ts_events WHERE payload LIKE '%abc%';
DROP INDEX idx_events_payload_trgm;

-- =====================================================================
\echo ''
\echo '════ 情境 B:昨天還很快的查詢,今天突然變慢 (統計資料過期) ════'
-- 症狀:同一條 SQL、同一個索引,沒改任何東西卻慢了 10 倍
-- =====================================================================
DROP TABLE IF EXISTS jobs;
CREATE TABLE jobs (
    id      SERIAL PRIMARY KEY,
    status  TEXT NOT NULL,
    payload TEXT
);
-- 只為了讓情境穩定重現:關掉這張 demo 表的 autovacuum,避免它在示範途中偷偷 ANALYZE
ALTER TABLE jobs SET (autovacuum_enabled = false);

-- 初始狀態:99.9% 是 done,pending 很少 → 用索引找 pending 是對的
INSERT INTO jobs (status, payload)
SELECT CASE WHEN g % 1000 = 0 THEN 'pending' ELSE 'done' END, md5(g::text)
FROM generate_series(1, 500000) g;
CREATE INDEX idx_jobs_status ON jobs (status);
ANALYZE jobs;

\echo '── B 昨天:估計列數 (rows=) 與實際 (actual rows=) 接近,走索引 ──'
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM jobs WHERE status = 'pending';

-- 今天:批次作業把 80% 的工作重設為 pending
UPDATE jobs SET status = 'pending' WHERE id <= 400000;

\echo '── B 今天:排查步驟 1:看估計 vs 實際 — rows 差了近千倍 ──'
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM jobs WHERE status = 'pending';

\echo '── B 排查步驟 2:統計資料多久沒更新?累積多少變更? ──'
SELECT relname, n_live_tup, n_mod_since_analyze, last_analyze, last_autoanalyze
FROM pg_stat_user_tables WHERE relname = 'jobs';

-- 根因:planner 用的是舊統計 (pending 只有 0.1%),所以仍選索引;
--       實際上 80% 的列都符合,索引反而要一列列回表,比 Seq Scan 更慢。

\echo '── B 修正:ANALYZE 之後估計正確,planner 自己改選 Seq Scan ──'
ANALYZE jobs;
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM jobs WHERE status = 'pending';

\echo '── B 驗證:確認 last_analyze 已更新、n_mod_since_analyze 歸零 ──'
SELECT relname, n_mod_since_analyze, last_analyze
FROM pg_stat_user_tables WHERE relname = 'jobs';

-- =====================================================================
\echo ''
\echo '════ 情境 C:寫入越來越慢、磁碟一直長 (多餘與重複的索引) ════'
-- 症狀:讀取沒變慢,但 INSERT/UPDATE 延遲變高,索引總大小逼近表本身
-- =====================================================================
-- 模擬歷任開發者各自「順手」加的索引
CREATE INDEX idx_events_created_dup   ON ts_events (created_at);          -- 與 idx_events_created 完全重複
CREATE INDEX idx_events_created_kind  ON ts_events (created_at, kind);    -- 使單欄索引成為前綴冗餘
CREATE INDEX idx_events_kind          ON ts_events (kind);                -- 只有 3 種值,選擇度極低
ANALYZE ts_events;

\echo '── C 排查步驟 1:索引總大小 vs 表大小 ──'
SELECT pg_size_pretty(pg_table_size('ts_events'))   AS table_size,
       pg_size_pretty(pg_indexes_size('ts_events')) AS indexes_size,
       (SELECT count(*) FROM pg_indexes WHERE tablename = 'ts_events') AS index_count;

\echo '── C 排查步驟 2:量化寫入成本 — 帶著 5 個索引插 10 萬列 ──'
EXPLAIN (ANALYZE, BUFFERS)
INSERT INTO ts_events (created_at, kind, payload)
SELECT now() + (g * INTERVAL '1 second'), 'click', md5(g::text)
FROM generate_series(1, 100000) g;

\echo '── C 排查步驟 3:找完全重複的索引 (相同欄位、運算子類別、條件) ──'
SELECT indrelid::regclass AS table_name,
       array_agg(indexrelid::regclass) AS duplicate_indexes
FROM pg_index
WHERE indrelid = 'ts_events'::regclass
GROUP BY indrelid, indkey, indclass, indexprs::text, indpred::text
HAVING count(*) > 1;

\echo '── C 排查步驟 4:找被複合索引「前綴覆蓋」的索引 ──'
SELECT a.indexrelid::regclass AS redundant_index,
       b.indexrelid::regclass AS covered_by
FROM pg_index a
JOIN pg_index b ON a.indrelid = b.indrelid AND a.indexrelid <> b.indexrelid
WHERE a.indrelid = 'ts_events'::regclass
  AND NOT a.indisunique AND NOT a.indisprimary
  AND a.indpred IS NULL AND b.indpred IS NULL
  AND a.indkey::text <> b.indkey::text
  AND position((a.indkey::text || ' ') IN (b.indkey::text || ' ')) = 1;

\echo '── C 排查步驟 5:從未被使用的索引 (idx_scan = 0;生產環境要看夠長的觀察期) ──'
SELECT indexrelname, idx_scan, pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE relname = 'ts_events'
ORDER BY pg_relation_size(indexrelid) DESC;

\echo '── C 修正:刪掉重複與冗餘 (生產環境用 DROP INDEX CONCURRENTLY,避免鎖表) ──'
DROP INDEX idx_events_created_dup;
DROP INDEX idx_events_created;        -- 被 (created_at, kind) 前綴覆蓋
DROP INDEX idx_events_kind;           -- 選擇度太低,planner 幾乎不會用

\echo '── C 驗證:同樣插 10 萬列,比較 Execution Time ──'
EXPLAIN (ANALYZE, BUFFERS)
INSERT INTO ts_events (created_at, kind, payload)
SELECT now() + (g * INTERVAL '1 second'), 'view', md5(g::text)
FROM generate_series(1, 100000) g;

-- =====================================================================
\echo ''
\echo '════ 情境 D:CREATE INDEX CONCURRENTLY 失敗,留下 INVALID 索引 ════'
-- 症狀:上線加索引時報錯,之後查詢沒變快,而且寫入還更慢了
-- =====================================================================
\echo '── D 重現:對有重複值的欄位建 UNIQUE 索引 (下面這個 ERROR 是預期的) ──'
CREATE UNIQUE INDEX CONCURRENTLY idx_events_kind_uq ON ts_events (kind);

\echo '── D 排查步驟 1:錯誤後索引沒有被自動清掉,而是以 INVALID 狀態留著 ──'
SELECT indexrelid::regclass AS index_name, indisvalid, indisready
FROM pg_index
WHERE indrelid = 'ts_events'::regclass;

-- 根因:CONCURRENTLY 分多個交易階段執行,中途失敗無法整體 rollback,
--       留下的 INVALID 索引不會被查詢使用,但每次寫入仍要維護它 (純負擔)。

\echo '── D 修正:刪掉 INVALID 索引,修好資料/定義後再重建 ──'
DROP INDEX CONCURRENTLY idx_events_kind_uq;
SELECT indexrelid::regclass AS index_name, indisvalid
FROM pg_index WHERE indrelid = 'ts_events'::regclass;

-- ---------------------------------------------------------------------
-- 清理
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS ts_events;
DROP TABLE IF EXISTS jobs;
\echo ''
\echo '✅ 情境模擬完成 (demo 表已清除)'
