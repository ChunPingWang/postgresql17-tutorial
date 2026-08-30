-- =====================================================================
-- 第 10 章 / 問題排查情境模擬 (對應 README 10.9 節)
-- 用法:psql -d bookstore -f 03-troubleshooting-scenarios.sql
--
-- 每個情境都用自己的 demo 表與 view (ts_ 開頭),跑完會清掉,
-- 不會動到 v_book_full / v_order_summary / mv_category_sales。
-- 注意:情境 A、B、C 各有刻意出現的 ERROR,那是情境的一部分,不是腳本壞掉
--       (全部 4 個:A 兩個、B 一個、C 一個,每個前面都有「預期」字樣)。
-- 情境 C 用 dblink 模擬第二個連線來觀察鎖。
-- =====================================================================
SET search_path TO shop, public;
CREATE EXTENSION IF NOT EXISTS dblink;

-- =====================================================================
\echo ''
\echo '════ 情境 A:改表時被 view 擋住 — cannot drop column ... because other objects depend on it ════'
-- 症狀:要刪掉一個沒人用的舊欄位,ALTER TABLE 報錯;想用 CREATE OR REPLACE VIEW 修 view 也報錯
-- =====================================================================
DROP TABLE IF EXISTS ts_products CASCADE;
CREATE TABLE ts_products (
    id        SERIAL PRIMARY KEY,
    name      TEXT NOT NULL,
    price     NUMERIC(10,2) NOT NULL,
    old_code  TEXT                      -- 舊系統代碼,早就沒人用了
);
INSERT INTO ts_products (name, price, old_code) VALUES
    ('Widget', 10, 'W-1'), ('Gadget', 25, 'G-1'), ('Gizmo', 40, 'Z-1');

-- 兩層 view:v_products_basic 用到 old_code;v_products_expensive 疊在它上面
CREATE VIEW ts_v_products_basic AS
SELECT id, name, price, old_code FROM ts_products;
CREATE VIEW ts_v_products_expensive AS
SELECT id, name, price FROM ts_v_products_basic WHERE price > 20;

\echo '── A 重現:刪欄位 (下面這個 ERROR 是預期的) ──'
ALTER TABLE ts_products DROP COLUMN old_code;

\echo '── A 排查步驟 1:錯誤訊息的 DETAIL 已經點名直接依賴者;用 pg_depend 把「整條依賴鏈」找出來 ──'
WITH RECURSIVE deps AS (
    -- 起點:直接依賴 ts_products 的 rewrite rule (view 的本體是 _RETURN rule)
    SELECT DISTINCT r.ev_class AS view_oid, 1 AS level
    FROM pg_depend d
    JOIN pg_rewrite r ON r.oid = d.objid
    WHERE d.refobjid = 'ts_products'::regclass
      AND d.classid = 'pg_rewrite'::regclass
      AND r.ev_class <> 'ts_products'::regclass
    UNION
    -- 往上層找:依賴「上一層 view」的 view
    SELECT DISTINCT r.ev_class, deps.level + 1
    FROM deps
    JOIN pg_depend d ON d.refobjid = deps.view_oid AND d.classid = 'pg_rewrite'::regclass
    JOIN pg_rewrite r ON r.oid = d.objid
    WHERE r.ev_class <> deps.view_oid
)
SELECT level, view_oid::regclass AS dependent_view,
       pg_get_viewdef(view_oid, true) AS definition
FROM deps ORDER BY level;

\echo '── A 排查步驟 2:哪個 view 真的用到 old_code?(只有第一層) ──'
SELECT c.relname AS view_name
FROM pg_depend d
JOIN pg_rewrite r ON r.oid = d.objid
JOIN pg_class c   ON c.oid = r.ev_class
JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
WHERE d.refobjid = 'ts_products'::regclass
  AND a.attname = 'old_code'
  AND c.relname <> 'ts_products';

\echo '── A 常見的錯誤修法:CREATE OR REPLACE VIEW 拿掉那個欄位 (下面這個 ERROR 也是預期的) ──'
-- CREATE OR REPLACE 只能「在尾端加欄位」,不能拿掉、改名、改型別、改順序
CREATE OR REPLACE VIEW ts_v_products_basic AS
SELECT id, name, price FROM ts_products;

\echo '── A 正確修法:在一個交易裡 DROP 整條鏈 → 改表 → 依序重建 ──'
BEGIN;
DROP VIEW ts_v_products_expensive;
DROP VIEW ts_v_products_basic;
ALTER TABLE ts_products DROP COLUMN old_code;
CREATE VIEW ts_v_products_basic AS
SELECT id, name, price FROM ts_products;
CREATE VIEW ts_v_products_expensive AS
SELECT id, name, price FROM ts_v_products_basic WHERE price > 20;
COMMIT;

\echo '── A 驗證:欄位已刪、兩個 view 都還在且可查 ──'
SELECT column_name FROM information_schema.columns
WHERE table_name = 'ts_products' ORDER BY ordinal_position;
SELECT * FROM ts_v_products_expensive ORDER BY id;

-- =====================================================================
\echo ''
\echo '════ 情境 B:底表改了,view 的資料「怪怪的」(view 綁的是欄位位置,不是名字) ════'
-- 症狀:表加了新欄位 view 看不到;欄位改名後 view 還是舊名字;改型別直接報錯
-- =====================================================================
DROP TABLE IF EXISTS ts_users CASCADE;
CREATE TABLE ts_users (id SERIAL PRIMARY KEY, email TEXT NOT NULL, plan TEXT NOT NULL DEFAULT 'free');
INSERT INTO ts_users (email, plan) VALUES ('a@x.io', 'free'), ('b@x.io', 'pro');

-- 用 SELECT * 建 view,以為之後會「自動跟著表」
CREATE VIEW ts_v_users AS SELECT * FROM ts_users;

\echo '── B-1 重現:表加了 created_at,view 卻沒有 ──'
ALTER TABLE ts_users ADD COLUMN created_at TIMESTAMPTZ NOT NULL DEFAULT now();
SELECT column_name FROM information_schema.columns WHERE table_name = 'ts_v_users' ORDER BY ordinal_position;

\echo '── B-1 排查:pg_get_viewdef 顯示 * 在建立當下就被展開成固定欄位清單 ──'
SELECT pg_get_viewdef('ts_v_users'::regclass, true) AS stored_definition;

\echo '── B-2 重現:底表欄位改名,view 的欄位名不會跟著變 ──'
ALTER TABLE ts_users RENAME COLUMN plan TO subscription_plan;
SELECT column_name FROM information_schema.columns WHERE table_name = 'ts_v_users' ORDER BY ordinal_position;
-- view 定義變成 ts_users.subscription_plan AS plan:資料還對,但名字已經跟表脫節
SELECT pg_get_viewdef('ts_v_users'::regclass, true) AS stored_definition;

\echo '── B-3 重現:改欄位型別直接被 view 擋下 (下面這個 ERROR 是預期的) ──'
ALTER TABLE ts_users ALTER COLUMN email TYPE VARCHAR(320);

\echo '── B 修正:CREATE OR REPLACE 可以「在尾端加欄位」;改名/改型別要 DROP 重建 ──'
CREATE OR REPLACE VIEW ts_v_users AS
SELECT id, email, subscription_plan AS plan, created_at FROM ts_users;   -- 保留舊欄位順序,尾端加新欄位
SELECT column_name FROM information_schema.columns WHERE table_name = 'ts_v_users' ORDER BY ordinal_position;

BEGIN;
DROP VIEW ts_v_users;
ALTER TABLE ts_users ALTER COLUMN email TYPE VARCHAR(320);
CREATE VIEW ts_v_users AS SELECT id, email, subscription_plan, created_at FROM ts_users;
COMMIT;

\echo '── B 驗證:型別已改、view 欄位名與表一致 ──'
SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'ts_v_users' ORDER BY ordinal_position;

-- =====================================================================
\echo ''
\echo '════ 情境 C:儀表板數字是昨天的 (Materialized View 沒 refresh / refresh 卡住讀取) ════'
-- 症狀:報表數字對不上底表;排程改成 CONCURRENTLY 又報錯;refresh 期間儀表板整個卡住
-- =====================================================================
DROP MATERIALIZED VIEW IF EXISTS ts_mv_daily_sales;
DROP TABLE IF EXISTS ts_sales;
CREATE TABLE ts_sales (id SERIAL PRIMARY KEY, sold_on DATE NOT NULL, amount NUMERIC(10,2) NOT NULL);
INSERT INTO ts_sales (sold_on, amount)
SELECT DATE '2025-06-01' + (g % 30), (g % 100) + 1
FROM generate_series(1, 200000) g;

CREATE MATERIALIZED VIEW ts_mv_daily_sales AS
SELECT sold_on, count(*) AS orders, sum(amount) AS revenue
FROM ts_sales GROUP BY sold_on;

-- 今天又進了一批單
INSERT INTO ts_sales (sold_on, amount)
SELECT DATE '2025-06-30', 500 FROM generate_series(1, 1000);

\echo '── C 排查步驟 1:mv 的數字 vs 底表現算的數字 ──'
SELECT 'mv'   AS source, revenue FROM ts_mv_daily_sales WHERE sold_on = '2025-06-30'
UNION ALL
SELECT 'base', sum(amount) FROM ts_sales WHERE sold_on = '2025-06-30';

\echo '── C 排查步驟 2:mv 有沒有被填過?(PostgreSQL 沒有內建「上次 refresh 時間」) ──'
SELECT matviewname, ispopulated, hasindexes FROM pg_matviews WHERE matviewname = 'ts_mv_daily_sales';

\echo '── C 排查步驟 3:想不鎖讀取地 refresh,卻報錯 (下面這個 ERROR 是預期的) ──'
REFRESH MATERIALIZED VIEW CONCURRENTLY ts_mv_daily_sales;

\echo '── C 觀察:一般 REFRESH 期間,別的連線 SELECT 會被擋住 (用 dblink 當第二個連線) ──'
SELECT dblink_connect('c2', 'dbname=bookstore');
BEGIN;
REFRESH MATERIALIZED VIEW ts_mv_daily_sales;     -- 交易還沒 COMMIT,鎖還握著
SELECT dblink_send_query('c2', 'SELECT count(*) FROM shop.ts_mv_daily_sales') AS sent;
SELECT pg_sleep(0.5);
SELECT wait_event_type, wait_event, state, left(query, 45) AS query
FROM pg_stat_activity
WHERE query LIKE 'SELECT count(*) FROM shop.ts_mv_daily_sales%' AND pid <> pg_backend_pid();
SELECT mode, granted FROM pg_locks
WHERE relation = 'ts_mv_daily_sales'::regclass AND pid = pg_backend_pid();
COMMIT;                                           -- 放鎖,第二個連線才拿到結果
SELECT * FROM dblink_get_result('c2') AS t(cnt BIGINT);
SELECT dblink_disconnect('c2');

\echo '── C 修正:建 UNIQUE INDEX (CONCURRENTLY 的前提),之後用 CONCURRENTLY refresh ──'
CREATE UNIQUE INDEX ts_mv_daily_sales_uq ON ts_mv_daily_sales (sold_on);
INSERT INTO ts_sales (sold_on, amount) SELECT DATE '2025-06-30', 100 FROM generate_series(1, 500);
REFRESH MATERIALIZED VIEW CONCURRENTLY ts_mv_daily_sales;

\echo '── C 驗證:mv 與底表一致 ──'
SELECT 'mv'   AS source, revenue FROM ts_mv_daily_sales WHERE sold_on = '2025-06-30'
UNION ALL
SELECT 'base', sum(amount) FROM ts_sales WHERE sold_on = '2025-06-30';

\echo '── C 延伸:自己記錄 refresh 時間,排查「多久沒更新」才有依據 ──'
CREATE TABLE ts_mv_refresh_log (matview TEXT PRIMARY KEY, refreshed_at TIMESTAMPTZ NOT NULL);
INSERT INTO ts_mv_refresh_log VALUES ('ts_mv_daily_sales', now())
ON CONFLICT (matview) DO UPDATE SET refreshed_at = EXCLUDED.refreshed_at;
SELECT matview, now() - refreshed_at AS age FROM ts_mv_refresh_log;

-- =====================================================================
\echo ''
\echo '════ 情境 D:view 越疊越慢 — 只要一個欄位,卻付了五張表 JOIN 的錢 ════'
-- 症狀:應用只查 v_order_wide 的一兩個欄位,EXPLAIN 卻顯示全部表都被 JOIN
-- =====================================================================
DROP VIEW IF EXISTS ts_v_order_wide;
DROP VIEW IF EXISTS ts_v_order_wide_fixed;
DROP TABLE IF EXISTS ts_order_items, ts_orders, ts_customers, ts_products_d CASCADE;
CREATE TABLE ts_customers  (id SERIAL PRIMARY KEY, name TEXT NOT NULL, region TEXT NOT NULL);
CREATE TABLE ts_products_d (id SERIAL PRIMARY KEY, name TEXT NOT NULL, category TEXT NOT NULL);
CREATE TABLE ts_orders     (id SERIAL PRIMARY KEY, customer_id INT NOT NULL REFERENCES ts_customers(id),
                            ordered_at TIMESTAMPTZ NOT NULL, status TEXT NOT NULL);
CREATE TABLE ts_order_items(id SERIAL PRIMARY KEY, order_id INT NOT NULL REFERENCES ts_orders(id),
                            product_id INT NOT NULL REFERENCES ts_products_d(id), qty INT NOT NULL);
INSERT INTO ts_customers  SELECT g, 'cust ' || g, (ARRAY['north','south','east','west'])[1 + g % 4] FROM generate_series(1, 5000) g;
INSERT INTO ts_products_d SELECT g, 'prod ' || g, 'cat ' || (g % 20) FROM generate_series(1, 2000) g;
INSERT INTO ts_orders     SELECT g, 1 + (g % 5000), TIMESTAMPTZ '2025-01-01' + g * INTERVAL '1 minute',
                                 (ARRAY['pending','paid','shipped'])[1 + g % 3] FROM generate_series(1, 100000) g;
INSERT INTO ts_order_items SELECT g, 1 + (g % 100000), 1 + (g % 2000), 1 + g % 5 FROM generate_series(1, 200000) g;
ANALYZE ts_customers; ANALYZE ts_products_d; ANALYZE ts_orders; ANALYZE ts_order_items;

-- 「把所有東西 JOIN 好」的萬用 view (INNER JOIN)
CREATE VIEW ts_v_order_wide AS
SELECT o.id AS order_id, o.ordered_at, o.status,
       c.name AS customer, c.region,
       p.name AS product, p.category, oi.qty
FROM ts_orders o
JOIN ts_customers   c  ON c.id = o.customer_id
JOIN ts_order_items oi ON oi.order_id = o.id
JOIN ts_products_d  p  ON p.id = oi.product_id;

\echo '── D 排查步驟 1:應用只要「某天有幾張 pending 訂單」,計畫卻 JOIN 了四張表 ──'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(DISTINCT order_id) FROM ts_v_order_wide
WHERE status = 'pending' AND ordered_at >= '2025-01-10' AND ordered_at < '2025-01-11';

\echo '── D 排查步驟 2:view 的定義 — INNER JOIN 會改變列數,planner 不能省略它 ──'
SELECT pg_get_viewdef('ts_v_order_wide'::regclass, true);

-- 根因:INNER JOIN 可能過濾掉列 (沒有對應 customer 的訂單會消失),
--       所以就算查詢沒用到 customers 的欄位,planner 也不敢把 JOIN 拿掉。
--       LEFT JOIN 到「唯一鍵」則不會改變列數,planner 可以整個省略 (join removal)。

\echo '── D 修正 1:拆 view — 只 JOIN 查詢真的需要的表 ──'
CREATE VIEW ts_v_order_wide_fixed AS
SELECT o.id AS order_id, o.ordered_at, o.status,
       c.name AS customer, c.region
FROM ts_orders o
LEFT JOIN ts_customers c ON c.id = o.customer_id;   -- LEFT JOIN 到 PK:沒用到就會被省略

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT count(*) FROM ts_v_order_wide_fixed
WHERE status = 'pending' AND ordered_at >= '2025-01-10' AND ordered_at < '2025-01-11';

-- 修正 2:明細層 (order_items) 另外做一個 view,需要時才 JOIN;不要一個 view 包天下
-- 驗證:同樣的需求,對照上面兩個計畫的 Buffers 與 Execution Time

-- ---------------------------------------------------------------------
-- 清理
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS ts_v_order_wide, ts_v_order_wide_fixed;
DROP TABLE IF EXISTS ts_order_items, ts_orders, ts_customers, ts_products_d;
DROP TABLE IF EXISTS ts_mv_refresh_log;
DROP MATERIALIZED VIEW IF EXISTS ts_mv_daily_sales;
DROP TABLE IF EXISTS ts_sales;
DROP VIEW IF EXISTS ts_v_users;
DROP TABLE IF EXISTS ts_users;
DROP VIEW IF EXISTS ts_v_products_expensive, ts_v_products_basic;
DROP TABLE IF EXISTS ts_products;
\echo ''
\echo '✅ 情境模擬完成 (demo 物件已清除)'
