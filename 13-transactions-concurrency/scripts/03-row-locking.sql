-- =====================================================================
-- 第 13 章 / 列鎖 / SELECT FOR UPDATE / SKIP LOCKED / Advisory Lock
-- =====================================================================
SET search_path TO shop, public;

\echo '── 1. SELECT FOR UPDATE (悲觀鎖) ──'
BEGIN;
-- 先鎖定再修改,確保讀到最新值且別人不能同時修改
SELECT stock FROM books WHERE id = 1 FOR UPDATE;
UPDATE books SET stock = stock - 1 WHERE id = 1;
ROLLBACK;

\echo '── 2. SKIP LOCKED — 任務佇列模式 ──'
-- 建一個 jobs 表模擬任務佇列
DROP TABLE IF EXISTS jobs;
CREATE TABLE jobs (
    id     SERIAL PRIMARY KEY,
    type   TEXT,
    status TEXT DEFAULT 'pending'
);
INSERT INTO jobs (type) VALUES ('email'), ('sms'), ('push'), ('webhook'), ('report');

-- Worker 1 取一個任務
BEGIN;
SELECT id, type FROM jobs
WHERE status = 'pending'
ORDER BY id
LIMIT 1 FOR UPDATE SKIP LOCKED;
-- 這個 worker 鎖住了第一筆,其他 worker 用 SKIP LOCKED 就跳過去

ROLLBACK;   -- 模擬未完成

\echo '── 3. NOWAIT — 鎖不到立即報錯 ──'
BEGIN;
DO $$
BEGIN
    BEGIN
        PERFORM 1 FROM books WHERE id = 1 FOR UPDATE NOWAIT;
        RAISE NOTICE '✅ 取得鎖';
    EXCEPTION WHEN lock_not_available THEN
        RAISE NOTICE '⚠️  鎖不到 (lock_not_available)';
    END;
END$$;
ROLLBACK;

\echo '── 4. Advisory Lock ──'
-- 用於應用層邏輯鎖 (例如確保只有一個排程任務在跑)
SELECT pg_advisory_lock(999);
SELECT pg_try_advisory_lock(999) AS can_lock_again;  -- false,已被鎖
SELECT pg_advisory_unlock(999);
SELECT pg_try_advisory_lock(999) AS can_lock_now;    -- true

\echo '── 5. 查看目前表鎖 ──'
SELECT
    locktype,
    relation::regclass AS relation,
    mode,
    granted
FROM pg_locks
WHERE database = (SELECT oid FROM pg_database WHERE datname = current_database())
  AND relation IS NOT NULL
ORDER BY relation;

DROP TABLE jobs;
