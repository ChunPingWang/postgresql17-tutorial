-- =====================================================================
-- 第 11 章 / PL/pgSQL 控制流程 (LOOP / FOR / WHILE / CASE)
-- =====================================================================
SET search_path TO shop, public;

-- 1) 計數型 FOR
CREATE OR REPLACE FUNCTION shop.factorial(n INT)
RETURNS BIGINT LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
    result BIGINT := 1;
BEGIN
    IF n < 0 THEN
        RAISE EXCEPTION 'n must be >= 0';
    END IF;
    FOR i IN 1..n LOOP
        result := result * i;
    END LOOP;
    RETURN result;
END;
$$;

SELECT shop.factorial(0), shop.factorial(5), shop.factorial(10);

-- 2) FOR 迴圈跑 query
CREATE OR REPLACE FUNCTION shop.list_books_with_log()
RETURNS INT LANGUAGE plpgsql
AS $$
DECLARE
    rec RECORD;
    cnt INT := 0;
BEGIN
    FOR rec IN
        SELECT title, price FROM shop.books WHERE price > 500 ORDER BY price
    LOOP
        cnt := cnt + 1;
        RAISE NOTICE '  #% %  $%', cnt, rec.title, rec.price;
    END LOOP;
    RETURN cnt;
END;
$$;

SELECT shop.list_books_with_log();

-- 3) WHILE
CREATE OR REPLACE FUNCTION shop.gcd(a INT, b INT)
RETURNS INT LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
    t INT;
BEGIN
    WHILE b <> 0 LOOP
        t := b;
        b := a % b;
        a := t;
    END LOOP;
    RETURN a;
END;
$$;

SELECT shop.gcd(48, 18) AS gcd1, shop.gcd(100, 75) AS gcd2;

-- 4) 字串組合 + CASE 運算式
CREATE OR REPLACE FUNCTION shop.book_label(book_id INT)
RETURNS TEXT LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_title TEXT;
    v_price NUMERIC;
BEGIN
    SELECT title, price INTO v_title, v_price
    FROM shop.books WHERE id = book_id;

    IF NOT FOUND THEN
        RETURN '(not found)';
    END IF;

    RETURN format('《%s》 [%s]', v_title,
                  CASE
                      WHEN v_price < 400  THEN '便宜'
                      WHEN v_price < 1000 THEN '一般'
                      ELSE '昂貴'
                  END);
END;
$$;

SELECT shop.book_label(1), shop.book_label(3), shop.book_label(999);

-- 5) 嵌套 BEGIN ... EXCEPTION
CREATE OR REPLACE FUNCTION shop.try_insert_customer(p_email TEXT, p_name TEXT)
RETURNS TEXT LANGUAGE plpgsql
AS $$
BEGIN
    BEGIN
        INSERT INTO shop.customers (email, name) VALUES (p_email, p_name);
        RETURN 'inserted';
    EXCEPTION WHEN unique_violation THEN
        RETURN 'already exists';
    END;
END;
$$;

SELECT shop.try_insert_customer('newone@x.com', 'New One');
SELECT shop.try_insert_customer('newone@x.com', 'Dup');     -- 第二次回 already exists
DELETE FROM shop.customers WHERE email = 'newone@x.com';
