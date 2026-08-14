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

### 用 psql 執行 .sql 檔案:完整用法

上面用到的 `-f` 是本教程執行章節腳本的標準方式,這裡完整說明。

**三種執行方式**:

```bash
# 1. -f:執行整個 .sql 檔 (最常用)
psql -d bookstore -f scripts/01-verify-install.sql

# 2. -c:執行單一指令 (適合快速查詢、shell 腳本)
psql -d bookstore -c "SELECT COUNT(*) FROM shop.books;"

# 3. \i:已在 psql 內時載入檔案
psql -d bookstore
bookstore=# \i scripts/01-verify-install.sql
```

`-f` 的路徑是相對於**執行指令的目錄** (cwd),不是檔案所在目錄,所以本教程的指令都假設你在 repo 根目錄執行。`\i` 同理;若 .sql 檔內要引用其他 .sql 檔,用 `\ir` (相對於該腳本自身的路徑)。

**多個檔案依序執行** (PG 15+ 可重複 `-f`):

```bash
psql -d postgres   -f setup/01-create-tutorial-db.sql
psql -d bookstore  -f setup/02-sample-data.sql

# 或一次全部 (依檔名排序)
for f in 03-database-schema/scripts/*.sql; do
    psql -d bookstore -f "$f"
done
```

**實用參數**:

| 參數 | 用途 |
|------|------|
| `-v ON_ERROR_STOP=1` | **遇錯即停**並回傳非零 exit code。預設 psql 遇錯會繼續往下執行,自動化腳本務必加這個 |
| `--single-transaction` | 整個檔案包成一個交易,全成功或全回滾。⚠️ 檔案內含 `CREATE DATABASE` 等不能進交易的指令時不可用 (見第 3 章 3.2) |
| `-e` | 執行前回顯每條 SQL,對照輸出時好用 |
| `-q` | 安靜模式,只輸出查詢結果 |
| `-o result.txt` | 結果寫入檔案 |
| `-h` / `-p` / `-U` | 主機 / 埠 / 使用者,連遠端時用:`psql -h db.example.com -p 5432 -U app -d bookstore -f x.sql` |

```bash
# 自動化 / CI 的推薦組合
psql -d bookstore -v ON_ERROR_STOP=1 -f migrate.sql
echo $?   # 0 = 成功,非 0 = 有錯誤
```

**密碼**:遠端連線避免把密碼寫在指令裡,用環境變數 `PGPASSWORD=xxx psql ...`,或設定 `~/.pgpass` 檔 (格式 `host:port:db:user:password`,權限須為 `chmod 600`)。

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
