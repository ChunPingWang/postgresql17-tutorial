# 第 15 章 JSON / JSONB 與全文搜尋

> 目標:用 JSONB 操作非結構化資料,用 `tsvector` / `tsquery` 做全文搜尋。

## 15.1 JSON vs JSONB

| 特性 | JSON | JSONB |
|------|------|-------|
| 儲存 | 文字 (原始) | 二進位解析 |
| 空白/順序 | 保留 | 不保留 |
| 重複 key | 保留 | 後者覆蓋前者 |
| 索引支援 | ❌ | ✅ GIN |
| 查詢速度 | 慢 (每次重解析) | 快 |
| 寫入速度 | 略快 | 略慢 |

**結論:永遠用 JSONB**,除非你要原始格式保留。

## 15.2 JSONB 操作子

| 操作子 | 說明 | 範例 |
|--------|------|------|
| `->` | 取 JSON 子元素 (回 JSONB) | `data->'name'` |
| `->>` | 取 JSON 子元素 (回 TEXT) | `data->>'name'` |
| `#>` | 路徑取值 (回 JSONB) | `data#>'{addr,city}'` |
| `#>>` | 路徑取值 (回 TEXT) | `data#>>'{addr,city}'` |
| `?` | key 是否存在 | `data ? 'age'` |
| `?|` | 任一 key 存在 | `data ?| ARRAY['a','b']` |
| `?&` | 全部 key 存在 | `data ?& ARRAY['a','b']` |
| `@>` | 包含 (left ⊇ right) | `data @> '{"age":30}'` |
| `<@` | 被包含 (left ⊆ right) | `'{"x":1}' <@ data` |
| `\|\|` | 合併 | `data \|\| '{"new":1}'` |
| `-` | 刪除 key / 索引 | `data - 'key'` |
| `#-` | 刪除路徑 | `data #- '{addr,city}'` |

## 15.3 建立與查詢 JSONB

```sql
-- 查詢 books 的 metadata (已在 setup 建好)
SELECT title,
       metadata->>'language'      AS lang,
       metadata->'tags'           AS tags,
       metadata->'tags'->0        AS first_tag,
       (metadata->>'pages')::INT  AS pages
FROM shop.books
WHERE metadata @> '{"language":"en"}';
```

## 15.4 更新 JSONB

```sql
-- jsonb_set(target, path, new_value)
UPDATE shop.books
SET metadata = jsonb_set(metadata, '{pages}', '700')
WHERE id = 1;

-- 合併新欄位
UPDATE shop.books
SET metadata = metadata || '{"edition":4}'::jsonb
WHERE id = 1;

-- 刪除 key
UPDATE shop.books
SET metadata = metadata - 'edition'
WHERE id = 1;
```

## 15.5 JSONB 函數

```sql
jsonb_each(jsonb)                 -- 展開 key-value
jsonb_each_text(jsonb)            -- key-value 都是 TEXT
jsonb_object_keys(jsonb)          -- 列出所有 key
jsonb_array_elements(jsonb)       -- 展開 JSON 陣列
jsonb_array_length(jsonb)         -- 陣列長度
jsonb_strip_nulls(jsonb)          -- 刪除 null 的 key
jsonb_build_object(k,v, ...)      -- 建立 JSON 物件
jsonb_agg(expr)                   -- 聚合成 JSON 陣列
json_build_array(v1, v2, ...)     -- 建立 JSON 陣列
to_jsonb(anyelement)              -- 轉成 JSONB
```

## 15.6 JSONB 索引

```sql
-- GIN 全欄位索引 (支援 @>、?、?|、?&)
CREATE INDEX idx_meta_gin ON shop.books USING gin (metadata);

-- GIN 對特定路徑
CREATE INDEX idx_meta_tags ON shop.books USING gin ((metadata->'tags'));

-- B-Tree 對特定 key (轉成 text)
CREATE INDEX idx_meta_lang ON shop.books ((metadata->>'language'));
```

## 15.7 全文搜尋

### 基礎型別

```sql
-- tsvector:文件的索引表示
SELECT to_tsvector('english', 'PostgreSQL is a powerful database system');
-- 'databas':5 'postgresql':1 'power':4 'system':6

-- tsquery:搜尋條件
SELECT to_tsquery('english', 'powerful & database');
SELECT plainto_tsquery('english', 'powerful database');    -- 自動 &
SELECT websearch_to_tsquery('english', '"full text" -boring'); -- 引號 + 排除
```

### 比對操作子 `@@`

```sql
SELECT to_tsvector('english', 'PostgreSQL is a powerful database')
       @@ to_tsquery('english', 'powerful');   -- t

SELECT title FROM shop.books
WHERE to_tsvector('english', title) @@ websearch_to_tsquery('english', 'programming');
```

### 建立 tsvector 欄位 (效能用)

```sql
ALTER TABLE shop.books ADD COLUMN IF NOT EXISTS tsv tsvector
    GENERATED ALWAYS AS (
        to_tsvector('english', COALESCE(title, '') || ' ' ||
                    COALESCE((metadata->>'tags')::text, ''))
    ) STORED;

CREATE INDEX idx_books_tsv ON shop.books USING gin (tsv);

-- 使用
SELECT title FROM shop.books
WHERE tsv @@ websearch_to_tsquery('english', 'classic algorithm');
```

### ts_rank — 相關性排序

```sql
SELECT
    title,
    ts_rank(to_tsvector('english', title), q) AS rank
FROM shop.books,
     websearch_to_tsquery('english', 'programming') AS q
WHERE to_tsvector('english', title) @@ q
ORDER BY rank DESC;
```

### 關鍵字標示 (Headline)

```sql
SELECT
    title,
    ts_headline('english', title,
                websearch_to_tsquery('english', 'programming'),
                'StartSel=<b>, StopSel=</b>')
FROM shop.books
WHERE tsv @@ websearch_to_tsquery('english', 'programming');
```

## 15.8 pg_trgm — 模糊相似度搜尋

`pg_trgm` 把字串拆成 3-gram,支援 `%` 相似度搜尋與 `LIKE/ILIKE` 索引。

```sql
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX idx_books_title_trgm ON shop.books USING gin (title gin_trgm_ops);

-- 相似度搜尋
SELECT title, similarity(title, 'programing') AS sim  -- 拼錯也能找到
FROM shop.books
WHERE title % 'programing'
ORDER BY sim DESC;
```

## 章節腳本

- [`scripts/01-jsonb-operations.sql`](./scripts/01-jsonb-operations.sql)
- [`scripts/02-fulltext-search.sql`](./scripts/02-fulltext-search.sql)

---

下一章 ➡ [第 16 章:角色與權限](../16-roles-permissions/)
