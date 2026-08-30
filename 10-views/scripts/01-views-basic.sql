-- =====================================================================
-- 第 10 章 / View 基本操作 (含可更新 View 與 WITH CHECK OPTION)
-- =====================================================================
SET search_path TO shop, public;

DROP VIEW IF EXISTS v_pending_orders;
DROP VIEW IF EXISTS v_in_stock;
DROP VIEW IF EXISTS v_order_summary;
DROP VIEW IF EXISTS v_book_full;

-- 1) 基本 View
CREATE VIEW v_book_full AS
SELECT
    b.id,
    b.title,
    a.name AS author,
    c.name AS category,
    b.price,
    b.stock,
    b.published_at,
    b.metadata
FROM books b
LEFT JOIN authors    a ON a.id = b.author_id
LEFT JOIN categories c ON c.id = b.category_id;

-- 使用
SELECT id, title, author, category, price FROM v_book_full ORDER BY id LIMIT 5;

-- 2) 聚合 View
CREATE VIEW v_order_summary AS
SELECT
    o.id,
    c.name AS customer,
    o.status,
    o.ordered_at,
    COUNT(oi.id) AS line_count,
    SUM(oi.quantity * oi.unit_price) AS computed_total
FROM orders o
JOIN customers c       ON c.id = o.customer_id
LEFT JOIN order_items oi ON oi.order_id = o.id
GROUP BY o.id, c.name, o.status, o.ordered_at;

SELECT * FROM v_order_summary ORDER BY id;

-- 3) 可更新 View (單表、無聚合)
CREATE VIEW v_in_stock AS
SELECT id, title, price, stock
FROM books
WHERE stock > 0;

-- 透過 view 更新底表
BEGIN;
UPDATE v_in_stock SET price = price * 1.05 WHERE id = 1
RETURNING id, title, price;
ROLLBACK;

-- 4) WITH CHECK OPTION:防止插入「跑出 view 範圍」的資料
CREATE VIEW v_pending_orders AS
SELECT id, customer_id, status, ordered_at, total
FROM orders
WHERE status = 'pending'
WITH CHECK OPTION;

-- 這個 INSERT 應失敗
DO $$
BEGIN
    BEGIN
        INSERT INTO v_pending_orders (customer_id, status, total)
        VALUES (1, 'completed', 100);
        RAISE EXCEPTION '應該被 CHECK OPTION 攔下';
    EXCEPTION WHEN with_check_option_violation THEN
        RAISE NOTICE '✅ WITH CHECK OPTION 攔下不符合條件的 INSERT';
    END;
END$$;

-- 5) 列出 schema 中的所有 view
SELECT viewname FROM pg_views WHERE schemaname = 'shop' ORDER BY viewname;

-- 6) 清理 (留下 v_book_full 與 v_order_summary 給後續章節)
DROP VIEW v_in_stock;
DROP VIEW v_pending_orders;
