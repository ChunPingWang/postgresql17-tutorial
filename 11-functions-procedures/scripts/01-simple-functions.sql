-- =====================================================================
-- 第 11 章 / 簡單 Function (SQL & PL/pgSQL)
-- =====================================================================
SET search_path TO shop, public;

-- 1) 純 SQL Function
CREATE OR REPLACE FUNCTION shop.add(a INT, b INT)
RETURNS INT LANGUAGE sql IMMUTABLE
AS $$ SELECT a + b; $$;

SELECT shop.add(3, 4) AS result;

-- 2) 純 SQL Function 也能查表
CREATE OR REPLACE FUNCTION shop.book_count_in_category(cid INT)
RETURNS BIGINT LANGUAGE sql STABLE
AS $$ SELECT COUNT(*) FROM shop.books WHERE category_id = cid; $$;

SELECT id, name, shop.book_count_in_category(id) AS cnt
FROM shop.categories
ORDER BY id;

-- 3) PL/pgSQL Function — IF/ELSIF/ELSE
CREATE OR REPLACE FUNCTION shop.price_tier(p NUMERIC)
RETURNS TEXT LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
    IF p IS NULL THEN RETURN 'unknown';
    ELSIF p < 400  THEN RETURN 'cheap';
    ELSIF p < 1000 THEN RETURN 'normal';
    ELSE RETURN 'expensive';
    END IF;
END;
$$;

SELECT title, price, shop.price_tier(price) AS tier
FROM shop.books
ORDER BY price;

-- 4) Set-returning function (回傳表)
CREATE OR REPLACE FUNCTION shop.books_in_category(c_name TEXT)
RETURNS TABLE (id INT, title TEXT, price NUMERIC)
LANGUAGE plpgsql STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT b.id, b.title::TEXT, b.price
    FROM shop.books b
    JOIN shop.categories c ON c.id = b.category_id
    WHERE c.name = c_name
    ORDER BY b.price DESC;
END;
$$;

SELECT * FROM shop.books_in_category('Database');

-- 5) 例外處理
CREATE OR REPLACE FUNCTION shop.safe_divide(a NUMERIC, b NUMERIC)
RETURNS NUMERIC LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
    RETURN a / b;
EXCEPTION
    WHEN division_by_zero THEN
        RAISE NOTICE '除以 0,回傳 NULL';
        RETURN NULL;
END;
$$;

SELECT shop.safe_divide(10, 0)  AS div_zero,
       shop.safe_divide(10, 4)  AS div_four;
