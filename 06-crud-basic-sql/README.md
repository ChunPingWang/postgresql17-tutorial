# 第 6 章 基本 SQL — CRUD

> 目標:熟練 `INSERT` / `SELECT` / `UPDATE` / `DELETE` 四大操作,以及 PostgreSQL 特有的 `RETURNING` 與 `INSERT ... ON CONFLICT` (UPSERT)。
>
> 🧰 **前置準備**:本章範例使用 `bookstore` 資料庫 (`shop` schema 與範例資料)。尚未建立的話,先在 repo 根目錄執行 `psql -d postgres -f setup/01-create-tutorial-db.sql` 與 `psql -d bookstore -f setup/02-sample-data.sql`,詳見[第 1 章 1.8 節](../01-installation/README.md#18-建立教學用資料庫)。

## 6.1 INSERT

```sql
-- 基本
INSERT INTO shop.categories (name, description)
VALUES ('Tech', '科技');

-- 多列一次插入
INSERT INTO shop.categories (name, description) VALUES
    ('Art', '藝術'),
    ('Music', '音樂'),
    ('Sport', '體育');

-- 從另一張表
INSERT INTO archive.books_old
SELECT * FROM shop.books WHERE published_at < '2000-01-01';

-- 用 DEFAULT
INSERT INTO shop.customers (name, email, registered_at)
VALUES ('Test', 't@x.com', DEFAULT);
```

### RETURNING:取得剛插入的資料

```sql
INSERT INTO shop.authors (name, country)
VALUES ('Test Author', 'TW')
RETURNING id, name;
-- 不必再下 SELECT max(id),直接拿到新 id
```

### INSERT ... ON CONFLICT (UPSERT)

```sql
-- 衝突時什麼都不做
INSERT INTO shop.customers (email, name)
VALUES ('alice@x.com', 'Alice2')
ON CONFLICT (email) DO NOTHING;

-- 衝突時改為 UPDATE
INSERT INTO shop.books (isbn, title, price)
VALUES ('978-XXX', 'Title', 100)
ON CONFLICT (isbn) DO UPDATE
SET title = EXCLUDED.title,
    price = EXCLUDED.price,
    updated_at = NOW();
```

`EXCLUDED` 是「假設新值要被插入的那一筆」,可在 DO UPDATE 子句參照。

## 6.2 SELECT

![SELECT 查詢範例](./screenshots/01-select-all-books.png)

```sql
-- 基本
SELECT id, title, price FROM shop.books;

-- 所有欄位 (production 不建議)
SELECT * FROM shop.books;

-- 別名與運算式
SELECT
    title,
    price,
    price * 0.9 AS sale_price,
    stock * price AS inventory_value
FROM shop.books;

-- DISTINCT
SELECT DISTINCT country FROM shop.authors;

-- DISTINCT ON (PostgreSQL 特色:每組保留一筆)
SELECT DISTINCT ON (country) country, name
FROM shop.authors
ORDER BY country, name;
```

### WHERE 條件

![WHERE 過濾條件範例](./screenshots/02-where-clause.png)

```sql
SELECT * FROM shop.books WHERE price > 500;
SELECT * FROM shop.books WHERE price BETWEEN 300 AND 600;
SELECT * FROM shop.books WHERE category_id IN (1, 2);
SELECT * FROM shop.books WHERE category_id NOT IN (3, 4);
SELECT * FROM shop.books WHERE title LIKE '%Programming%';
SELECT * FROM shop.books WHERE title ILIKE '%programming%';  -- 大小寫不敏感
SELECT * FROM shop.books WHERE author_id IS NULL;
SELECT * FROM shop.books WHERE author_id IS NOT NULL;
SELECT * FROM shop.books WHERE published_at >= '2010-01-01';

-- 布林組合
SELECT * FROM shop.books
WHERE (price > 500 OR stock > 20)
  AND category_id = 1;
```

### ORDER BY / LIMIT / OFFSET

```sql
-- 排序
SELECT * FROM shop.books ORDER BY price DESC, title ASC;

-- NULL 順序控制
SELECT * FROM shop.books ORDER BY published_at DESC NULLS LAST;

-- 分頁
SELECT * FROM shop.books
ORDER BY id
LIMIT 10 OFFSET 20;     -- 第 21~30 筆

-- 標準 SQL 寫法 (等價)
SELECT * FROM shop.books
ORDER BY id
OFFSET 20 ROWS FETCH NEXT 10 ROWS ONLY;
```

> ⚠️ `OFFSET` 數字大時效能差。海量分頁請改 keyset 分頁 (見第 18 章)。

## 6.3 UPDATE

![UPDATE 更新資料範例](./screenshots/04-update.png)

```sql
-- 基本
UPDATE shop.books
SET price = price * 1.1
WHERE category_id = 1;

-- 多欄
UPDATE shop.books
SET price = 999, stock = 50, updated_at = NOW()
WHERE id = 1;

-- 用另一張表的資料更新 (FROM 子句)
UPDATE shop.orders o
SET total = sub.total
FROM (
    SELECT order_id, SUM(quantity * unit_price) AS total
    FROM shop.order_items
    GROUP BY order_id
) sub
WHERE sub.order_id = o.id;

-- RETURNING
UPDATE shop.books
SET stock = stock - 1
WHERE id = 1
RETURNING id, title, stock;
```

> ⚠️ 沒寫 `WHERE` 就是全表更新,**先用 `BEGIN; ... ROLLBACK;` 練習較安全**。

## 6.4 DELETE

```sql
-- 基本
DELETE FROM shop.customers WHERE id = 99;

-- 用 JOIN 條件刪 (USING 子句)
DELETE FROM shop.order_items oi
USING shop.orders o
WHERE oi.order_id = o.id
  AND o.status = 'cancelled';

-- RETURNING (拿回被刪資料,常用於審計)
DELETE FROM shop.books
WHERE published_at < '1980-01-01'
RETURNING *;

-- 整表清空 (保留結構,可重設 IDENTITY)
TRUNCATE TABLE temp_stage;
TRUNCATE TABLE shop.orders RESTART IDENTITY CASCADE;
```

`TRUNCATE` vs `DELETE`:
- `TRUNCATE` 更快 (不掃描每列),但**不會觸發 ROW level trigger**
- `TRUNCATE` 隱含 `ACCESS EXCLUSIVE LOCK`,別於高峰期使用

## 6.5 CASE 運算式

```sql
SELECT
    title,
    price,
    CASE
        WHEN price < 400 THEN 'cheap'
        WHEN price < 1000 THEN 'normal'
        ELSE 'expensive'
    END AS price_tier
FROM shop.books;

-- 簡單 CASE
SELECT
    status,
    CASE status
        WHEN 'pending'   THEN '待付款'
        WHEN 'paid'      THEN '已付款'
        WHEN 'shipped'   THEN '已出貨'
        WHEN 'completed' THEN '已完成'
        WHEN 'cancelled' THEN '已取消'
    END AS status_zh
FROM shop.orders;
```

## 6.6 COALESCE / NULLIF / GREATEST / LEAST

```sql
-- COALESCE:回傳第一個非 NULL
SELECT COALESCE(phone, email, 'unknown') AS contact FROM shop.customers;

-- NULLIF:兩值相等回 NULL,常用於避免除 0
SELECT total / NULLIF(quantity, 0) AS avg FROM ...;

-- GREATEST / LEAST:多值取最大/小
SELECT GREATEST(price, sale_price), LEAST(stock, 10) FROM ...;
```

## 6.7 練習

```sql
-- 1) 新增一本書 (有 RETURNING)
INSERT INTO shop.books (title, author_id, category_id, isbn, price, stock, published_at, metadata)
VALUES ('Test Book', 1, 1, '978-TEST', 250.00, 10, '2024-01-01', '{}'::jsonb)
RETURNING id, title;

-- 2) 把所有 pending 訂單改為 cancelled
UPDATE shop.orders SET status = 'cancelled'
WHERE status = 'pending'
RETURNING id, status;

-- 3) 刪除剛才的測試書
DELETE FROM shop.books WHERE isbn = '978-TEST' RETURNING id, title;
```

## 章節腳本

- [`scripts/01-insert-and-returning.sql`](./scripts/01-insert-and-returning.sql)
- [`scripts/02-select-where.sql`](./scripts/02-select-where.sql)
- [`scripts/03-update-delete-upsert.sql`](./scripts/03-update-delete-upsert.sql)

---

下一章 ➡ [第 7 章:JOIN 與子查詢](../07-joins-subqueries/)
