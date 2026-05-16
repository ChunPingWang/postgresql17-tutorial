-- =====================================================================
-- 第 5 章 / 建立含完整約束的表
-- psql -d bookstore -f 01-create-with-constraints.sql
-- =====================================================================

SET search_path TO shop, public;

DROP TABLE IF EXISTS demo_products CASCADE;
DROP TABLE IF EXISTS demo_memberships CASCADE;
DROP TABLE IF EXISTS demo_orgs CASCADE;
DROP TABLE IF EXISTS demo_users CASCADE;

-- 父表
CREATE TABLE demo_users (
    id    INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email VARCHAR(120) NOT NULL UNIQUE,
    name  TEXT NOT NULL
);

CREATE TABLE demo_orgs (
    id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name TEXT NOT NULL UNIQUE
);

-- 多欄組合主鍵 + 雙 FK
CREATE TABLE demo_memberships (
    org_id  INT NOT NULL REFERENCES demo_orgs(id)  ON DELETE CASCADE,
    user_id INT NOT NULL REFERENCES demo_users(id) ON DELETE CASCADE,
    role    TEXT NOT NULL DEFAULT 'member',
    joined_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (org_id, user_id),
    CHECK (role IN ('owner','admin','member','viewer'))
);

-- 完整 product 表
CREATE TABLE demo_products (
    id          INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku         VARCHAR(30) NOT NULL,
    name        TEXT        NOT NULL,
    price       NUMERIC(10,2) NOT NULL,
    sale_price  NUMERIC(10,2),
    stock       INT         NOT NULL DEFAULT 0,
    category_id INT REFERENCES categories(id) ON DELETE SET NULL,
    metadata    JSONB       NOT NULL DEFAULT '{}'::jsonb,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_demo_sku   UNIQUE (sku),
    CONSTRAINT chk_price     CHECK (price >= 0),
    CONSTRAINT chk_stock     CHECK (stock >= 0),
    CONSTRAINT chk_sale_price CHECK (sale_price IS NULL OR sale_price < price)
);

-- 部分唯一索引 (示範:同一 SKU 只能有一筆「啟用」紀錄,假設 metadata.status='active')
CREATE UNIQUE INDEX uq_demo_sku_active
    ON demo_products(sku)
    WHERE (metadata->>'status') = 'active';

-- 插入測試
INSERT INTO demo_users (email, name) VALUES
    ('alice@a.com','Alice'), ('bob@b.com','Bob');

INSERT INTO demo_orgs (name) VALUES ('Acme'), ('Globex');

INSERT INTO demo_memberships (org_id, user_id, role) VALUES
    (1, 1, 'owner'),
    (1, 2, 'member'),
    (2, 1, 'admin');

INSERT INTO demo_products (sku, name, price, stock, category_id) VALUES
    ('SKU-001', 'Mouse',     350.00, 100, 1),
    ('SKU-002', 'Keyboard',  890.00, 50, 1);

-- 看結果
SELECT u.name, o.name AS org, m.role
FROM demo_memberships m
JOIN demo_users u ON u.id = m.user_id
JOIN demo_orgs  o ON o.id = m.org_id;

-- 約束違反測試 (這些應該都失敗,故包在 DO 區塊中)
DO $$
BEGIN
    BEGIN
        INSERT INTO demo_products (sku, name, price) VALUES ('SKU-001','Dup',1);
        RAISE EXCEPTION '預期失敗未發生';
    EXCEPTION WHEN unique_violation THEN
        RAISE NOTICE '✅ unique_violation 如預期被攔下';
    END;

    BEGIN
        INSERT INTO demo_products (sku, name, price) VALUES ('SKU-999','X',-1);
        RAISE EXCEPTION '預期失敗未發生';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE '✅ check_violation 如預期被攔下';
    END;

    BEGIN
        INSERT INTO demo_memberships (org_id, user_id, role) VALUES (1,1,'godking');
        RAISE EXCEPTION '預期失敗未發生';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE '✅ role check 攔下不合法值';
    END;
END$$;

\echo '✅ 約束測試完成'

-- 清理
DROP TABLE demo_memberships, demo_orgs, demo_users, demo_products CASCADE;
