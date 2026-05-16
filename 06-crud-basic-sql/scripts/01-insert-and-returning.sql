-- =====================================================================
-- 第 6 章 / INSERT 與 RETURNING、UPSERT
-- =====================================================================
SET search_path TO shop, public;

-- 確保不會污染原資料
BEGIN;

-- 1) 單筆插入 + RETURNING
INSERT INTO authors (name, country, birth_date)
VALUES ('Test Author A', 'TW', '1980-01-01')
RETURNING id, name;

-- 2) 多筆插入
INSERT INTO authors (name, country) VALUES
    ('Test B', 'JP'),
    ('Test C', 'KR'),
    ('Test D', 'US')
RETURNING id, name, country;

-- 3) INSERT ... SELECT (從現有表拷貝)
CREATE TEMP TABLE local_books AS
SELECT id, title, price FROM books WHERE price < 500;
SELECT count(*) FROM local_books;

-- 4) UPSERT — 衝突時 DO NOTHING
INSERT INTO customers (email, name)
VALUES ('ming@example.com', 'Ming (重複)')
ON CONFLICT (email) DO NOTHING
RETURNING id;       -- 應該不會傳回任何列

-- 5) UPSERT — 衝突時 DO UPDATE
INSERT INTO customers (email, name, phone)
VALUES ('ming@example.com', '王小明 v2', '0911-999-999')
ON CONFLICT (email) DO UPDATE
SET name  = EXCLUDED.name,
    phone = EXCLUDED.phone
RETURNING id, name, phone;

-- 還原避免影響後續章節
ROLLBACK;

\echo '✅ INSERT/UPSERT 練習完成 (已 ROLLBACK,資料庫狀態不變)'
