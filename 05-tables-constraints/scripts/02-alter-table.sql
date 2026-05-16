-- =====================================================================
-- 第 5 章 / ALTER TABLE 各種變更示範
-- =====================================================================

SET search_path TO shop, public;

DROP TABLE IF EXISTS alter_demo;
CREATE TABLE alter_demo (
    id   SERIAL PRIMARY KEY,
    name TEXT
);

INSERT INTO alter_demo (name) VALUES ('a'), ('b');

-- 1. 加欄位 (可帶 DEFAULT,既有資料會被填上)
ALTER TABLE alter_demo ADD COLUMN status TEXT NOT NULL DEFAULT 'active';

-- 2. 改型別
ALTER TABLE alter_demo ALTER COLUMN status TYPE VARCHAR(20);

-- 3. 加 CHECK
ALTER TABLE alter_demo
    ADD CONSTRAINT chk_status CHECK (status IN ('active','inactive','deleted'));

-- 4. 改欄位預設值
ALTER TABLE alter_demo ALTER COLUMN status SET DEFAULT 'inactive';

-- 5. 加註解
COMMENT ON TABLE alter_demo IS '示範 ALTER TABLE 的測試表';
COMMENT ON COLUMN alter_demo.status IS '狀態:active / inactive / deleted';

-- 6. 改欄位名與表名
ALTER TABLE alter_demo RENAME COLUMN status TO state;
ALTER TABLE alter_demo RENAME TO alter_demo_v2;

-- 7. 看最終結果
\d shop.alter_demo_v2

-- 8. 取消約束 / 還原
ALTER TABLE alter_demo_v2 DROP CONSTRAINT chk_status;
ALTER TABLE alter_demo_v2 RENAME COLUMN state TO status;

-- 9. 暫時表 (session 結束自動消失)
CREATE TEMP TABLE temp_stage AS
SELECT id, title FROM shop.books WHERE price > 500;
SELECT count(*) FROM temp_stage;

DROP TABLE alter_demo_v2;
