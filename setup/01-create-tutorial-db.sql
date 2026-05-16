-- =====================================================================
-- 教學資料庫初始化腳本
-- 用法:psql -d postgres -f setup/01-create-tutorial-db.sql
-- =====================================================================

-- 若已存在則砍掉重建,確保乾淨環境 (謹慎使用!)
DROP DATABASE IF EXISTS bookstore;

CREATE DATABASE bookstore
    WITH ENCODING = 'UTF8'
         LC_COLLATE = 'en_US.UTF-8'
         LC_CTYPE = 'en_US.UTF-8'
         TEMPLATE = template0;

COMMENT ON DATABASE bookstore IS 'PostgreSQL 教學用書店資料庫';

-- 切換到 bookstore 後再建立 schema 與表
\connect bookstore

CREATE SCHEMA IF NOT EXISTS shop;
COMMENT ON SCHEMA shop IS '書店核心業務 schema';

-- 啟用常用 extension
CREATE EXTENSION IF NOT EXISTS "pgcrypto";   -- 提供 gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS "pg_trgm";    -- 文字相似度搜尋
CREATE EXTENSION IF NOT EXISTS "btree_gin";  -- 進階索引

SET search_path TO shop, public;

-- =====================================================================
-- 資料表定義
-- =====================================================================

CREATE TABLE shop.categories (
    id          SERIAL PRIMARY KEY,
    name        VARCHAR(50) NOT NULL UNIQUE,
    description TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE shop.authors (
    id          SERIAL PRIMARY KEY,
    name        VARCHAR(100) NOT NULL,
    email       VARCHAR(120) UNIQUE,
    country     VARCHAR(50),
    birth_date  DATE,
    bio         TEXT
);

CREATE TABLE shop.books (
    id              SERIAL PRIMARY KEY,
    title           VARCHAR(200) NOT NULL,
    author_id       INT REFERENCES shop.authors(id) ON DELETE SET NULL,
    category_id     INT REFERENCES shop.categories(id) ON DELETE SET NULL,
    isbn            VARCHAR(20) UNIQUE,
    price           NUMERIC(10,2) NOT NULL CHECK (price >= 0),
    stock           INT NOT NULL DEFAULT 0 CHECK (stock >= 0),
    published_at    DATE,
    metadata        JSONB DEFAULT '{}'::jsonb,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE shop.customers (
    id              SERIAL PRIMARY KEY,
    name            VARCHAR(100) NOT NULL,
    email           VARCHAR(120) NOT NULL UNIQUE,
    phone           VARCHAR(30),
    registered_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TYPE shop.order_status AS ENUM ('pending', 'paid', 'shipped', 'completed', 'cancelled');

CREATE TABLE shop.orders (
    id              SERIAL PRIMARY KEY,
    customer_id     INT NOT NULL REFERENCES shop.customers(id),
    status          shop.order_status NOT NULL DEFAULT 'pending',
    ordered_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    total           NUMERIC(12,2) NOT NULL DEFAULT 0
);

CREATE TABLE shop.order_items (
    id              SERIAL PRIMARY KEY,
    order_id        INT NOT NULL REFERENCES shop.orders(id) ON DELETE CASCADE,
    book_id         INT NOT NULL REFERENCES shop.books(id),
    quantity        INT NOT NULL CHECK (quantity > 0),
    unit_price      NUMERIC(10,2) NOT NULL CHECK (unit_price >= 0),
    UNIQUE (order_id, book_id)
);

-- 員工資料 (展示自我參照,manager_id 指向另一位員工)
CREATE TABLE shop.employees (
    id              SERIAL PRIMARY KEY,
    name            VARCHAR(100) NOT NULL,
    role            VARCHAR(50) NOT NULL,
    salary          NUMERIC(10,2) NOT NULL CHECK (salary > 0),
    hired_at        DATE NOT NULL,
    manager_id      INT REFERENCES shop.employees(id)
);

-- 完成
\echo '✅ bookstore 資料庫與 shop schema 已建立'
