-- =====================================================================
-- 第 13 章 / 隔離等級示範
-- 此腳本需要 2 個 psql session 同時執行來觀察行為差異
-- 可單 session 執行觀察語法,但並發效果要 2 個 session
-- =====================================================================
SET search_path TO shop, public;

\echo '── 查看預設隔離等級 ──'
SHOW transaction_isolation;

\echo '── READ COMMITTED (預設) ──'
-- Session 1: BEGIN; UPDATE books SET price=9999 WHERE id=1;
-- Session 2 (這個視窗): 在 Session 1 COMMIT 前讀不到 9999

BEGIN;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
SELECT id, title, price FROM books WHERE id = 1;
-- 如果此時 Session 1 更新了 id=1 但未 commit,這裡仍看到舊值
COMMIT;

\echo '── REPEATABLE READ ──'
BEGIN;
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
-- 整個交易看到的是 BEGIN 時的快照
SELECT id, price FROM books WHERE id = 1;
-- 即使其他 session 在此期間更新並 commit,這裡結果不變
COMMIT;

\echo '── SERIALIZABLE ──'
BEGIN;
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
SELECT SUM(price) AS total FROM books;
-- PostgreSQL 追蹤這裡讀了哪些列/範圍,
-- 若其他交易與此產生衝突,其中一個會被 ABORT (serialization failure)
COMMIT;

\echo '── 查看目前所有 session 的交易狀態 ──'
SELECT pid,
       state,
       wait_event_type,
       wait_event,
       query
FROM pg_stat_activity
WHERE datname = 'bookstore' AND pid <> pg_backend_pid();
