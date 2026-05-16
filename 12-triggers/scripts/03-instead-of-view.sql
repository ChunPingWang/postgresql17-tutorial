-- =====================================================================
-- 第 12 章 / INSTEAD OF Trigger 讓複雜 view 可寫
-- =====================================================================
SET search_path TO shop, public;

DROP VIEW IF EXISTS v_book_with_author CASCADE;

CREATE VIEW v_book_with_author AS
SELECT
    b.id,
    b.title,
    a.name AS author_name,
    b.price
FROM books b
JOIN authors a ON a.id = b.author_id;

-- 預設 view 帶 JOIN,不可直接 INSERT;用 INSTEAD OF trigger 拆解到底表
CREATE OR REPLACE FUNCTION shop.fn_v_book_insert()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_author_id INT;
BEGIN
    SELECT id INTO v_author_id FROM authors WHERE name = NEW.author_name;
    IF v_author_id IS NULL THEN
        INSERT INTO authors(name) VALUES (NEW.author_name)
        RETURNING id INTO v_author_id;
    END IF;

    INSERT INTO books(title, author_id, price)
    VALUES (NEW.title, v_author_id, COALESCE(NEW.price, 0))
    RETURNING id INTO NEW.id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_v_book_ins
INSTEAD OF INSERT ON v_book_with_author
FOR EACH ROW EXECUTE FUNCTION shop.fn_v_book_insert();

-- 測試
BEGIN;
INSERT INTO v_book_with_author (title, author_name, price)
VALUES ('Test INSTEAD OF', 'New Author From View', 199);

SELECT * FROM v_book_with_author WHERE title = 'Test INSTEAD OF';
ROLLBACK;
