-- =====================================================================
-- 第 5 章 / 問題排查情境模擬 (對應 README 5.12 節)
-- 用法:psql -d bookstore -f 03-troubleshooting-scenarios.sql
--
-- 每個情境都用自己的 demo 表 (前綴 ts_),跑完會清掉,不影響 bookstore 其他章節。
-- 建議搭配 README 5.12 的「排查順序」逐段執行、對照輸出。
-- 注意:情境 D 會刻意出現 2 個 ERROR (ALTER TABLE 失敗),那是情境的一部分。
-- =====================================================================
SET search_path TO shop, public;

DROP TABLE IF EXISTS ts_comments, ts_tasks, ts_projects, ts_orgs,
                     ts_books, ts_authors, ts_users, ts_products CASCADE;

-- =====================================================================
\echo ''
\echo '════ 情境 A:DELETE 父資料被擋 — violates foreign key constraint ════'
-- 症狀:客服要刪一位作者,得到 ERROR: update or delete on table "ts_authors"
--       violates foreign key constraint ... on table "ts_books"
-- =====================================================================
CREATE TABLE ts_authors (
    id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name TEXT NOT NULL
);
CREATE TABLE ts_books (
    id        INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title     TEXT NOT NULL,
    author_id INT NOT NULL REFERENCES ts_authors(id)      -- 預設 NO ACTION
);
INSERT INTO ts_authors (name) VALUES ('Alice'), ('Bob');
INSERT INTO ts_books (title, author_id) VALUES ('A1', 1), ('A2', 1), ('B1', 2);

\echo '── A 重現:刪掉還有書的作者 (錯誤被 DO 區塊接住,原文印在 NOTICE) ──'
DO $$
DECLARE v_detail TEXT;
BEGIN
    DELETE FROM ts_authors WHERE id = 1;
    RAISE EXCEPTION '預期失敗未發生';
EXCEPTION WHEN foreign_key_violation THEN
    GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
    RAISE NOTICE '被攔下:%', SQLERRM;
    RAISE NOTICE 'DETAIL:%', v_detail;
END$$;

\echo '── A 排查步驟 1:誰在參照這張表?(錯誤訊息只列第一個,實際可能有很多張) ──'
SELECT conname                        AS constraint_name,
       conrelid::regclass             AS child_table,
       pg_get_constraintdef(oid)      AS definition
FROM pg_constraint
WHERE contype = 'f' AND confrelid = 'ts_authors'::regclass;

\echo '── A 排查步驟 2:這位作者到底有幾筆子資料? ──'
SELECT count(*) AS dependent_books FROM ts_books WHERE author_id = 1;

-- 根因:FK 預設 ON DELETE NO ACTION — 有子資料就拒絕。這是約束在保護你,不是 bug;
--       該問的是「業務上刪作者時,書該怎麼辦」,答案決定修正方式。

\echo '── A 修正 1 (子資料應保留,改成沒有作者):把 FK 改為 ON DELETE SET NULL ──'
ALTER TABLE ts_books ALTER COLUMN author_id DROP NOT NULL;
ALTER TABLE ts_books DROP CONSTRAINT ts_books_author_id_fkey;
ALTER TABLE ts_books ADD CONSTRAINT ts_books_author_id_fkey
    FOREIGN KEY (author_id) REFERENCES ts_authors(id) ON DELETE SET NULL;
DELETE FROM ts_authors WHERE id = 1;

\echo '── A 驗證:作者刪掉了,書還在、author_id 變 NULL ──'
SELECT id, title, author_id FROM ts_books ORDER BY id;

-- 修正 2 (子資料沒有父就沒意義):ON DELETE CASCADE — 但先看情境 C 再決定
-- 修正 3 (保守):不改 FK,應用程式先處理子資料再刪父,或改成軟刪除 (deleted_at)

-- =====================================================================
\echo ''
\echo '════ 情境 B:明明有 UNIQUE,資料還是重複了 ════'
-- 症狀:email 欄位有 UNIQUE,報表卻出現同一個人兩筆;sku 也有 UNIQUE,卻有多筆「空的」
-- =====================================================================
CREATE TABLE ts_users (
    id    INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email TEXT UNIQUE,
    sku   TEXT UNIQUE
);
INSERT INTO ts_users (email, sku) VALUES
    ('alice@example.com', 'SKU-1'),
    ('Alice@Example.com', 'SKU-2'),     -- 大小寫不同,UNIQUE 認為是不同值
    (NULL, NULL),
    (NULL, NULL);                       -- NULL 不等於 NULL,UNIQUE 預設放行

\echo '── B 排查步驟 1:約束確實存在 ──'
SELECT conname, pg_get_constraintdef(oid) AS definition
FROM pg_constraint WHERE conrelid = 'ts_users'::regclass AND contype = 'u';

\echo '── B 排查步驟 2:用「業務上的相等」找重複 — 忽略大小寫 ──'
SELECT LOWER(email) AS normalized_email, count(*)
FROM ts_users WHERE email IS NOT NULL
GROUP BY LOWER(email) HAVING count(*) > 1;

\echo '── B 排查步驟 3:NULL 有幾筆? ──'
SELECT count(*) FILTER (WHERE email IS NULL) AS null_emails,
       count(*) FILTER (WHERE sku   IS NULL) AS null_skus
FROM ts_users;

-- 根因:UNIQUE 比的是「值完全相等」。(1) 'alice' 與 'Alice' 是不同字串;
--       (2) SQL 標準裡 NULL 不等於任何值 (含 NULL),所以多個 NULL 不算重複。
--       約束沒壞,是它定義的「唯一」跟業務想的不一樣。

\echo '── B 修正 1:先清資料 (合併/刪除重複),否則新約束建不起來 ──'
DELETE FROM ts_users WHERE email = 'Alice@Example.com';
DELETE FROM ts_users WHERE id IN (SELECT id FROM ts_users WHERE sku IS NULL ORDER BY id OFFSET 1);

\echo '── B 修正 2:大小寫不敏感的唯一 → 對 LOWER(email) 建唯一索引 ──'
CREATE UNIQUE INDEX uq_ts_users_email_ci ON ts_users (LOWER(email));

\echo '── B 修正 3:NULL 也要視為同一值 → UNIQUE NULLS NOT DISTINCT (PG 15+) ──'
ALTER TABLE ts_users DROP CONSTRAINT ts_users_sku_key;
ALTER TABLE ts_users ADD CONSTRAINT ts_users_sku_key UNIQUE NULLS NOT DISTINCT (sku);

\echo '── B 驗證:兩種重複現在都被攔下 ──'
DO $$
BEGIN
    BEGIN
        INSERT INTO ts_users (email) VALUES ('ALICE@example.com');
        RAISE EXCEPTION '預期失敗未發生';
    EXCEPTION WHEN unique_violation THEN
        RAISE NOTICE '✅ 大小寫不同的 email 被攔下:%', SQLERRM;
    END;
    BEGIN
        INSERT INTO ts_users (sku) VALUES (NULL);
        RAISE EXCEPTION '預期失敗未發生';
    EXCEPTION WHEN unique_violation THEN
        RAISE NOTICE '✅ 第二個 NULL sku 被攔下:%', SQLERRM;
    END;
END$$;

-- =====================================================================
\echo ''
\echo '════ 情境 C:刪一筆,消失了幾千筆 — CASCADE 連鎖範圍超出預期 ════'
-- 症狀:刪除一個「測試用組織」,結果 tasks 與 comments 少了一大片,沒有任何警告
-- =====================================================================
CREATE TABLE ts_orgs     (id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY, name TEXT NOT NULL);
CREATE TABLE ts_projects (id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                          org_id INT NOT NULL REFERENCES ts_orgs(id) ON DELETE CASCADE, name TEXT);
CREATE TABLE ts_tasks    (id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                          project_id INT NOT NULL REFERENCES ts_projects(id) ON DELETE CASCADE, title TEXT);
CREATE TABLE ts_comments (id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                          task_id INT NOT NULL REFERENCES ts_tasks(id) ON DELETE CASCADE, body TEXT);

INSERT INTO ts_orgs (name) VALUES ('Acme'), ('Globex');
INSERT INTO ts_projects (org_id, name) SELECT 1, 'P' || g FROM generate_series(1, 10) g;
INSERT INTO ts_projects (org_id, name) SELECT 2, 'Q' || g FROM generate_series(1, 10) g;
INSERT INTO ts_tasks (project_id, title) SELECT p.id, 'T' || g FROM ts_projects p, generate_series(1, 100) g;
INSERT INTO ts_comments (task_id, body) SELECT t.id, 'c' || g FROM ts_tasks t, generate_series(1, 5) g;

\echo '── C 排查步驟 1:刪之前先看 CASCADE 鏈會延伸到哪裡 (遞迴走 pg_constraint) ──'
WITH RECURSIVE chain AS (
    SELECT 'ts_orgs'::regclass AS parent, conrelid AS child, confdeltype, 1 AS depth
    FROM pg_constraint WHERE contype = 'f' AND confrelid = 'ts_orgs'::regclass
    UNION ALL
    SELECT c.child, p.conrelid, p.confdeltype, c.depth + 1
    FROM chain c JOIN pg_constraint p ON p.contype = 'f' AND p.confrelid = c.child
)
SELECT repeat('  ', depth - 1) || child::regclass::text AS cascade_path,
       CASE confdeltype WHEN 'c' THEN 'CASCADE' WHEN 'n' THEN 'SET NULL'
                        WHEN 'r' THEN 'RESTRICT' WHEN 'a' THEN 'NO ACTION' END AS on_delete
FROM chain ORDER BY depth;

\echo '── C 排查步驟 2:在交易裡試刪,看各表少了幾列,再 ROLLBACK ──'
SELECT (SELECT count(*) FROM ts_projects) AS projects,
       (SELECT count(*) FROM ts_tasks)    AS tasks,
       (SELECT count(*) FROM ts_comments) AS comments;
BEGIN;
DELETE FROM ts_orgs WHERE name = 'Acme';
SELECT (SELECT count(*) FROM ts_projects) AS projects_after,
       (SELECT count(*) FROM ts_tasks)    AS tasks_after,
       (SELECT count(*) FROM ts_comments) AS comments_after;
ROLLBACK;

-- 根因:每一層 FK 都是 ON DELETE CASCADE,刪 1 筆 org → 10 projects → 1000 tasks → 5000 comments,
--       PostgreSQL 只回報最上層的 DELETE 1,連鎖刪掉的列數不會出現在任何訊息裡。

\echo '── C 修正:在「跨業務邊界」那一層改用 RESTRICT,強迫呼叫端明確處理 ──'
ALTER TABLE ts_projects DROP CONSTRAINT ts_projects_org_id_fkey;
ALTER TABLE ts_projects ADD CONSTRAINT ts_projects_org_id_fkey
    FOREIGN KEY (org_id) REFERENCES ts_orgs(id) ON DELETE RESTRICT;

\echo '── C 驗證:再刪 org 會被擋下,資料完好 ──'
DO $$
BEGIN
    DELETE FROM ts_orgs WHERE name = 'Acme';
    RAISE EXCEPTION '預期失敗未發生';
EXCEPTION WHEN foreign_key_violation THEN
    RAISE NOTICE '✅ RESTRICT 攔下:%', SQLERRM;
END$$;
SELECT (SELECT count(*) FROM ts_projects) AS projects,
       (SELECT count(*) FROM ts_tasks)    AS tasks,
       (SELECT count(*) FROM ts_comments) AS comments;

-- =====================================================================
\echo ''
\echo '════ 情境 D:對既有大表補約束失敗 — 髒資料與鎖表 ════'
-- 症狀:上線後想補 FK 與 NOT NULL,ALTER TABLE 直接報錯;
--       改在離峰硬跑又鎖住整張表好幾秒,線上寫入全部卡住
-- =====================================================================
CREATE TABLE ts_products (
    id          INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku         TEXT,
    category_id INT           -- 早期沒加 FK,也沒 NOT NULL
);
-- 20 萬列;其中 0.1% category_id 指向不存在的分類 (999),另有一些 sku 是 NULL
INSERT INTO ts_products (sku, category_id)
SELECT CASE WHEN g % 5000 = 0 THEN NULL ELSE 'SKU-' || g END,
       CASE WHEN g % 1000 = 0 THEN 999 ELSE 1 + (g % 5) END
FROM generate_series(1, 200000) g;

\echo '── D 重現 1:補 FK 失敗 (下面這個 ERROR 是預期的) ──'
ALTER TABLE ts_products ADD CONSTRAINT ts_products_category_fkey
    FOREIGN KEY (category_id) REFERENCES shop.categories(id);

\echo '── D 重現 2:補 NOT NULL 失敗 (下面這個 ERROR 是預期的) ──'
ALTER TABLE ts_products ALTER COLUMN sku SET NOT NULL;

\echo '── D 排查步驟 1:找孤兒列 — 指向不存在父資料的列有幾筆、是哪些值 ──'
SELECT p.category_id, count(*) AS orphan_rows
FROM ts_products p
LEFT JOIN shop.categories c ON c.id = p.category_id
WHERE c.id IS NULL
GROUP BY p.category_id;

\echo '── D 排查步驟 2:NULL 有幾筆 ──'
SELECT count(*) AS null_skus FROM ts_products WHERE sku IS NULL;

-- 根因:約束只在「加上去的那一刻」對全表檢查一次,既有髒資料一筆就失敗。
--       而且 ADD CONSTRAINT 檢查期間持有 SHARE ROW EXCLUSIVE 鎖,20 萬列還好,
--       2 億列就是線上寫入卡好幾分鐘。

\echo '── D 修正 1:先修資料 (孤兒改指向合理值或 NULL;NULL sku 補值) ──'
UPDATE ts_products SET category_id = NULL WHERE category_id = 999;
UPDATE ts_products SET sku = 'UNKNOWN-' || id WHERE sku IS NULL;

\echo '── D 修正 2:FK 用 NOT VALID 先掛上 (只擋新資料,幾乎不鎖),再另外 VALIDATE ──'
\timing on
ALTER TABLE ts_products ADD CONSTRAINT ts_products_category_fkey
    FOREIGN KEY (category_id) REFERENCES shop.categories(id) NOT VALID;
-- VALIDATE 只取 SHARE UPDATE EXCLUSIVE 鎖,線上讀寫不受影響
ALTER TABLE ts_products VALIDATE CONSTRAINT ts_products_category_fkey;
\timing off

\echo '── D 修正 3:NOT NULL 用 CHECK ... NOT VALID 過渡 (PG 12+ 之後可直接 SET NOT NULL 免全表掃描) ──'
ALTER TABLE ts_products ADD CONSTRAINT ts_products_sku_not_null
    CHECK (sku IS NOT NULL) NOT VALID;
ALTER TABLE ts_products VALIDATE CONSTRAINT ts_products_sku_not_null;
ALTER TABLE ts_products ALTER COLUMN sku SET NOT NULL;   -- 有已驗證的 CHECK,這步不再掃表
ALTER TABLE ts_products DROP CONSTRAINT ts_products_sku_not_null;

\echo '── D 驗證:約束都在、convalidated = true ──'
SELECT conname, contype, convalidated FROM pg_constraint
WHERE conrelid = 'ts_products'::regclass ORDER BY conname;
SELECT attname, attnotnull FROM pg_attribute
WHERE attrelid = 'ts_products'::regclass AND attname = 'sku';

-- ---------------------------------------------------------------------
-- 清理
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS ts_comments, ts_tasks, ts_projects, ts_orgs,
                     ts_books, ts_authors, ts_users, ts_products CASCADE;
\echo ''
\echo '✅ 情境模擬完成 (demo 表已清除)'
