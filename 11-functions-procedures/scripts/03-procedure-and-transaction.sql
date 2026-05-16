-- =====================================================================
-- 第 11 章 / PROCEDURE 與內部交易控制
-- =====================================================================
SET search_path TO shop, public;

-- 1) 基本 PROCEDURE
CREATE OR REPLACE PROCEDURE shop.adjust_stock(p_book_id INT, p_delta INT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_new_stock INT;
BEGIN
    UPDATE shop.books
       SET stock = stock + p_delta
     WHERE id = p_book_id
    RETURNING stock INTO v_new_stock;

    IF v_new_stock IS NULL THEN
        RAISE EXCEPTION 'Book id % not found', p_book_id;
    END IF;
    IF v_new_stock < 0 THEN
        RAISE EXCEPTION 'Stock cannot be negative (would be %)', v_new_stock;
    END IF;

    RAISE NOTICE 'Book % now has stock %', p_book_id, v_new_stock;
END;
$$;

CALL shop.adjust_stock(1, 1);
CALL shop.adjust_stock(1, -1);     -- 還原

-- 2) Procedure 控制交易 (BEGIN..COMMIT..ROLLBACK)
-- 注意:必須以自身為頂層交易呼叫,不能在 BEGIN...COMMIT 區塊內呼叫
CREATE OR REPLACE PROCEDURE shop.bulk_adjust(p_qty INT)
LANGUAGE plpgsql
AS $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN SELECT id FROM shop.books ORDER BY id LOOP
        UPDATE shop.books SET stock = stock + p_qty WHERE id = rec.id;
        -- 每筆一次 commit (示範用,實務謹慎)
        COMMIT;
    END LOOP;
END;
$$;

-- 想還原:
-- CALL shop.bulk_adjust(1);
-- CALL shop.bulk_adjust(-1);

-- 3) OUT 參數
CREATE OR REPLACE PROCEDURE shop.summarize_book(
    IN  p_book_id  INT,
    OUT out_title  TEXT,
    OUT out_revenue NUMERIC
)
LANGUAGE plpgsql
AS $$
BEGIN
    SELECT b.title,
           COALESCE(SUM(oi.quantity * oi.unit_price), 0)
      INTO out_title, out_revenue
      FROM shop.books b
      LEFT JOIN shop.order_items oi ON oi.book_id = b.id
     WHERE b.id = p_book_id
     GROUP BY b.title;
    IF out_title IS NULL THEN
        RAISE EXCEPTION '查無書籍 id=%', p_book_id;
    END IF;
END;
$$;

CALL shop.summarize_book(1, NULL, NULL);

-- 4) 列出所有自訂 function/procedure
SELECT
    p.proname  AS name,
    CASE p.prokind
        WHEN 'f' THEN 'function'
        WHEN 'p' THEN 'procedure'
        WHEN 'a' THEN 'aggregate'
        WHEN 'w' THEN 'window'
    END AS kind,
    pg_get_function_arguments(p.oid) AS args,
    pg_get_function_result(p.oid)    AS returns
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'shop'
ORDER BY kind, name;
