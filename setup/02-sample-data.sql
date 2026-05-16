-- =====================================================================
-- 範例資料 - 載入示範用書店資料
-- 用法:psql -d bookstore -f setup/02-sample-data.sql
-- =====================================================================

SET search_path TO shop, public;

-- 清空表 (依 FK 順序反向 TRUNCATE)
TRUNCATE shop.order_items, shop.orders, shop.books, shop.authors,
         shop.categories, shop.customers, shop.employees RESTART IDENTITY CASCADE;

-- 分類
INSERT INTO shop.categories (name, description) VALUES
    ('Programming', '程式設計類'),
    ('Database',    '資料庫類'),
    ('Novel',       '小說'),
    ('History',     '歷史'),
    ('Science',     '科普');

-- 作者
INSERT INTO shop.authors (name, email, country, birth_date, bio) VALUES
    ('Donald Knuth',   'knuth@stanford.edu',  'USA',     '1938-01-10', 'TAOCP 作者'),
    ('Bjarne Stroustrup', 'bs@cpp.org',       'Denmark', '1950-12-30', 'C++ 之父'),
    ('Joe Celko',      'celko@sql.com',       'USA',     '1947-06-15', 'SQL 名家'),
    ('Haruki Murakami','haruki@example.com',  'Japan',   '1949-01-12', '日本作家'),
    ('Yuval Harari',   'yuval@example.com',   'Israel',  '1976-02-24', '人類大歷史作者'),
    ('Carl Sagan',     NULL,                  'USA',     '1934-11-09', '宇宙天文學家');

-- 書籍 (含 JSONB metadata)
INSERT INTO shop.books (title, author_id, category_id, isbn, price, stock, published_at, metadata) VALUES
    ('The Art of Computer Programming Vol.1', 1, 1, '978-0201896831',  1500.00, 5,  '1968-01-01', '{"pages":672,"language":"en","tags":["algorithm","classic"]}'),
    ('The C++ Programming Language',          2, 1, '978-0321563842',  1200.00, 10, '2013-05-19', '{"pages":1376,"language":"en","tags":["cpp"]}'),
    ('SQL for Smarties',                      3, 2, '978-0128007617',  900.00,  8,  '2014-12-25', '{"pages":864,"language":"en","tags":["sql","advanced"]}'),
    ('Norwegian Wood',                        4, 3, '978-0375704024',  350.00,  20, '1987-09-04', '{"pages":296,"language":"en","tags":["novel"]}'),
    ('Kafka on the Shore',                    4, 3, '978-1400079278',  420.00,  15, '2002-09-12', '{"pages":505,"language":"en","tags":["novel","fantasy"]}'),
    ('Sapiens',                               5, 4, '978-0062316097',  480.00,  25, '2011-01-01', '{"pages":443,"language":"en","tags":["history","bestseller"]}'),
    ('Homo Deus',                             5, 4, '978-0062464347',  500.00,  18, '2015-09-08', '{"pages":450,"language":"en","tags":["future"]}'),
    ('Cosmos',                                6, 5, '978-0345539434',  380.00,  12, '1980-10-12', '{"pages":396,"language":"en","tags":["astronomy","classic"]}');

-- 客戶
INSERT INTO shop.customers (name, email, phone) VALUES
    ('王小明', 'ming@example.com',   '0911-111-111'),
    ('李美麗', 'mei@example.com',    '0922-222-222'),
    ('陳大文', 'wen@example.com',    '0933-333-333'),
    ('林志玲', 'ling@example.com',   '0944-444-444'),
    ('張三豐', 'sf@example.com',     '0955-555-555');

-- 訂單
INSERT INTO shop.orders (customer_id, status, ordered_at, total) VALUES
    (1, 'completed', NOW() - INTERVAL '30 days',  1850.00),
    (1, 'paid',      NOW() - INTERVAL '5 days',   480.00),
    (2, 'completed', NOW() - INTERVAL '20 days',  900.00),
    (3, 'shipped',   NOW() - INTERVAL '3 days',   770.00),
    (4, 'pending',   NOW() - INTERVAL '1 day',    380.00),
    (5, 'cancelled', NOW() - INTERVAL '10 days',  420.00);

-- 訂單明細
INSERT INTO shop.order_items (order_id, book_id, quantity, unit_price) VALUES
    (1, 1, 1, 1500.00), (1, 4, 1, 350.00),
    (2, 6, 1, 480.00),
    (3, 3, 1, 900.00),
    (4, 6, 1, 480.00), (4, 8, 1, 380.00),  -- Wait, total 770 but 480+380 != 770; adjust
    (5, 8, 1, 380.00),
    (6, 5, 1, 420.00);

-- 修正 order 4 的 total (示範範例,實際應由觸發器維護)
UPDATE shop.orders SET total = 860.00 WHERE id = 4;

-- 員工 (展示主管階層)
INSERT INTO shop.employees (name, role, salary, hired_at, manager_id) VALUES
    ('Alice',  'CEO',           150000, '2018-01-01', NULL),
    ('Bob',    'Engineering Manager', 110000, '2019-03-15', 1),
    ('Carol',  'Sales Manager',  100000, '2019-04-20', 1),
    ('Dave',   'Senior Engineer', 90000, '2020-06-01', 2),
    ('Eve',    'Engineer',        70000, '2021-08-10', 2),
    ('Frank',  'Engineer',        72000, '2022-02-14', 2),
    ('Grace',  'Sales Lead',      75000, '2021-01-05', 3),
    ('Henry',  'Sales',           55000, '2023-05-01', 7);

\echo '✅ 範例資料載入完成'
SELECT
    (SELECT COUNT(*) FROM shop.categories)   AS categories,
    (SELECT COUNT(*) FROM shop.authors)      AS authors,
    (SELECT COUNT(*) FROM shop.books)        AS books,
    (SELECT COUNT(*) FROM shop.customers)    AS customers,
    (SELECT COUNT(*) FROM shop.orders)       AS orders,
    (SELECT COUNT(*) FROM shop.order_items)  AS order_items,
    (SELECT COUNT(*) FROM shop.employees)    AS employees;
