-- =====================================================================
-- 第 12 章 / 問題排查情境模擬 (對應 README 12.12 節)
-- 用法:psql -d bookstore -f 04-troubleshooting-scenarios.sql
--
-- 每個情境都用自己的 demo_* 表與 trigger,跑完會清掉,
-- 不會在 shop.books / shop.order_items 等表上留下任何 trigger。
-- 建議搭配 README 12.12 的「排查順序」逐段執行、對照輸出。
-- 注意:情境 C 會刻意觸發一個錯誤,但已包在 DO ... EXCEPTION 裡,不會有裸 ERROR。
-- =====================================================================
SET search_path TO shop, public;

-- =====================================================================
\echo ''
\echo '════ 情境 A:INSERT 沒報錯,資料卻沒進去 (BEFORE trigger 回傳 NULL) ════'
-- 症狀:應用程式 INSERT 成功 (沒有 exception),事後查卻找不到那筆資料
-- =====================================================================
DROP TABLE IF EXISTS demo_signups CASCADE;
CREATE TABLE demo_signups (
    id         SERIAL PRIMARY KEY,
    email      TEXT NOT NULL,
    source     TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 某人想「INSERT 時順便正規化 email」,照著 AFTER trigger 的寫法回了 NULL
CREATE OR REPLACE FUNCTION demo_fn_normalize_email()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.email := lower(btrim(NEW.email));
    RETURN NULL;     -- ← 錯在這裡:BEFORE ROW 回 NULL = 「這一列不要做了」
END;
$$;

CREATE TRIGGER trg_normalize_email
BEFORE INSERT ON demo_signups
FOR EACH ROW EXECUTE FUNCTION demo_fn_normalize_email();

\echo '── A 症狀重現:注意 INSERT 的回應是 INSERT 0 0,而且沒有任何錯誤 ──'
INSERT INTO demo_signups (email, source) VALUES ('  Alice@Example.com ', 'web');
SELECT count(*) AS rows_in_table FROM demo_signups;

\echo '── A 排查步驟 1:這張表上有哪些 trigger?時機 (BEFORE/AFTER)、粒度 (ROW/STATEMENT)? ──'
SELECT tgname,
       CASE WHEN tgtype & 2  > 0 THEN 'BEFORE' ELSE 'AFTER' END AS timing,
       CASE WHEN tgtype & 1  > 0 THEN 'ROW'    ELSE 'STATEMENT' END AS level,
       tgenabled,
       tgfoid::regproc AS function_name
FROM pg_trigger
WHERE tgrelid = 'demo_signups'::regclass AND NOT tgisinternal;

\echo '── A 排查步驟 2:看 trigger function 的原始碼,找 RETURN ──'
SELECT pg_get_functiondef('demo_fn_normalize_email'::regproc);

-- 根因:BEFORE ROW trigger 的回傳值就是「接下來要寫入的那一列」;
--       回 NULL 代表跳過這列,而且這不算錯誤,所以應用程式完全不知道。

\echo '── A 修正:BEFORE ROW 一定要 RETURN NEW (UPDATE/DELETE 時視情況 RETURN OLD) ──'
CREATE OR REPLACE FUNCTION demo_fn_normalize_email()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.email := lower(btrim(NEW.email));
    RETURN NEW;
END;
$$;

\echo '── A 驗證:INSERT 0 1,而且 email 已正規化 ──'
INSERT INTO demo_signups (email, source) VALUES ('  Alice@Example.com ', 'web');
SELECT id, email, source FROM demo_signups;

\echo '── A-2 同類問題:BEFORE UPDATE 回 OLD,更新被默默丟掉 ──'
CREATE OR REPLACE FUNCTION demo_fn_touch()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    OLD.created_at := NOW();   -- 改錯物件,又回傳 OLD
    RETURN OLD;                -- ← 回傳 OLD = 用「舊值」覆蓋,等於這次 UPDATE 沒發生
END;
$$;
CREATE TRIGGER trg_touch BEFORE UPDATE ON demo_signups
FOR EACH ROW EXECUTE FUNCTION demo_fn_touch();

UPDATE demo_signups SET source = 'mobile' WHERE id = 2;
SELECT id, source AS source_after_update FROM demo_signups WHERE id = 2;
-- 修正:改 NEW、回 NEW
CREATE OR REPLACE FUNCTION demo_fn_touch()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.created_at := NOW();
    RETURN NEW;
END;
$$;
UPDATE demo_signups SET source = 'mobile' WHERE id = 2;
SELECT id, source AS source_after_fix FROM demo_signups WHERE id = 2;

-- =====================================================================
\echo ''
\echo '════ 情境 B:批次匯入 20 萬列從幾百毫秒變成幾秒 (row-level trigger 成本) ════'
-- 症狀:同樣的 COPY/INSERT 批次,加了「稽核 trigger」之後慢了好幾倍
-- =====================================================================
DROP TABLE IF EXISTS demo_events CASCADE;
DROP TABLE IF EXISTS demo_events_audit CASCADE;
CREATE TABLE demo_events (
    id      SERIAL PRIMARY KEY,
    kind    TEXT NOT NULL,
    payload TEXT
);
CREATE TABLE demo_events_audit (
    id         BIGSERIAL PRIMARY KEY,
    op         TEXT,
    event_id   INT,
    kind       TEXT,
    logged_at  TIMESTAMPTZ DEFAULT NOW()
);

\echo '── B 基準線:沒有 trigger 時插 20 萬列 ──'
EXPLAIN (ANALYZE, SUMMARY ON)
INSERT INTO demo_events (kind, payload)
SELECT (ARRAY['click','view','buy'])[1 + (g % 3)], md5(g::text)
FROM generate_series(1, 200000) g;

-- 基準線量完就清掉,後面的筆數才好對帳
TRUNCATE demo_events, demo_events_audit RESTART IDENTITY;

-- 常見寫法:FOR EACH ROW,每一列都執行一次 INSERT 到稽核表
CREATE OR REPLACE FUNCTION demo_fn_audit_row()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO demo_events_audit (op, event_id, kind)
    VALUES (TG_OP, NEW.id, NEW.kind);
    RETURN NULL;
END;
$$;
CREATE TRIGGER trg_audit_row
AFTER INSERT ON demo_events
FOR EACH ROW EXECUTE FUNCTION demo_fn_audit_row();

\echo '── B 症狀重現:帶 row-level trigger 插 20 萬列 (注意 Trigger 那一行的 time 與 calls) ──'
EXPLAIN (ANALYZE, SUMMARY ON)
INSERT INTO demo_events (kind, payload)
SELECT (ARRAY['click','view','buy'])[1 + (g % 3)], md5(g::text)
FROM generate_series(1, 200000) g;

\echo '── B 排查步驟 1:EXPLAIN ANALYZE 直接把 trigger 的時間列出來 (上面 "Trigger trg_audit_row: time=... calls=200000") ──'
\echo '── B 排查步驟 2:確認是每列呼叫一次 (calls = 列數) → 是 row-level ──'
SELECT tgname,
       CASE WHEN tgtype & 1 > 0 THEN 'ROW' ELSE 'STATEMENT' END AS level
FROM pg_trigger WHERE tgrelid = 'demo_events'::regclass AND NOT tgisinternal;

-- 根因:FOR EACH ROW 的 trigger 是「每一列呼叫一次 PL/pgSQL 函數 + 一次單列 INSERT」,
--       20 萬列就是 20 萬次函數呼叫與 20 萬次單列寫入,固定開銷被放大 20 萬倍。

\echo '── B 修正 1:改成 STATEMENT-level + transition table,一次 INSERT ... SELECT 寫完 ──'
DROP TRIGGER trg_audit_row ON demo_events;
CREATE OR REPLACE FUNCTION demo_fn_audit_stmt()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO demo_events_audit (op, event_id, kind)
    SELECT TG_OP, n.id, n.kind FROM new_rows n;
    RETURN NULL;
END;
$$;
CREATE TRIGGER trg_audit_stmt
AFTER INSERT ON demo_events
REFERENCING NEW TABLE AS new_rows
FOR EACH STATEMENT EXECUTE FUNCTION demo_fn_audit_stmt();

EXPLAIN (ANALYZE, SUMMARY ON)
INSERT INTO demo_events (kind, payload)
SELECT (ARRAY['click','view','buy'])[1 + (g % 3)], md5(g::text)
FROM generate_series(1, 200000) g;

\echo '── B 驗證:稽核筆數與事件筆數一致 (row-level 與 statement-level 各 20 萬,都沒漏) ──'
SELECT (SELECT count(*) FROM demo_events)       AS events,
       (SELECT count(*) FROM demo_events_audit) AS audit_rows;

\echo '── B 修正 2 (另一種選擇):初始匯入/搬遷時暫時停用 trigger,事後補稽核 ──'
ALTER TABLE demo_events DISABLE TRIGGER trg_audit_stmt;
EXPLAIN (ANALYZE, SUMMARY ON)
INSERT INTO demo_events (kind, payload)
SELECT 'import', md5(g::text) FROM generate_series(1, 200000) g;
ALTER TABLE demo_events ENABLE TRIGGER trg_audit_stmt;
-- 停用期間的資料沒有稽核紀錄,要自己補:
INSERT INTO demo_events_audit (op, event_id, kind)
SELECT 'BACKFILL', e.id, e.kind
FROM demo_events e
WHERE NOT EXISTS (SELECT 1 FROM demo_events_audit a WHERE a.event_id = e.id);
SELECT (SELECT count(*) FROM demo_events)       AS events,
       (SELECT count(*) FROM demo_events_audit) AS audit_rows;

-- =====================================================================
\echo ''
\echo '════ 情境 C:stack depth limit exceeded (trigger 更新自己的表,無限遞迴) ════'
-- 症狀:一條普通的 UPDATE 跑幾秒後爆出 stack depth limit exceeded
-- =====================================================================
DROP TABLE IF EXISTS demo_counters CASCADE;
CREATE TABLE demo_counters (
    id          INT PRIMARY KEY,
    hits        INT NOT NULL DEFAULT 0,
    updated_at  TIMESTAMPTZ
);
INSERT INTO demo_counters (id) VALUES (1);

-- 想在每次 UPDATE 後順便記 updated_at,但用 AFTER trigger 再 UPDATE 同一張表
CREATE OR REPLACE FUNCTION demo_fn_touch_after()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    UPDATE demo_counters SET updated_at = NOW() WHERE id = NEW.id;   -- ← 又觸發自己
    RETURN NULL;
END;
$$;
CREATE TRIGGER trg_touch_after
AFTER UPDATE ON demo_counters
FOR EACH ROW EXECUTE FUNCTION demo_fn_touch_after();

\echo '── C 症狀重現 (錯誤已被 DO 區塊接住,只印 NOTICE) ──'
DO $$
BEGIN
    UPDATE demo_counters SET hits = hits + 1 WHERE id = 1;
    RAISE EXCEPTION '不應該走到這裡';
EXCEPTION WHEN statement_too_complex THEN
    RAISE NOTICE '❌ 重現成功 SQLSTATE=%: %', SQLSTATE, left(SQLERRM, 60);
END$$;

\echo '── C 排查步驟 1:錯誤訊息的 CONTEXT 會一路列出 "SQL statement ... PL/pgSQL function demo_fn_touch_after()" 重複幾百次 ──'
\echo '── C 排查步驟 2:列出這張表的 trigger,看有沒有 trigger function 寫回同一張表 ──'
SELECT t.tgname, t.tgfoid::regproc AS fn,
       position('UPDATE demo_counters' IN pg_get_functiondef(t.tgfoid)) > 0 AS writes_same_table
FROM pg_trigger t
WHERE t.tgrelid = 'demo_counters'::regclass AND NOT t.tgisinternal;

-- 根因:AFTER UPDATE trigger 內對同一張表 UPDATE → 再次觸發同一個 trigger → 無限遞迴,
--       直到 max_stack_depth 用完。

\echo '── C 修正 1 (最佳):改成 BEFORE trigger 直接改 NEW,根本不需要第二次 UPDATE ──'
DROP TRIGGER trg_touch_after ON demo_counters;
CREATE OR REPLACE FUNCTION demo_fn_touch_before()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_touch_before
BEFORE UPDATE ON demo_counters
FOR EACH ROW EXECUTE FUNCTION demo_fn_touch_before();
UPDATE demo_counters SET hits = hits + 1 WHERE id = 1;
SELECT id, hits, updated_at IS NOT NULL AS touched FROM demo_counters;

\echo '── C 修正 2 (真的需要 AFTER 時):用 pg_trigger_depth() 擋住遞迴 ──'
DROP TRIGGER trg_touch_before ON demo_counters;
CREATE TRIGGER trg_touch_after
AFTER UPDATE ON demo_counters
FOR EACH ROW
WHEN (pg_trigger_depth() = 0)          -- 只有「不是由 trigger 引起的」UPDATE 才觸發
EXECUTE FUNCTION demo_fn_touch_after();
UPDATE demo_counters SET hits = hits + 1 WHERE id = 1;
SELECT id, hits, updated_at IS NOT NULL AS touched FROM demo_counters;

-- =====================================================================
\echo ''
\echo '════ 情境 D:訂單總額跟明細對不起來 (衍生欄位 trigger 事件不完整) ════'
-- 症狀:財務對帳發現 orders.total 與 SUM(order_items) 有出入,但只有部分訂單
-- =====================================================================
DROP TABLE IF EXISTS demo_items CASCADE;
DROP TABLE IF EXISTS demo_orders CASCADE;
CREATE TABLE demo_orders (id SERIAL PRIMARY KEY, total NUMERIC(12,2) NOT NULL DEFAULT 0);
CREATE TABLE demo_items (
    id       SERIAL PRIMARY KEY,
    order_id INT NOT NULL REFERENCES demo_orders(id) ON DELETE CASCADE,
    qty      INT NOT NULL,
    price    NUMERIC(10,2) NOT NULL
);

-- 當初只想到「新增明細要加總額」,只綁了 INSERT
CREATE OR REPLACE FUNCTION demo_fn_recalc_total()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_order_id INT := COALESCE(NEW.order_id, OLD.order_id);
BEGIN
    UPDATE demo_orders
       SET total = COALESCE((SELECT SUM(qty * price) FROM demo_items WHERE order_id = v_order_id), 0)
     WHERE id = v_order_id;
    RETURN NULL;
END;
$$;
CREATE TRIGGER trg_recalc_total
AFTER INSERT ON demo_items            -- ← 少了 UPDATE OR DELETE
FOR EACH ROW EXECUTE FUNCTION demo_fn_recalc_total();

-- 3 張訂單,各 2 筆明細
INSERT INTO demo_orders DEFAULT VALUES;
INSERT INTO demo_orders DEFAULT VALUES;
INSERT INTO demo_orders DEFAULT VALUES;
INSERT INTO demo_items (order_id, qty, price) VALUES
    (1, 1, 100), (1, 2, 50),
    (2, 1, 300), (2, 1, 200),
    (3, 3, 10),  (3, 1, 70);

-- 之後的日常操作:客服改數量、刪一筆明細
UPDATE demo_items SET qty = 5 WHERE order_id = 2 AND price = 300;
DELETE FROM demo_items WHERE order_id = 3 AND price = 70;

\echo '── D 排查步驟 1:對帳查詢 — 找出 total ≠ SUM(明細) 的訂單 ──'
SELECT o.id, o.total AS stored_total,
       COALESCE(SUM(i.qty * i.price), 0) AS computed_total,
       o.total - COALESCE(SUM(i.qty * i.price), 0) AS drift
FROM demo_orders o
LEFT JOIN demo_items i ON i.order_id = o.id
GROUP BY o.id, o.total
HAVING o.total <> COALESCE(SUM(i.qty * i.price), 0)
ORDER BY o.id;

\echo '── D 排查步驟 2:trigger 綁了哪些事件? (tgtype 位元:4=INSERT 8=DELETE 16=UPDATE) ──'
SELECT tgname,
       (tgtype & 4)  > 0 AS on_insert,
       (tgtype & 16) > 0 AS on_update,
       (tgtype & 8)  > 0 AS on_delete
FROM pg_trigger WHERE tgrelid = 'demo_items'::regclass AND NOT tgisinternal;

-- 根因:只有 INSERT 會重算;UPDATE / DELETE 明細時 total 停在舊值。
--       只有「被改過/刪過明細」的訂單才會飄,所以看起來像隨機發生。

\echo '── D 修正 1:補齊事件 ──'
DROP TRIGGER trg_recalc_total ON demo_items;
CREATE TRIGGER trg_recalc_total
AFTER INSERT OR UPDATE OR DELETE ON demo_items
FOR EACH ROW EXECUTE FUNCTION demo_fn_recalc_total();

\echo '── D 修正 2:回填 — 修 trigger 不會修歷史資料,要主動重算一次 ──'
UPDATE demo_orders o
   SET total = COALESCE((SELECT SUM(qty * price) FROM demo_items WHERE order_id = o.id), 0);

\echo '── D 驗證:對帳查詢應回 0 列;再做一次 UPDATE/DELETE 也不會飄 ──'
UPDATE demo_items SET qty = 10 WHERE order_id = 1 AND price = 100;
DELETE FROM demo_items WHERE order_id = 2 AND price = 200;
SELECT count(*) AS drifted_orders
FROM (
    SELECT o.id
    FROM demo_orders o LEFT JOIN demo_items i ON i.order_id = o.id
    GROUP BY o.id, o.total
    HAVING o.total <> COALESCE(SUM(i.qty * i.price), 0)
) d;

-- =====================================================================
\echo ''
\echo '════ 情境 E:兩個 trigger 的執行順序不如預期 (依名稱字典序) ════'
-- 症狀:「先補預設值、再驗證」的兩個 trigger,驗證卻總是失敗
-- =====================================================================
DROP TABLE IF EXISTS demo_tickets CASCADE;
CREATE TABLE demo_tickets (id SERIAL PRIMARY KEY, priority TEXT, title TEXT NOT NULL);

CREATE OR REPLACE FUNCTION demo_fn_set_default_priority()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.priority IS NULL THEN NEW.priority := 'normal'; END IF;
    RETURN NEW;
END;
$$;
CREATE OR REPLACE FUNCTION demo_fn_validate_priority()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.priority NOT IN ('low','normal','high') OR NEW.priority IS NULL THEN
        RAISE EXCEPTION 'priority 不合法: %', NEW.priority;
    END IF;
    RETURN NEW;
END;
$$;
-- 開發者以為「建立順序」= 執行順序:先建 set_default,再建 validate
CREATE TRIGGER trg_set_default BEFORE INSERT ON demo_tickets
FOR EACH ROW EXECUTE FUNCTION demo_fn_set_default_priority();
CREATE TRIGGER trg_check_priority BEFORE INSERT ON demo_tickets
FOR EACH ROW EXECUTE FUNCTION demo_fn_validate_priority();

\echo '── E 症狀重現 (錯誤已被 DO 接住) ──'
DO $$
BEGIN
    INSERT INTO demo_tickets (title) VALUES ('沒填 priority');
    RAISE NOTICE '(不會到這裡)';
EXCEPTION WHEN raise_exception THEN
    RAISE NOTICE '❌ 驗證先跑了: %', SQLERRM;
END$$;

\echo '── E 排查步驟:同表同時機的 trigger 依「名稱字典序」執行,看 ORDER BY tgname ──'
SELECT tgname FROM pg_trigger
WHERE tgrelid = 'demo_tickets'::regclass AND NOT tgisinternal
ORDER BY tgname;

-- 根因:trg_check_priority < trg_set_default (c < s),驗證先於補值。建立順序不影響。

\echo '── E 修正:用名稱前綴明確排序 (例如 10_、20_) ──'
ALTER TRIGGER trg_set_default   ON demo_tickets RENAME TO trg_10_set_default;
ALTER TRIGGER trg_check_priority ON demo_tickets RENAME TO trg_20_check_priority;
INSERT INTO demo_tickets (title) VALUES ('沒填 priority');
SELECT id, priority, title FROM demo_tickets;

-- ---------------------------------------------------------------------
-- 清理
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS demo_signups, demo_events, demo_events_audit,
                     demo_counters, demo_items, demo_orders, demo_tickets CASCADE;
DROP FUNCTION IF EXISTS demo_fn_normalize_email(), demo_fn_touch(),
                        demo_fn_audit_row(), demo_fn_audit_stmt(),
                        demo_fn_touch_after(), demo_fn_touch_before(),
                        demo_fn_recalc_total(),
                        demo_fn_set_default_priority(), demo_fn_validate_priority();
\echo ''
\echo '✅ 情境模擬完成 (demo 表與 function 已清除)'
