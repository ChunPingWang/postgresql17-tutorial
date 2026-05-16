-- =====================================================================
-- 第 12 章 / 衍生欄位維護 — 訂單 total 自動同步
-- =====================================================================
SET search_path TO shop, public;

-- 1) trigger function
CREATE OR REPLACE FUNCTION shop.fn_recalc_order_total()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_order_id INT := COALESCE(NEW.order_id, OLD.order_id);
BEGIN
    UPDATE shop.orders
       SET total = COALESCE((
           SELECT SUM(quantity * unit_price)
           FROM shop.order_items WHERE order_id = v_order_id
       ), 0)
     WHERE id = v_order_id;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_items_recalc ON shop.order_items;
CREATE TRIGGER trg_items_recalc
AFTER INSERT OR UPDATE OR DELETE ON shop.order_items
FOR EACH ROW EXECUTE FUNCTION shop.fn_recalc_order_total();

-- 2) 防止價格下降的 trigger
CREATE OR REPLACE FUNCTION shop.fn_no_lower_price()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.price < OLD.price THEN
        RAISE EXCEPTION '價格不可降低 (% → %)', OLD.price, NEW.price;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_no_lower_price ON shop.books;
CREATE TRIGGER trg_no_lower_price
BEFORE UPDATE OF price ON shop.books
FOR EACH ROW WHEN (NEW.price <> OLD.price)
EXECUTE FUNCTION shop.fn_no_lower_price();

-- 3) 測試:total 自動同步
BEGIN;
SELECT id, total FROM shop.orders WHERE id = 1;
\echo '↑ before'

INSERT INTO shop.order_items (order_id, book_id, quantity, unit_price)
VALUES (1, 6, 2, 300);
SELECT id, total FROM shop.orders WHERE id = 1;
\echo '↑ after insert (total 自動加)'

UPDATE shop.order_items SET quantity = 5 WHERE order_id = 1 AND book_id = 6;
SELECT id, total FROM shop.orders WHERE id = 1;
\echo '↑ after update quantity'

DELETE FROM shop.order_items WHERE order_id = 1 AND book_id = 6;
SELECT id, total FROM shop.orders WHERE id = 1;
\echo '↑ after delete (total 自動扣)'

-- 4) 測試:降價會被攔
DO $$
BEGIN
    BEGIN
        UPDATE shop.books SET price = price - 50 WHERE id = 1;
        RAISE EXCEPTION '應該被攔下';
    EXCEPTION WHEN raise_exception THEN
        RAISE NOTICE '✅ 降價被 trigger 攔下: %', SQLERRM;
    END;
END$$;

ROLLBACK;
