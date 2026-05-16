-- =====================================================================
-- 第 16 章 / Row Level Security (RLS)
-- =====================================================================
SET search_path TO shop, public;

-- 示範 RLS:依 customer_id 隔離訂單可見性
\echo '── 1. 建立 RLS ──'
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;

CREATE POLICY policy_orders_by_customer ON orders
    AS PERMISSIVE
    FOR ALL
    USING (
        -- 允許超級使用者看全部 (current_setting 不存在時回 NULL)
        current_setting('app.customer_id', true) IS NULL
        OR customer_id = current_setting('app.customer_id', true)::INT
    );

\echo '── 2. 不設定 session 參數 → 超級使用者看全部 ──'
SELECT id, customer_id, status, total FROM orders ORDER BY id;

\echo '── 3. 設定 customer_id = 1 → 只看自己的 ──'
SET app.customer_id = '1';
SELECT id, customer_id, status, total FROM orders ORDER BY id;

\echo '── 4. 切換到 customer_id = 2 ──'
SET app.customer_id = '2';
SELECT id, customer_id, status, total FROM orders ORDER BY id;

\echo '── 5. 清除設定後恢復看全部 ──'
RESET app.customer_id;
SELECT count(*) AS all_orders FROM orders;

\echo '── 6. 查看 Policy ──'
SELECT policyname, cmd, qual
FROM pg_policies
WHERE schemaname = 'shop' AND tablename = 'orders';

-- 清理
ALTER TABLE orders DISABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS policy_orders_by_customer ON orders;
\echo '✅ RLS 示範完成,已清除'
