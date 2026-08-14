# 第 16 章 角色與權限管理

> 目標:建立角色、授予最小必要權限、設定 Row Level Security (RLS)。
>
> 🧰 **前置準備**:本章範例使用 `bookstore` 資料庫 (`shop` schema 與範例資料)。尚未建立的話,先在 repo 根目錄執行 `psql -d postgres -f setup/01-create-tutorial-db.sql` 與 `psql -d bookstore -f setup/02-sample-data.sql`,詳見[第 1 章 1.8 節](../01-installation/README.md#18-建立教學用資料庫)。

## 16.1 角色 (Role) 概念

PostgreSQL 把「使用者」與「群組」統一成 **Role** (角色)。

- 能登入的 role = 使用者
- 不能登入的 role = 群組
- 一個 role 可以是另一個 role 的成員 (繼承)

## 16.2 建立角色

```sql
-- 基本使用者 (能登入)
CREATE ROLE alice LOGIN PASSWORD 'secret123';

-- 指定有效期限
CREATE ROLE temp_user LOGIN PASSWORD 'pwd' VALID UNTIL '2026-12-31';

-- 群組 (不能登入,用於授權)
CREATE ROLE readonly;
CREATE ROLE readwrite;

-- 超級使用者 (謹慎使用!)
CREATE ROLE admin_user LOGIN SUPERUSER;

-- 修改
ALTER ROLE alice PASSWORD 'newpwd';
ALTER ROLE alice VALID UNTIL 'infinity';   -- 永久
ALTER ROLE alice NOLOGIN;                 -- 禁止登入

-- 刪除
DROP ROLE alice;
```

## 16.3 GRANT / REVOKE

### 物件權限

```sql
-- 資料庫連線
GRANT CONNECT ON DATABASE bookstore TO readonly;

-- schema 使用
GRANT USAGE ON SCHEMA shop TO readonly;

-- 表格
GRANT SELECT ON ALL TABLES IN SCHEMA shop TO readonly;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA shop TO readwrite;

-- 特定表特定欄位
GRANT SELECT (id, title, price) ON shop.books TO alice;
GRANT UPDATE (price) ON shop.books TO alice;

-- Sequence (INSERT 時需要)
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA shop TO readwrite;

-- Function
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA shop TO readwrite;
```

### 預設權限 (未來建立的物件)

```sql
-- 未來在 shop schema 建立的表都自動給 readonly 讀取
ALTER DEFAULT PRIVILEGES IN SCHEMA shop
    GRANT SELECT ON TABLES TO readonly;
```

### 成員關係

```sql
-- 把 alice 加入 readwrite 群組
GRANT readwrite TO alice;

-- alice 繼承 readwrite 的所有權限
-- 如果不要繼承:GRANT readwrite TO alice WITH INHERIT FALSE;

-- 移除
REVOKE readwrite FROM alice;
```

### 查看權限

```sql
-- 物件的 ACL
SELECT relname, relacl FROM pg_class WHERE relnamespace = 'shop'::regnamespace;

-- 用 \dp
\dp shop.*

-- 角色成員
SELECT r.rolname AS role, m.rolname AS member
FROM pg_auth_members pm
JOIN pg_roles r ON r.oid = pm.roleid
JOIN pg_roles m ON m.oid = pm.member;
```

## 16.4 最小權限原則 (Principle of Least Privilege)

**設計模式**:
```
superuser (你)
    └── 應用程式群組 (app_role)   ← 只有業務需要的操作
        ├── 唯讀角色 (readonly)
        └── 讀寫角色 (readwrite)
```

```sql
-- 應用連線角色 (不給 SUPERUSER)
CREATE ROLE app_user LOGIN PASSWORD 'apppass';
GRANT CONNECT ON DATABASE bookstore TO app_user;
GRANT USAGE ON SCHEMA shop TO app_user;
GRANT SELECT, INSERT, UPDATE ON shop.orders, shop.order_items TO app_user;
GRANT SELECT ON shop.books, shop.customers TO app_user;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA shop TO app_user;
```

## 16.5 Row Level Security (RLS)

RLS 讓同一張表的不同 row 對不同使用者可見。

```sql
-- 啟用 RLS
ALTER TABLE shop.orders ENABLE ROW LEVEL SECURITY;

-- 政策 (Policy)
CREATE POLICY orders_customer_isolation ON shop.orders
    USING (customer_id = current_setting('app.current_customer_id')::INT);

-- 讓擁有者繞過 RLS (預設就是這樣)
ALTER TABLE shop.orders FORCE ROW LEVEL SECURITY;   -- 連 owner 也受約束

-- 分別設定讀/寫政策
CREATE POLICY orders_read  ON shop.orders FOR SELECT USING (true);
CREATE POLICY orders_write ON shop.orders FOR INSERT WITH CHECK (
    customer_id = current_setting('app.current_customer_id')::INT
);

-- 應用端設定 session 參數
SET app.current_customer_id = '1';
SELECT * FROM shop.orders;  -- 只看到 customer 1 的訂單

-- 關閉 RLS
ALTER TABLE shop.orders DISABLE ROW LEVEL SECURITY;
```

## 16.6 pg_hba.conf — 連線認證

位於 `/opt/homebrew/var/postgresql@17/pg_hba.conf`:

```
# TYPE  DATABASE  USER  ADDRESS    METHOD
local   all       all              trust        # 本機 socket
host    all       all   127.0.0.1  scram-sha-256
host    all       all   ::1/128    scram-sha-256
```

常用 METHOD:
- `trust` — 不驗證密碼 (本機開發用)
- `md5` — MD5 雜湊密碼
- `scram-sha-256` — 更安全的密碼驗證 (推薦)
- `reject` — 拒絕所有

修改後執行 `SELECT pg_reload_conf();` 或 `pg_ctl reload` 即可套用。

## 章節腳本

- [`scripts/01-roles-and-grants.sql`](./scripts/01-roles-and-grants.sql)
- [`scripts/02-row-level-security.sql`](./scripts/02-row-level-security.sql)

---

下一章 ➡ [第 17 章:備份與還原](../17-backup-restore/)
