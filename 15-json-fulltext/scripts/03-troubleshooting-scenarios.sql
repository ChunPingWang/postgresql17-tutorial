-- =====================================================================
-- 第 15 章 / 問題排查情境模擬 (對應 README 15.10 節)
-- 用法:psql -d bookstore -f 03-troubleshooting-scenarios.sql
--
-- 每個情境都用自己的 demo 表 (ts_products),跑完會清掉,不影響 bookstore 其他章節。
-- 建議搭配 README 15.10 的「排查順序」逐段執行、對照輸出。
-- 刻意觸發的錯誤都包在 DO ... EXCEPTION 裡,以 NOTICE 顯示 SQLSTATE,不會中斷腳本。
-- =====================================================================
SET search_path TO shop, public;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ---------------------------------------------------------------------
-- 共用測試資料:20 萬筆商品,attrs 是 JSONB (brand / pages / tags / dims)
-- brand 有 1000 種 → 單一品牌約 200 筆,是「索引划算」的選擇度
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS ts_products;
CREATE TABLE ts_products (
    id     SERIAL PRIMARY KEY,
    name   TEXT NOT NULL,
    attrs  JSONB NOT NULL
);
INSERT INTO ts_products (name, attrs)
SELECT 'Product ' || g,
       jsonb_build_object(
           'brand', 'brand' || (g % 1000),                    -- 1000 個品牌,每個約 200 筆 (0.1%)
           'pages', 20 + (g * 7) % 980,                      -- 20 ~ 999
           'tags',  jsonb_build_array('tag' || (g % 50), 'tag' || (g % 7)),
           'dims',  jsonb_build_object('w', g % 100, 'h', g % 60)
       )
FROM generate_series(1, 200000) g;

CREATE INDEX idx_products_attrs_gin ON ts_products USING gin (attrs);
ANALYZE ts_products;

-- =====================================================================
\echo ''
\echo '════ 情境 A:attrs 上有 GIN 索引,查 brand 還是 Seq Scan ════'
-- 症狀:建了 GIN,但「查某個品牌」的查詢 EXPLAIN 是全表掃描
-- =====================================================================

\echo '── A 排查步驟 1:確認索引存在、是 GIN、涵蓋整個 attrs ──'
SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'ts_products';

\echo '── A 排查步驟 2:看執行計畫 (Seq Scan + Filter) ──'
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM ts_products WHERE attrs->>'brand' = 'brand42';

-- 根因:GIN (jsonb_ops) 支援的是 @>、?、?|、?& 這些「包含 / 存在」操作子;
--       attrs->>'brand' 是先把值取出成 text 再比對 =,索引裡沒有這個 text 值可比。

\echo '── A 修正 1:改寫成包含查詢 @> (GIN 能用) ──'
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM ts_products WHERE attrs @> '{"brand":"brand42"}';

\echo '── A 修正 2:查詢非改不可時,對 ->> 表達式建 B-Tree ──'
CREATE INDEX idx_products_brand ON ts_products ((attrs->>'brand'));
ANALYZE ts_products;
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM ts_products WHERE attrs->>'brand' = 'brand42';

\echo '── A 延伸:兩種 GIN 的大小差異 (jsonb_ops vs jsonb_path_ops) ──'
CREATE INDEX idx_products_attrs_pathops ON ts_products USING gin (attrs jsonb_path_ops);
SELECT indexrelname, pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes WHERE relname = 'ts_products' ORDER BY indexrelname;
DROP INDEX idx_products_attrs_pathops;
DROP INDEX idx_products_brand;

-- =====================================================================
\echo ''
\echo '════ 情境 B:數字比較「報錯」或「結果不對」(-> vs ->> 與型別) ════'
-- 症狀:WHERE attrs->'pages' > 500 直接報錯;改成 ->> 不報錯了,但筆數怪怪的
-- =====================================================================

\echo '── B 排查步驟 1:重現錯誤,看 SQLSTATE 與 HINT ──'
DO $$
BEGIN
    PERFORM count(*) FROM ts_products WHERE attrs->'pages' > 500;
    RAISE EXCEPTION '不該執行到這裡';
EXCEPTION WHEN undefined_function THEN
    RAISE NOTICE '預期錯誤 SQLSTATE=% : %', SQLSTATE, SQLERRM;
END$$;

-- 根因 1:-> 回傳的是 jsonb,jsonb 與 integer 之間沒有 > 運算子。

\echo '── B 排查步驟 2:改用 ->> 不報錯,但是 text 比較:''60'' > ''500'' 是 true ──'
SELECT count(*) AS text_compare_count
FROM ts_products WHERE attrs->>'pages' > '500';

SELECT '60' > '500' AS text_60_gt_500, 60 > 500 AS int_60_gt_500;

\echo '── B 修正:明確轉型後比較 (或用 jsonb 對 jsonb 的數值比較) ──'
SELECT count(*) AS int_compare_count
FROM ts_products WHERE (attrs->>'pages')::INT > 500;

SELECT count(*) AS jsonb_compare_count
FROM ts_products WHERE attrs->'pages' > '500'::jsonb;

\echo '── B 驗證:兩種正確寫法筆數一致,且與 text 比較不同 ──'
SELECT
    (SELECT count(*) FROM ts_products WHERE attrs->>'pages' > '500')          AS text_compare,
    (SELECT count(*) FROM ts_products WHERE (attrs->>'pages')::INT > 500)     AS int_compare,
    (SELECT count(*) FROM ts_products WHERE attrs->'pages' > '500'::jsonb)    AS jsonb_compare;

\echo '── B 延伸:轉型遇到髒資料會炸 (key 缺少 → NULL 沒事;值不是數字 → 22P02) ──'
DO $$
BEGIN
    PERFORM ('{"pages":"n/a"}'::jsonb->>'pages')::INT;
EXCEPTION WHEN invalid_text_representation THEN
    RAISE NOTICE '預期錯誤 SQLSTATE=% : %', SQLSTATE, SQLERRM;
END$$;
-- 防禦:先用 jsonb_typeof 過濾
SELECT jsonb_typeof('{"pages":"n/a"}'::jsonb->'pages') AS typeof_text,
       jsonb_typeof('{"pages":42}'::jsonb->'pages')    AS typeof_number;

-- =====================================================================
\echo ''
\echo '════ 情境 C:全文搜尋找不到明明存在的字 (設定不一致 / 中文) ════'
-- 症狀:文件裡明明有 "databases",搜 "databases" 卻 0 筆
-- =====================================================================
DROP TABLE IF EXISTS ts_docs;
CREATE TABLE ts_docs (
    id    SERIAL PRIMARY KEY,
    body  TEXT NOT NULL,
    -- 某位開發者當初用 'simple' 建了 tsvector 欄位 (不做詞幹處理)
    tsv   tsvector GENERATED ALWAYS AS (to_tsvector('simple', body)) STORED
);
INSERT INTO ts_docs (body) VALUES
    ('PostgreSQL powers modern databases'),
    ('Relational databases are everywhere'),
    ('PostgreSQL資料庫教學,從安裝到效能調校'),
    ('資料庫 索引 與 查詢 最佳化');

\echo '── C 症狀:搜 databases → 0 筆 ──'
SELECT count(*) AS hits FROM ts_docs
WHERE tsv @@ to_tsquery('english', 'databases');

\echo '── C 排查步驟 1:把儲存端與查詢端的 token 印出來對照 ──'
SELECT to_tsvector('simple',  'Relational databases are everywhere') AS stored_simple,
       to_tsquery('english', 'databases')                            AS query_english;

\echo '── C 排查步驟 2:確認欄位用的是哪個 config (看 generated 定義) ──'
SELECT pg_get_expr(adbin, adrelid) AS generated_expr
FROM pg_attrdef WHERE adrelid = 'ts_docs'::regclass;

-- 根因:'simple' 存的是原字 'databases','english' 把查詢詞幹化成 'databas',
--       兩邊 token 不同,永遠對不上。儲存與查詢的 config 必須一致。

\echo '── C 修正:查詢端改用同一個 config (立即可用) ──'
SELECT count(*) AS hits_simple FROM ts_docs
WHERE tsv @@ to_tsquery('simple', 'databases');

\echo '── C 修正 (根本):欄位改成 english,並在查詢端固定用 english ──'
ALTER TABLE ts_docs DROP COLUMN tsv;
ALTER TABLE ts_docs ADD COLUMN tsv tsvector
    GENERATED ALWAYS AS (to_tsvector('english', body)) STORED;
CREATE INDEX idx_docs_tsv ON ts_docs USING gin (tsv);
-- 詞幹化後 database / databases 都能命中
SELECT id, body FROM ts_docs WHERE tsv @@ to_tsquery('english', 'database');

\echo '── C-2 症狀:兩篇文件都含「資料庫」,全文搜尋只找到一篇 ──'
SELECT id, body FROM ts_docs WHERE body LIKE '%資料庫%';          -- 事實:2 篇
SELECT id, body FROM ts_docs WHERE tsv @@ to_tsquery('english', '資料庫');  -- FTS:只有 1 篇

\echo '── C-2 排查:看 parser 把中文切成什麼 ──'
SELECT to_tsvector('english', 'PostgreSQL資料庫教學,從安裝到效能調校') AS zh_no_space,
       to_tsvector('english', '資料庫 索引 與 查詢 最佳化')            AS zh_with_space;

-- 根因:內建 parser 不會斷中文詞,只能靠空白/標點切;沒有空白的整句變成一個 token,
--       搜「資料庫」自然對不上。要中文分詞得裝 zhparser / pg_jieba,
--       或改用 pg_trgm 做子字串比對 (不需分詞)。

\echo '── C-2 修正:pg_trgm GIN + ILIKE,中文英文都能子字串命中 ──'
CREATE INDEX idx_docs_body_trgm ON ts_docs USING gin (body gin_trgm_ops);
SELECT id, body FROM ts_docs WHERE body ILIKE '%資料庫%';
-- 表只有 4 列,planner 當然選 Seq Scan;暫時關掉 seqscan 只是為了證明索引「能用」
BEGIN;
SET LOCAL enable_seqscan = off;
EXPLAIN (COSTS OFF) SELECT id FROM ts_docs WHERE body ILIKE '%資料庫%';
ROLLBACK;

-- =====================================================================
\echo ''
\echo '════ 情境 D:jsonb_set 「沒生效」、|| 把巢狀物件整個蓋掉 ════'
-- 症狀:UPDATE 回報 UPDATE 1,但 JSON 沒變;另一個 UPDATE 後 dims 裡的 w 不見了
-- =====================================================================

\echo '── D-1 症狀:對不存在的巢狀路徑 jsonb_set → 原樣回傳 (沒有錯誤) ──'
SELECT jsonb_set('{"name":"x"}'::jsonb, '{dims,h}', '10') AS unchanged;

-- 根因:jsonb_set 只會在「父路徑存在」時建立最後一層 key (create_missing 預設 true
--       只管最後一層);父物件 dims 不存在就整個略過,而且不報錯。

\echo '── D-1 修正:先確保父物件存在,再 set;或用 || 建父物件 ──'
SELECT jsonb_set(
           jsonb_set('{"name":"x"}'::jsonb, '{dims}', '{}', true),
           '{dims,h}', '10', true)                                          AS fixed_nested,
       '{"name":"x"}'::jsonb || '{"dims":{"h":10}}'                          AS fixed_concat;

\echo '── D-2 症狀:用 || 更新 dims.h,結果 dims.w 消失 ──'
SELECT attrs->'dims' AS before_dims FROM ts_products WHERE id = 1;
BEGIN;
UPDATE ts_products SET attrs = attrs || '{"dims":{"h":99}}' WHERE id = 1;
SELECT attrs->'dims' AS after_shallow_merge FROM ts_products WHERE id = 1;
ROLLBACK;

-- 根因:|| 是「淺合併」— 同名頂層 key 直接以右邊取代,不會遞迴合併子物件。

\echo '── D-2 修正:改路徑更新 jsonb_set,或對子物件做 || 後放回 ──'
BEGIN;
UPDATE ts_products SET attrs = jsonb_set(attrs, '{dims,h}', '99') WHERE id = 1;
SELECT attrs->'dims' AS after_jsonb_set FROM ts_products WHERE id = 1;
ROLLBACK;
BEGIN;
UPDATE ts_products
SET attrs = attrs || jsonb_build_object('dims', (attrs->'dims') || '{"h":99}')
WHERE id = 1;
SELECT attrs->'dims' AS after_child_merge FROM ts_products WHERE id = 1;
ROLLBACK;

\echo '── D 延伸:JSONB 的更新成本 — 改一個 key 也是整個值重寫,GIN 還要跟著重建 ──'
\echo '── (1) 有 GIN 索引時更新 5 萬列 ──'
EXPLAIN (ANALYZE, BUFFERS)
UPDATE ts_products SET attrs = jsonb_set(attrs, '{dims,h}', '1') WHERE id <= 50000;
\echo '── (2) 拿掉 GIN 後更新另外 5 萬列 ──'
DROP INDEX idx_products_attrs_gin;
EXPLAIN (ANALYZE, BUFFERS)
UPDATE ts_products SET attrs = jsonb_set(attrs, '{dims,h}', '1') WHERE id > 50000 AND id <= 100000;
-- 結論:JSONB 欄位頻繁更新的表,GIN 的維護成本會非常明顯;
--       常改的 key 應該升格成一般欄位,而不是留在 JSONB 裡。

-- ---------------------------------------------------------------------
-- 清理
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS ts_docs;
DROP TABLE IF EXISTS ts_products;
\echo ''
\echo '✅ 情境模擬完成 (demo 表已清除)'
