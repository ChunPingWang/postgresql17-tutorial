# 第 1 章 環境安裝與啟動

> 目標:理解 PostgreSQL 在 macOS 上的安裝方式,完成本機伺服器啟動並驗證連線。

## 1.1 PostgreSQL 是什麼

PostgreSQL (常簡稱 Postgres) 是一個**開源、物件關聯式 (Object-Relational)** 的資料庫管理系統,擁有 35+ 年歷史,以**標準遵循度高、功能完整、可靠性強**著稱。

**為什麼選 PostgreSQL?**
- 支援完整 SQL 標準 (window function、CTE、JSON、full-text search…)
- 支援 ACID 交易、MVCC 並發控制
- 強大的擴充性 (Extension 系統、自訂型別、自訂函數)
- 完全免費 & BSD-like 授權

## 1.2 macOS 安裝方式比較

| 方式 | 優點 | 缺點 |
|------|------|------|
| **Homebrew** (本教程使用) | 易於版本管理、與其他 CLI 工具整合 | 需要 Terminal 基本知識 |
| Postgres.app | 一鍵安裝、GUI 啟動 | 不易切換多版本 |
| Docker | 隔離乾淨、可重現 | 需熟悉 Docker、效能略低 |
| EnterpriseDB 安裝包 | 含 pgAdmin 一站式 | 套件較舊、移除繁瑣 |

## 1.3 透過 Homebrew 安裝

```bash
# 安裝最新穩定版 (本教程使用 17)
brew install postgresql@17

# 安裝完成後,執行檔位置
ls /opt/homebrew/opt/postgresql@17/bin

# 將 PostgreSQL 工具加入 PATH (寫入 ~/.zshrc 永久生效)
echo 'export PATH="/opt/homebrew/opt/postgresql@17/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc

# 驗證
psql --version
# 預期輸出:psql (PostgreSQL) 17.10 (Homebrew)
```

## 1.4 啟動與停止服務

Homebrew 提供 `brew services` 管理背景服務:

```bash
# 啟動 (含開機自動啟動)
brew services start postgresql@17

# 查看狀態
brew services list | grep postgres

# 停止
brew services stop postgresql@17

# 重啟
brew services restart postgresql@17
```

**不想常駐 (手動啟動)**:
```bash
LC_ALL="en_US.UTF-8" \
  /opt/homebrew/opt/postgresql@17/bin/postgres \
  -D /opt/homebrew/var/postgresql@17
```

## 1.5 重要路徑

| 路徑 | 用途 |
|------|------|
| `/opt/homebrew/opt/postgresql@17/bin/` | 執行檔 (psql、pg_dump、createdb…) |
| `/opt/homebrew/var/postgresql@17/` | 資料目錄 (`PGDATA`) — 內含所有資料庫檔案 |
| `/opt/homebrew/var/log/postgresql@17.log` | 服務日誌 |
| `/opt/homebrew/var/postgresql@17/postgresql.conf` | 主設定檔 |
| `/opt/homebrew/var/postgresql@17/pg_hba.conf` | 連線驗證設定 |

## 1.6 驗證連線

```bash
# 檢查服務是否就緒
pg_isready
# 預期:localhost:5432 - accepting connections

# 列出所有資料庫
psql -l

# 連入預設資料庫
psql -d postgres
```

進入 `psql` 後常用指令:
```
\l          列出所有資料庫
\du         列出所有角色 (使用者)
\dt         列出當前資料庫的資料表
\d <name>   檢視物件結構
\c <db>     切換資料庫
\q          離開
\?          顯示所有命令
```

## 1.7 初次連線:預設帳號

Homebrew 安裝後,**安裝時的 macOS 使用者**會自動成為超級使用者:
```bash
$ whoami
rexwang

$ psql -d postgres -c "\du"
                         角色清單
 角色名稱 |                      屬性                      
----------+------------------------------------------------
 rexwang  | 超級用戶, 建立角色, 建立資料庫, 複寫, 忽略 RLS
```

> ⚠️ 與 Linux 套件版本不同,Homebrew **不會自動建立 postgres 使用者**。

## 1.8 建立教學用資料庫

執行本教程提供的 setup 腳本:

```bash
cd /Users/rexwang/workspace/postgresql-tutorial

# 建立 bookstore 資料庫與 schema
psql -d postgres -f setup/01-create-tutorial-db.sql

# 載入範例資料
psql -d bookstore -f setup/02-sample-data.sql
```

驗證:
```bash
psql -d bookstore -c "SELECT COUNT(*) FROM shop.books;"
#  count 
# -------
#      8
```

## 1.9 常見問題

| 問題 | 解法 |
|------|------|
| `command not found: psql` | PATH 沒設,執行 `export PATH=...` 或重新開 terminal |
| `connection refused` | 服務未啟動,執行 `brew services start postgresql@17` |
| `database "xxx" does not exist` | 預設不會建立同名資料庫,需指定 `psql -d postgres` |
| 中文亂碼 | 確保資料庫 ENCODING 是 UTF8 (本教程預設) |

## 章節腳本

- [`scripts/01-verify-install.sh`](./scripts/01-verify-install.sh) — 環境驗證腳本
- [`scripts/02-psql-cheatsheet.sql`](./scripts/02-psql-cheatsheet.sql) — psql 常用指令範例

---

下一章 ➡ [第 2 章:pgAdmin 介紹與基本操作](../02-pgadmin-intro/)
