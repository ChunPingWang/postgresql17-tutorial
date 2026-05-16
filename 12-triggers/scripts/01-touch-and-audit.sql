-- =====================================================================
-- 第 12 章 / 自動 updated_at 與稽核 trigger
-- =====================================================================
SET search_path TO shop, public;

-- 1) updated_at 自動更新
CREATE OR REPLACE FUNCTION shop.fn_touch_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_books_updated_at ON shop.books;
CREATE TRIGGER trg_books_updated_at
BEFORE UPDATE ON shop.books
FOR EACH ROW EXECUTE FUNCTION shop.fn_touch_updated_at();

-- 測試
SELECT id, title, updated_at FROM shop.books WHERE id = 1;
UPDATE shop.books SET stock = stock WHERE id = 1;
SELECT id, title, updated_at FROM shop.books WHERE id = 1;

-- 2) 稽核紀錄表
CREATE TABLE IF NOT EXISTS shop.audit_log (
    id          BIGSERIAL PRIMARY KEY,
    table_name  TEXT NOT NULL,
    op          TEXT NOT NULL,
    old_data    JSONB,
    new_data    JSONB,
    changed_by  TEXT DEFAULT CURRENT_USER,
    changed_at  TIMESTAMPTZ DEFAULT NOW()
);

-- 3) 稽核 trigger function (適用於任何表)
CREATE OR REPLACE FUNCTION shop.fn_audit_generic()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO shop.audit_log(table_name, op, old_data, new_data)
    VALUES (
        TG_TABLE_NAME,
        TG_OP,
        CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) END,
        CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) END
    );
    RETURN COALESCE(NEW, OLD);
END;
$$;

-- 4) 綁到 books 上 (INSERT / UPDATE / DELETE 三事件)
DROP TRIGGER IF EXISTS trg_audit_books ON shop.books;
CREATE TRIGGER trg_audit_books
AFTER INSERT OR UPDATE OR DELETE ON shop.books
FOR EACH ROW EXECUTE FUNCTION shop.fn_audit_generic();

-- 5) 測試:模擬一連串變更
BEGIN;
INSERT INTO shop.books (title, author_id, category_id, isbn, price, stock, published_at)
VALUES ('Audit Test', 1, 1, '978-AUDIT', 100, 5, CURRENT_DATE);

UPDATE shop.books SET price = 120 WHERE isbn = '978-AUDIT';
UPDATE shop.books SET stock = 3   WHERE isbn = '978-AUDIT';
DELETE FROM shop.books             WHERE isbn = '978-AUDIT';

-- 看稽核紀錄
SELECT id, table_name, op,
       old_data->>'title' AS old_title,
       old_data->>'price' AS old_price,
       new_data->>'title' AS new_title,
       new_data->>'price' AS new_price
FROM shop.audit_log
ORDER BY id DESC
LIMIT 5;

ROLLBACK;     -- 不保留測試紀錄
