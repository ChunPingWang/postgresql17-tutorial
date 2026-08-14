# 第 5 章 資料表設計與約束

> 目標:能完整定義一張表的結構與約束,避免「先讓資料進去再說」的常見錯誤。
>
> 🧰 **前置準備**:本章範例使用 `bookstore` 資料庫 (`shop` schema 與範例資料)。尚未建立的話,先在 repo 根目錄執行 `psql -d postgres -f setup/01-create-tutorial-db.sql` 與 `psql -d bookstore -f setup/02-sample-data.sql`,詳見[第 1 章 1.8 節](../01-installation/README.md#18-建立教學用資料庫)。

## 5.1 CREATE TABLE 完整語法

```sql
CREATE TABLE [IF NOT EXISTS] [schema.]table_name (
    column_name DATA_TYPE [COLUMN_CONSTRAINT ...],
    ...
    [TABLE_CONSTRAINT, ...]
)
[INHERITS (parent_table)]
[PARTITION BY ...]
[TABLESPACE name]
;
```

## 5.2 約束 (Constraints) 總覽

| 約束 | 用途 |
|------|------|
| `NOT NULL` | 不允許 NULL |
| `DEFAULT` | 預設值 (運算式) |
| `UNIQUE` | 唯一,允許多個 NULL |
| `PRIMARY KEY` | 主鍵 = `UNIQUE` + `NOT NULL` |
| `FOREIGN KEY` | 外鍵 (參照完整性) |
| `CHECK` | 任意條件運算式 |
| `EXCLUDE` | 進階:範圍 / 空間互斥 |

## 5.3 PRIMARY KEY

每張表**強烈建議**有一個 primary key。

```sql
-- 單欄主鍵
CREATE TABLE a (
    id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ...
);

-- 多欄主鍵 (常見於關聯表)
CREATE TABLE order_items (
    order_id INT,
    line_no  INT,
    book_id  INT,
    qty      INT,
    PRIMARY KEY (order_id, line_no)
);
```

**自然鍵 vs 代理鍵**:
- **代理鍵 (Surrogate)**:`id INTEGER IDENTITY`,與業務無關。**推薦**。
- **自然鍵 (Natural)**:如 `email`、`國碼+電話`。簡單但業務變動時痛苦。

## 5.4 FOREIGN KEY

```sql
CREATE TABLE orders (
    id          SERIAL PRIMARY KEY,
    customer_id INT NOT NULL REFERENCES customers(id),
    ...
);
-- 或表級
CREATE TABLE orders (
    id          SERIAL PRIMARY KEY,
    customer_id INT NOT NULL,
    FOREIGN KEY (customer_id) REFERENCES customers(id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT
);
```

**參考動作**:
| 動作 | 父表變動時 |
|------|-----------|
| `NO ACTION` (預設) | 在交易結尾時檢查;有子資料則錯誤 |
| `RESTRICT` | 立即檢查;有子資料則錯誤 |
| `CASCADE` | 連動刪除/更新子資料 |
| `SET NULL` | 子資料外鍵改為 NULL |
| `SET DEFAULT` | 子資料外鍵改為預設值 |

### 何時用 CASCADE / SET NULL?

- **CASCADE**:子資料「沒有父就沒意義」 (如 `order_items` 與 `orders`)
- **SET NULL**:子資料可獨立存在 (如 `books.author_id` 若作者被刪)
- **RESTRICT**:保守,需要明確處理

> ⚠️ 不要把 CASCADE 視為偷懶工具。CASCADE 出錯時很難救。

## 5.5 UNIQUE

```sql
-- 單欄
CREATE TABLE users (
    email VARCHAR(120) UNIQUE
);

-- 多欄組合
CREATE TABLE memberships (
    org_id  INT,
    user_id INT,
    role    TEXT,
    UNIQUE (org_id, user_id)
);

-- 命名約束 (方便後續 DROP)
CREATE TABLE x (
    sku TEXT CONSTRAINT uq_sku UNIQUE
);
```

**部分唯一索引 (PostgreSQL 特色)**:某條件下才唯一。

```sql
-- 同一使用者只能有一筆 active 訂閱
CREATE UNIQUE INDEX uq_user_active_sub
    ON subscriptions(user_id)
    WHERE status = 'active';
```

## 5.6 CHECK

任意布林運算式,違反時拒絕。

```sql
CREATE TABLE products (
    id    SERIAL PRIMARY KEY,
    price NUMERIC(10,2) CHECK (price > 0),
    stock INT NOT NULL DEFAULT 0,
    CHECK (stock >= 0),

    -- 跨欄
    sale_price NUMERIC(10,2),
    CHECK (sale_price IS NULL OR sale_price < price)
);
```

> CHECK **不能參照其他資料表**。要那種驗證請用 trigger。

## 5.7 NOT NULL 與 DEFAULT

```sql
CREATE TABLE events (
    id          BIGSERIAL PRIMARY KEY,
    payload     JSONB        NOT NULL,
    occurred_at TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    status      TEXT         NOT NULL DEFAULT 'pending'
);
```

**好習慣**:可空欄位請刻意設計,並在註解中說明為何允許 NULL。

## 5.8 修改既有資料表

```sql
-- 加欄位
ALTER TABLE books ADD COLUMN summary TEXT;

-- 改型別 (有時需 USING)
ALTER TABLE books ALTER COLUMN price TYPE NUMERIC(12,2);
ALTER TABLE events ALTER COLUMN payload TYPE JSONB USING payload::jsonb;

-- 加/移除預設值
ALTER TABLE books ALTER COLUMN stock SET DEFAULT 0;
ALTER TABLE books ALTER COLUMN stock DROP DEFAULT;

-- 加 NOT NULL
ALTER TABLE books ALTER COLUMN price SET NOT NULL;

-- 加約束
ALTER TABLE books ADD CONSTRAINT chk_price CHECK (price >= 0);
ALTER TABLE books DROP CONSTRAINT chk_price;

-- 改欄位名
ALTER TABLE books RENAME COLUMN summary TO description;

-- 改表名
ALTER TABLE books RENAME TO books_v1;

-- 改 schema
ALTER TABLE shop.books SET SCHEMA archive;

-- 刪除欄位
ALTER TABLE books DROP COLUMN description;

-- 刪除表
DROP TABLE books;
DROP TABLE books CASCADE;   -- 連同依賴的 view/FK 一起刪
```

## 5.9 暫時表 (Temporary Tables)

只在當前 session 存在,session 結束自動消失。常用於 ETL 中介。

```sql
CREATE TEMP TABLE staging AS
SELECT * FROM shop.orders WHERE status = 'pending';

-- 或顯式
CREATE TEMPORARY TABLE staging (
    id INT,
    payload JSONB
) ON COMMIT DROP;     -- 交易結束就刪
```

## 5.10 IDENTITY 重排與 Sequence

```sql
-- 看 sequence 當前值
SELECT pg_get_serial_sequence('shop.books','id');
SELECT last_value FROM shop.books_id_seq;

-- 重設 (在批量匯入後常用)
ALTER SEQUENCE shop.books_id_seq RESTART WITH 1000;

-- 跳號示範
INSERT INTO shop.categories (name) VALUES ('Test');
ROLLBACK;          -- sequence 不會回退,下次仍是下一號
```

## 5.11 完整範例

```sql
DROP TABLE IF EXISTS demo_products CASCADE;
CREATE TABLE demo_products (
    id          INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku         VARCHAR(30) NOT NULL,
    name        TEXT        NOT NULL,
    price       NUMERIC(10,2) NOT NULL,
    stock       INT         NOT NULL DEFAULT 0,
    category_id INT REFERENCES shop.categories(id) ON DELETE SET NULL,
    metadata    JSONB       NOT NULL DEFAULT '{}'::jsonb,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_demo_sku UNIQUE (sku),
    CONSTRAINT chk_price   CHECK (price >= 0),
    CONSTRAINT chk_stock   CHECK (stock >= 0)
);

COMMENT ON TABLE  demo_products       IS '示範:完整定義的產品表';
COMMENT ON COLUMN demo_products.sku   IS '商品料號 (對外公開)';
COMMENT ON COLUMN demo_products.stock IS '當前可售庫存,扣除預留';
```

## 章節腳本

- [`scripts/01-create-with-constraints.sql`](./scripts/01-create-with-constraints.sql)
- [`scripts/02-alter-table.sql`](./scripts/02-alter-table.sql)

---

下一章 ➡ [第 6 章:基本 SQL — CRUD](../06-crud-basic-sql/)
