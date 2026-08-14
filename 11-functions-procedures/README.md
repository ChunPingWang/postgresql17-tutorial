# 第 11 章 函數 與 Stored Procedure

> 目標:能用 PL/pgSQL 撰寫可重用的 Function 與 Procedure,理解兩者差異。
>
> 🧰 **前置準備**:本章範例使用 `bookstore` 資料庫 (`shop` schema 與範例資料)。尚未建立的話,先在 repo 根目錄執行 `psql -d postgres -f setup/01-create-tutorial-db.sql` 與 `psql -d bookstore -f setup/02-sample-data.sql`,詳見[第 1 章 1.8 節](../01-installation/README.md#18-建立教學用資料庫)。

## 11.1 Function vs Procedure (重要區別)

PostgreSQL **11+** 才有真正的 `PROCEDURE`,在那之前只有 `FUNCTION` 也能做副作用。

| 特性 | FUNCTION | PROCEDURE |
|------|----------|-----------|
| 用 `SELECT` 呼叫 | ✅ | ❌ |
| 用 `CALL` 呼叫 | ❌ | ✅ |
| 在查詢中當值用 | ✅ | ❌ |
| 內部能 `COMMIT` / `ROLLBACK` | ❌ | ✅ |
| 必須有回傳值 | ✅ (可 void) | 無回傳 (用 OUT 參數) |

**白話**:
- 需要**回值用在 SQL** → Function
- 需要**控制交易**或**純執行流程** → Procedure

## 11.2 簡單 Function (SQL 語言)

![建立函數範例](./screenshots/01-create-function.png)

```sql
CREATE OR REPLACE FUNCTION shop.add(a INT, b INT)
RETURNS INT
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT a + b;
$$;

SELECT shop.add(3, 4);   -- 7
```

**volatility 標籤**:
- `IMMUTABLE` — 同輸入永遠同輸出 (可被 planner 預先計算)
- `STABLE` — 同 query 內穩定 (例如 `NOW()` 在同 statement 不變)
- `VOLATILE` (預設) — 每次都可能不同

## 11.3 PL/pgSQL Function (流程控制)

PL/pgSQL 是 PostgreSQL 預設的儲存程序語言,跟 PL/SQL 類似。

```sql
CREATE OR REPLACE FUNCTION shop.price_tier(p NUMERIC)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p IS NULL THEN
        RETURN 'unknown';
    ELSIF p < 400 THEN
        RETURN 'cheap';
    ELSIF p < 1000 THEN
        RETURN 'normal';
    ELSE
        RETURN 'expensive';
    END IF;
END;
$$;

SELECT title, price, shop.price_tier(price) AS tier
FROM shop.books;
```

### 變數宣告與賦值

```sql
CREATE OR REPLACE FUNCTION shop.calc_discount(p NUMERIC, off NUMERIC)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_result NUMERIC;
    v_min    CONSTANT NUMERIC := 0;
BEGIN
    v_result := p * (1 - off/100);
    IF v_result < v_min THEN
        v_result := v_min;
    END IF;
    RETURN ROUND(v_result, 2);
END;
$$;
```

## 11.4 控制流程

```sql
-- 條件
IF cond THEN ... ELSIF cond THEN ... ELSE ... END IF;

-- 簡單 LOOP
LOOP
    EXIT WHEN i > 10;
    i := i + 1;
END LOOP;

-- FOR 計數
FOR i IN 1..10 LOOP ... END LOOP;
FOR i IN REVERSE 10..1 LOOP ... END LOOP;

-- FOR 跑 query 結果
FOR rec IN SELECT * FROM books WHERE price > 500 LOOP
    RAISE NOTICE 'Book: %', rec.title;
END LOOP;

-- WHILE
WHILE x > 0 LOOP x := x - 1; END LOOP;

-- CASE
CASE x
    WHEN 1 THEN ...
    WHEN 2 THEN ...
    ELSE ...
END CASE;
```

## 11.5 回傳多列 / 表 (Set-returning function)

```sql
CREATE OR REPLACE FUNCTION shop.recent_books(days INT)
RETURNS TABLE (id INT, title TEXT, published_at DATE)
LANGUAGE sql
AS $$
    SELECT id, title, published_at
    FROM shop.books
    WHERE published_at >= CURRENT_DATE - (days || ' days')::interval;
$$;

SELECT * FROM shop.recent_books(36500);  -- 近 100 年
```

PL/pgSQL 版本用 `RETURN QUERY` 或 `RETURN NEXT`:

```sql
CREATE OR REPLACE FUNCTION shop.books_in_category(c_name TEXT)
RETURNS TABLE (id INT, title TEXT)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT b.id, b.title
    FROM shop.books b
    JOIN shop.categories c ON c.id = b.category_id
    WHERE c.name = c_name;
END;
$$;

SELECT * FROM shop.books_in_category('Database');
```

## 11.6 例外處理

```sql
CREATE OR REPLACE FUNCTION shop.safe_divide(a NUMERIC, b NUMERIC)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN a / b;
EXCEPTION
    WHEN division_by_zero THEN
        RAISE NOTICE '0 除錯誤,改回傳 NULL';
        RETURN NULL;
    WHEN OTHERS THEN
        RAISE NOTICE '未知錯誤: %', SQLERRM;
        RETURN NULL;
END;
$$;

SELECT shop.safe_divide(10, 0);
```

常用例外名:`unique_violation`, `foreign_key_violation`, `check_violation`, `division_by_zero`, `not_null_violation`, `data_exception`, `OTHERS`。

## 11.7 PROCEDURE (PG 11+)

```sql
CREATE OR REPLACE PROCEDURE shop.transfer_stock(
    src_book_id INT,
    dst_book_id INT,
    qty         INT
)
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE shop.books SET stock = stock - qty WHERE id = src_book_id;
    UPDATE shop.books SET stock = stock + qty WHERE id = dst_book_id;

    IF (SELECT stock FROM shop.books WHERE id = src_book_id) < 0 THEN
        RAISE EXCEPTION 'Source stock cannot go below zero';
    END IF;

    COMMIT;     -- procedure 內可控制交易!function 不行
END;
$$;

CALL shop.transfer_stock(1, 2, 1);
```

## 11.8 OUT / INOUT 參數

```sql
CREATE OR REPLACE PROCEDURE shop.summarize_book(
    IN  book_id  INT,
    OUT out_title TEXT,
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
     WHERE b.id = book_id
     GROUP BY b.title;
END;
$$;

CALL shop.summarize_book(1, NULL, NULL);
```

## 11.9 RAISE 訊息與例外

```sql
RAISE NOTICE  'Hello %', name;     -- 提示
RAISE WARNING '注意 %', code;
RAISE EXCEPTION '錯誤 %', code USING ERRCODE = 'P0001';
```

## 11.10 修改、刪除

```sql
-- 列出
\df shop.*

-- 看程式碼
\sf shop.price_tier

-- 刪除 (注意 overloaded function 要指定參數型別)
DROP FUNCTION shop.add(INT, INT);
DROP PROCEDURE shop.transfer_stock(INT, INT, INT);
```

## 章節腳本

- [`scripts/01-simple-functions.sql`](./scripts/01-simple-functions.sql)
- [`scripts/02-plpgsql-control-flow.sql`](./scripts/02-plpgsql-control-flow.sql)
- [`scripts/03-procedure-and-transaction.sql`](./scripts/03-procedure-and-transaction.sql)

---

下一章 ➡ [第 12 章:Trigger](../12-triggers/)
