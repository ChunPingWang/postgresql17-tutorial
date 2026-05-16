-- =====================================================================
-- 第 14 章 / WITH RECURSIVE — 員工組織樹
-- =====================================================================
SET search_path TO shop, public;

\echo '── 1. 員工清單 ──'
SELECT id, name, role, manager_id FROM employees ORDER BY id;

\echo '── 2. 向上找主管鏈 (某員工的所有上司) ──'
WITH RECURSIVE mgr_chain AS (
    -- 起點:Henry (id=8)
    SELECT id, name, role, manager_id, 0 AS depth
    FROM employees WHERE id = 8

    UNION ALL

    SELECT e.id, e.name, e.role, e.manager_id, mc.depth + 1
    FROM employees e
    JOIN mgr_chain mc ON e.id = mc.manager_id
)
SELECT depth, id, name, role
FROM mgr_chain
ORDER BY depth;

\echo '── 3. 向下找所有下屬 (CEO 開始的組織樹) ──'
WITH RECURSIVE org_tree AS (
    SELECT id, name, role, manager_id, 0 AS depth,
           name::text AS path
    FROM employees WHERE manager_id IS NULL    -- CEO

    UNION ALL

    SELECT e.id, e.name, e.role, e.manager_id,
           t.depth + 1,
           t.path || ' > ' || e.name
    FROM employees e
    JOIN org_tree t ON e.manager_id = t.id
)
SELECT
    lpad('', depth * 2, '  ') || name AS org_chart,
    role,
    path
FROM org_tree
ORDER BY path;

\echo '── 4. 計算每人的下屬人數 ──'
WITH RECURSIVE sub AS (
    SELECT id AS root_id, id AS sub_id FROM employees
    UNION ALL
    SELECT s.root_id, e.id
    FROM sub s
    JOIN employees e ON e.manager_id = s.sub_id
)
SELECT m.name, COUNT(*) - 1 AS subordinates
FROM sub s
JOIN employees m ON m.id = s.root_id
GROUP BY m.id, m.name
ORDER BY subordinates DESC;

\echo '── 5. 遞迴生成序列 ──'
WITH RECURSIVE nums AS (
    SELECT 1 AS n
    UNION ALL
    SELECT n + 1 FROM nums WHERE n < 10
)
SELECT n FROM nums;

\echo '── 6. 路徑長度 (防無限迴圈的最大深度) ──'
WITH RECURSIVE limited_tree AS (
    SELECT id, name, manager_id, 0 AS depth
    FROM employees WHERE manager_id IS NULL
    UNION ALL
    SELECT e.id, e.name, e.manager_id, t.depth + 1
    FROM employees e
    JOIN limited_tree t ON e.manager_id = t.id
    WHERE t.depth < 5     -- 安全上限
)
SELECT depth, name FROM limited_tree ORDER BY depth, name;
