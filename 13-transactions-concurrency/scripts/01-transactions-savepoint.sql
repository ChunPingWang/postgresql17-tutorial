-- =====================================================================
-- 第 13 章 / 交易基礎與 SAVEPOINT
-- =====================================================================
SET search_path TO shop, public;

\echo '── 1. 成功交易 ────────────────────────────'
BEGIN;
INSERT INTO customers (name, email) VALUES ('Tx Test', 'txtest@x.com');
UPDATE books SET stock = stock + 1 WHERE id = 1;
COMMIT;
SELECT name FROM customers WHERE email = 'txtest@x.com';
DELETE FROM customers WHERE email = 'txtest@x.com';

\echo '── 2. 交易回滾 ────────────────────────────'
BEGIN;
INSERT INTO customers (name, email) VALUES ('Will Rollback', 'rollback@x.com');
ROLLBACK;
SELECT count(*) AS should_be_0 FROM customers WHERE email = 'rollback@x.com';

\echo '── 3. SAVEPOINT 部分回滾 ────────────────────'
BEGIN;
INSERT INTO customers (name, email) VALUES ('SaveOK', 'save_ok@x.com');
SAVEPOINT sp1;
INSERT INTO customers (name, email) VALUES ('SaveBad', 'save_bad@x.com');
-- 後悔了,只回滾 SaveBad
ROLLBACK TO SAVEPOINT sp1;
RELEASE SAVEPOINT sp1;
SELECT name FROM customers WHERE email IN ('save_ok@x.com', 'save_bad@x.com');
ROLLBACK;   -- 整個回滾

\echo '── 4. 錯誤自動讓交易進入 ABORTED 狀態 ─────'
BEGIN;
INSERT INTO customers (name, email) VALUES ('Err', 'err@x.com');
-- 故意造成錯誤
DO $$ BEGIN
    BEGIN
        INSERT INTO customers (name, email) VALUES ('Dup', 'err@x.com');
    EXCEPTION WHEN unique_violation THEN
        RAISE NOTICE '捕獲 unique_violation,交易仍可繼續';
    END;
END$$;
SELECT name FROM customers WHERE email = 'err@x.com';
ROLLBACK;

\echo '── 5. XMIN / XMAX (MVCC 系統欄位) ──────────'
SELECT xmin, xmax, ctid, id, title FROM books LIMIT 3;
