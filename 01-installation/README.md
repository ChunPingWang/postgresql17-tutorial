# 第 1 章 環境安裝與啟動

> 目標:理解 PostgreSQL 在 macOS 上的安裝方式、**裝之前該先決定哪些事**,完成本機伺服器啟動並驗證連線,而且當「連不上」時知道從哪裡開始查。
>
> 📐 **本章讀法**:每一節先講「為什麼要做這件事」,再講「怎麼做」。1.2 是動手裝之前的決策清單,1.9 是六個連線 / 安裝故障情境與排查順序 — 之後任何一章卡在「連不上、找不到、亂碼」都回來翻 1.9。

## 1.1 PostgreSQL 是什麼

PostgreSQL (常簡稱 Postgres) 是一個**開源、物件關聯式 (Object-Relational)** 的資料庫管理系統,擁有 35+ 年歷史,以**標準遵循度高、功能完整、可靠性強**著稱。

**為什麼選 PostgreSQL?**
- 支援完整 SQL 標準 (window function、CTE、JSON、full-text search…)
- 支援 ACID 交易、MVCC 並發控制
- 強大的擴充性 (Extension 系統、自訂型別、自訂函數)
- 完全免費 & BSD-like 授權

**為什麼要「自己裝一套」而不是直接用雲端**:整本教程都在做「下指令 → 看伺服器怎麼反應」的練習,本機有一套完整的伺服器,才看得到設定檔、日誌、資料目錄這些雲端服務刻意藏起來的東西 — 而這些正是第 16~18 章維運內容的基礎。

## 1.2 設計前的決策條件與考量重點

**為什麼要先想再裝**:安裝本身十分鐘,但有幾個決定是**裝下去就改不了**的 (編碼與 locale)、或改起來很痛的 (資料目錄位置、主版本、誰是超級使用者)。這些在 `brew install` 前花五分鐘想清楚,比半年後 `pg_upgrade` 或重建資料庫便宜得多。

### 先確認的前提

| 問題 | 為什麼重要 | 怎麼確認 |
|------|-----------|---------|
| **這套環境是給誰用的?** (自己練習 / 團隊開發 / 正式服務) | 練習環境求方便 (本機 trust 認證、單一超級使用者);正式環境反過來:密碼、最小權限、備份 — 兩者的安裝選擇完全不同 | 想清楚再往下看決策表;本教程是「自己練習」 |
| **要哪個主版本?** | PostgreSQL 主版本 (16 → 17) 之間**資料目錄格式不相容**,升級要 `pg_upgrade` 或 dump/restore;每個主版本各有自己的資料目錄與服務 | 選最新穩定版,除非要跟正式環境對齊 (`SHOW server_version`) |
| **正式環境是什麼版本、什麼平台?** | 本機 17、正式環境 14,你在本機用的語法 (`MERGE`、`JSON_TABLE`) 到了正式環境會爆 | 問維運 / 看雲端服務頁面;版本以正式環境為準,或至少不高於它 |
| **需要同時跑多個版本嗎?** | 影響安裝方式:Homebrew 的 `@17` 命名與 keg-only 設計就是為了多版本並存;Postgres.app 也可以;Docker 最乾淨 | 看你手上有幾個專案、各用什麼版本 |
| **資料要放哪、有多大?** | 資料目錄 (`PGDATA`) 是整個資料庫的實體,放在會被清掉的位置 (`/tmp`、容器可寫層) 等於沒存;磁碟滿了 PostgreSQL 直接停 | 決定路徑、確認磁碟空間 (`df -h`);Docker 一定掛 volume |
| **編碼與 locale 要什麼?** | `initdb` 時決定,**之後不能改**:`template1`/`postgres` 的 encoding 與 collation 會影響每個新資料庫的預設;collation 更決定排序與索引順序,改了要 REINDEX | 本教程用 `UTF8` + `en_US.UTF-8`;需要中文排序才考慮 `zh_TW.UTF-8` 或 ICU |

### 決策對照:什麼情況選什麼

| 情況 | 選擇 | 理由 |
|------|------|------|
| macOS 上自己練習、常用 terminal、可能多版本 | **Homebrew** (本教程) | 版本管理、升級、與其他 CLI 工具整合最順;`brew services` 管服務 |
| macOS 上只想點一下就有、不碰 terminal | Postgres.app | 一鍵啟動、GUI;但 PATH 與多版本切換要自己處理 |
| 要跟正式環境一模一樣、或同時要好幾套隔離的環境 | Docker (`postgres:17`) | 可重現、砍掉重來零成本;代價是要懂 volume、port、`--shm-size` (見第 18 章 18.11) |
| Windows,或想要 pgAdmin 一起裝好 | EnterpriseDB 安裝包 | 一站式;但套件較舊、移除繁瑣 |
| 正式服務、不想自己管備份與升級 | 雲端託管 (RDS / Cloud SQL / Supabase…) | 備份、HA、升級都是別人的事;代價是看不到 OS 層、部分參數與 extension 受限 |
| Linux 伺服器自己管 | 發行版套件 (PGDG apt/yum repo) | 有 `postgres` 系統使用者、systemd 服務、`pg_ctlcluster` 等工具;跟 Homebrew 的預設帳號行為不同 (見 1.7) |

### 上線 / 實務考量

- **超級使用者是誰**:Homebrew 讓「安裝的 macOS 使用者」直接成為超級使用者,練習很方便;正式環境應有專用的 `postgres` 角色,應用程式用另外建立的最小權限角色連線 (第 16 章)。
- **暴露面**:預設 `listen_addresses = 'localhost'` + `pg_hba.conf` 只允許本機,是安全的起點。開 `'*'` 之前先想清楚誰要連、用什麼認證 (`scram-sha-256`,不是 `trust`)。
- **第一天就有備份**:練習環境砍掉重來沒關係,但任何你會心疼的資料,裝好的當天就設 `pg_dump` 排程 (第 17 章)。
- **資源預設值很小**:`shared_buffers` 預設 128MB、`work_mem` 4MB,是「任何機器都跑得起來」的保守值,不是效能設定;練習夠用,正式環境見第 18 章 18.6。
- **開發 / 正式一致性**:版本、encoding、`search_path`、時區 (`timezone` 設定) 四項對齊,可以避掉一整類「本機好好的、上線就壞」的問題 (第 4 章 4.15 情境 B 的時區情境就是典型)。

## 1.3 透過 Homebrew 安裝

**為什麼裝完還要設 PATH**:`postgresql@17` 是 Homebrew 的 **keg-only** formula — 為了讓多個版本並存,Homebrew 刻意**不**把它的執行檔連結到 `/opt/homebrew/bin`。所以裝完直接打 `psql` 會得到 `command not found` (1.9 情境 A),要自己把它的 `bin` 目錄加進 PATH。

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

**為什麼需要「服務」而不是直接執行**:PostgreSQL 是一個常駐的伺服器行程 (postmaster),你的 psql、pgAdmin、應用程式都是「客戶端」去連它。它沒起來,任何客戶端都會得到 `connection refused` (1.9 情境 B)。`brew services` 把它註冊成背景服務,開機自動啟動、當掉自動重拉,你就不用每次手動起。

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

**不想常駐 (手動啟動)**:適合「只在需要時開一下」的情境,關掉 terminal 就結束。
```bash
LC_ALL="en_US.UTF-8" \
  /opt/homebrew/opt/postgresql@17/bin/postgres \
  -D /opt/homebrew/var/postgresql@17
```

## 1.5 重要路徑

**為什麼要知道這些路徑**:排查時最重要的三樣東西 — 日誌、設定檔、資料目錄 — 都在這裡。伺服器起不來的原因一定寫在日誌裡;連線被拒的原因在 `pg_hba.conf`;磁碟滿了要看的是資料目錄。

| 路徑 | 用途 |
|------|------|
| `/opt/homebrew/opt/postgresql@17/bin/` | 執行檔 (psql、pg_dump、createdb…) |
| `/opt/homebrew/var/postgresql@17/` | 資料目錄 (`PGDATA`) — 內含所有資料庫檔案 |
| `/opt/homebrew/var/log/postgresql@17.log` | 服務日誌 |
| `/opt/homebrew/var/postgresql@17/postgresql.conf` | 主設定檔 |
| `/opt/homebrew/var/postgresql@17/pg_hba.conf` | 連線驗證設定 |

不確定路徑時 (其他安裝方式、Docker),**問伺服器本人**最準:

```sql
SHOW data_directory;
SHOW config_file;
SHOW hba_file;
SHOW log_directory;   -- 相對於 data_directory
```

## 1.6 驗證連線

**為什麼要分兩步驗證**:`pg_isready` 只問「伺服器有沒有在聽」,不需要帳號密碼,能先排除「根本沒起來」;`psql` 則會真的走完認證與資料庫選擇,能再排除帳號 / 資料庫 / `pg_hba.conf` 的問題。先跑前者再跑後者,失敗時就知道問題在哪一層 (1.9 通用排查順序)。

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

**為什麼要搞清楚預設帳號**:psql 不給 `-U` 時,用的是**你的作業系統使用者名稱**;不給 `-d` 時,用的是**與使用者同名的資料庫**。這兩個預設值就是 `role "xxx" does not exist` 與 `database "xxx" does not exist` 兩個最常見錯誤的來源 (1.9 情境 C)。

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

> ⚠️ 與 Linux 套件版本不同,Homebrew **不會自動建立 postgres 使用者**。Linux 套件版 (以及 Docker 官方 image) 則相反:超級使用者叫 `postgres`,而且 Linux 套件版預設用 `peer` 認證 — 要先 `sudo -u postgres psql` 切換成同名的系統使用者才連得上 (1.9 情境 D)。

## 1.8 建立教學用資料庫

**為什麼用腳本而不是手動建**:整本教程的範例都依賴同一個 `bookstore` 資料庫與 `shop` schema;用腳本建立,每個人 (以及你砍掉重來時) 得到的都是一模一樣的起點,後面章節的輸出才對得上。

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

**為什麼要特別記 `ON_ERROR_STOP`**:psql 預設遇到錯誤會**繼續往下執行**,一個 migration 腳本第 3 行失敗、後面 50 行照跑,結果資料庫處於半套用狀態,而且 exit code 還是 0 — 自動化環境裡這是最危險的預設值。

| 參數 | 用途 |
|------|------|
| `-v ON_ERROR_STOP=1` | **遇錯即停**並回傳非零 exit code。預設 psql 遇錯會繼續往下執行,自動化腳本務必加這個 |
| `--single-transaction` | 整個檔案包成一個交易,全成功或全回滾。⚠️ 檔案內含 `CREATE DATABASE` 等不能進交易的指令時不可用 (見第 3 章 3.3) |
| `-e` | 執行前回顯每條 SQL,對照輸出時好用 |
| `-q` | 安靜模式,只輸出查詢結果 |
| `-o result.txt` | 結果寫入檔案 |
| `-h` / `-p` / `-U` | 主機 / 埠 / 使用者,連遠端時用:`psql -h db.example.com -p 5432 -U app -d bookstore -f x.sql` |

```bash
# 自動化 / CI 的推薦組合
psql -d bookstore -v ON_ERROR_STOP=1 -f migrate.sql
echo $?   # 0 = 成功,非 0 = 有錯誤
```

**密碼**:遠端連線避免把密碼寫在指令裡 (會留在 shell history 與 `ps` 輸出),用環境變數 `PGPASSWORD=xxx psql ...`,或設定 `~/.pgpass` 檔 (格式 `host:port:db:user:password`,權限須為 `chmod 600`)。

## 1.9 問題排查:情境模擬與排查順序

**為什麼要練這個**:安裝與連線的問題有個特點 — 錯誤訊息看起來都像「連不上」,但原因可能在六個完全不同的層:客戶端工具、網路 / socket、伺服器行程、認證、角色 / 資料庫、編碼。沒有順序地亂試 (重裝、重開機) 常常把問題弄得更複雜。下面先給一套由外而內的排查順序,再用六個情境走一遍。

> 🧪 [`scripts/03-troubleshooting-scenarios.sh`](./scripts/03-troubleshooting-scenarios.sh) 會真的執行情境 C 與 F (印出真實錯誤訊息),情境 A / B / E 需要一個「壞掉的環境」才能重現,腳本改為印出診斷指令與健康 / 故障時的輸出長相,並列出你目前環境的實際值。只建立 `ts_` 開頭的角色與資料庫,跑完清掉,可重複執行。標示 macOS 的檢查 (`brew`、`lsof`) 在沒有該指令的環境會自動略過。

### 通用排查順序:「連不上 / 找不到」

順序的邏輯是**由外而內、每一層只問一個問題**,某一層過了就不用再回頭:

```
0. 客戶端工具 — psql 在不在?是哪一個版本的 psql?
   → which psql;psql --version                                (情境 A)
1. 伺服器行程 — 有沒有在跑、在聽哪個埠 / socket?
   → pg_isready;brew services list;lsof -i :5432;看日誌       (情境 B、E)
2. 網路路徑 — 走 socket 還是 TCP?位址、埠對不對?
   → 有沒有給 -h?PGHOST / PGPORT 環境變數?listen_addresses?  (情境 B)
3. 認證 — pg_hba.conf 哪一行接住了你?用什麼方法?
   → SHOW hba_file;pg_hba_file_rules;訊息是 FATAL: … authentication failed  (情境 D)
4. 角色與資料庫 — 你以為的 -U / -d 跟實際的一樣嗎?
   → \du;\l;訊息是 FATAL: role/database "…" does not exist  (情境 C)
5. 編碼 — 連上了但中文是亂碼?
   → SHOW server_encoding;SHOW client_encoding;終端機 LANG     (情境 F)
6. 才動手修;修完用同一條指令再驗證一次
```

錯誤訊息本身就告訴你在哪一層:`command not found` 是第 0 層;`No such file or directory` / `Connection refused` 是第 1~2 層;`FATAL:` 開頭的都已經**連到伺服器了**,問題在第 3~4 層。

### 情境 A:`psql: command not found`

**症狀**:`brew install postgresql@17` 明明成功,打 `psql` 卻是 `zsh: command not found: psql`。

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | `which psql` | 沒輸出 — PATH 裡真的沒有 |
| 2 | `brew --prefix postgresql@17`;`ls "$(brew --prefix postgresql@17)/bin/psql"` | `/opt/homebrew/opt/postgresql@17`,檔案存在 — 套件裝了,只是沒在 PATH |
| 3 | `echo "$PATH" \| tr ':' '\n' \| grep -n postgres` | 沒有任何一行含 postgresql@17 |

**根因**:`postgresql@17` 是 keg-only formula,Homebrew 刻意不把它連到 `/opt/homebrew/bin` (為了多版本並存),所以 PATH 要自己加 (1.3)。

**修正**:`echo 'export PATH="/opt/homebrew/opt/postgresql@17/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc`。

**驗證**:`which psql` 指到 `/opt/homebrew/opt/postgresql@17/bin/psql`,`psql --version` 顯示 17.x。

**變形**:`which psql` 有輸出但版本不對 (例如 `/usr/bin/psql` 或 14.x) — 表示 PATH 裡有另一個版本排在前面 (系統自帶、其他版本的 Homebrew formula)。PATH 是「前面的贏」,把 17 的路徑放到最前面。

### 情境 B:`connection refused` / `No such file or directory`

**症狀**:兩種長相,代表兩條不同的路:

```
psql: error: connection to server on socket "/tmp/.s.PGSQL.5432" failed:
      No such file or directory
      Is the server running locally and accepting connections on that socket?
```
→ 沒給 `-h`,走 Unix socket;socket 檔不存在 = **伺服器沒起來**,或它把 socket 放在別的目錄。

```
psql: error: connection to server at "localhost" (::1), port 5432 failed:
      Connection refused
```
→ 給了 `-h localhost`,走 TCP;該埠沒人在聽 = 沒起來、埠不同、或 `listen_addresses` 不含這個位址。

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | `pg_isready` | 健康:`localhost:5432 - accepting connections`;故障:`no response` |
| 2 | `brew services list \| grep postgresql` (macOS) 或 `pg_ctl -D "$PGDATA" status` | 健康:`started`;故障:`none` / `error` / `pg_ctl: no server running` |
| 3 | `lsof -nP -iTCP:5432 -sTCP:LISTEN` (macOS / Linux) 或 `ss -ltnp \| grep 5432` (Linux) | 健康:一行 `postgres … LISTEN`;故障:空 |
| 4 | 沒起來 → `tail -50 /opt/homebrew/var/log/postgresql@17.log` (Docker:`docker logs <容器>`) | **啟動失敗的原因一定寫在這裡**:資料目錄權限、埠被占 (情境 E)、上次沒乾淨關機留下 `postmaster.pid`、磁碟滿 |

**根因**:九成是服務沒啟動 (剛裝好、重開機後 `brew services` 沒註冊、或啟動失敗但你沒看日誌)。

**修正**:`brew services start postgresql@17`;若日誌說啟動失敗,先修日誌裡的那個原因。

**驗證**:`pg_isready` 回 `accepting connections`,再 `psql -d postgres -c 'SELECT 1'`。

### 情境 C:`FATAL: role "xxx" does not exist` / `database "xxx" does not exist`

**症狀** (腳本真實執行的輸出):

```
$ psql -U ts_nobody -d postgres
psql: error: connection to server on socket "…/.s.PGSQL.5432" failed:
      FATAL:  role "ts_nobody" does not exist

$ psql -U ts_app          # 角色存在,但沒給 -d
psql: error: connection to server on socket "…/.s.PGSQL.5432" failed:
      FATAL:  database "ts_app" does not exist
```

注意這兩個都是 `FATAL:` — 你**已經連到伺服器了**,問題不在網路,在你給的 (或沒給的) 參數。

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | 回想 psql 的預設值:沒給 `-U` → 用作業系統使用者名;沒給 `-d` → 用**與 -U 相同**的名字 | 你以為連的是 `postgres`,其實是 `psql -U rexwang -d rexwang` |
| 2 | `psql -d postgres -c '\du'` 列出角色 | 有 `rexwang` (Homebrew) 或 `postgres` (Linux / Docker),沒有你打的那個 |
| 3 | `psql -d postgres -c '\l'` 列出資料庫 | 只有 `postgres`、`template0/1`、`bookstore`,沒有同名資料庫 |

**根因**:預設值假設「每個使用者都有一個同名資料庫」,而 Homebrew 與 Docker 都沒有幫你建。

**修正**:明確指定 `-d postgres` (或建立同名資料庫 `createdb`);角色不存在則以超級使用者 `CREATE ROLE xxx LOGIN`。

**驗證**:`psql -U ts_app -d postgres -c 'SELECT current_user, current_database()'` 成功。

### 情境 D:`password authentication failed` / `Peer authentication failed`

**症狀**:

```
FATAL:  password authentication failed for user "app"
FATAL:  Peer authentication failed for user "app"            ← Linux 套件版常見
FATAL:  no pg_hba.conf entry for host "10.0.0.5", user "app", database "bookstore"
```

同樣是 `FATAL:`,已經連到伺服器,卡在**認證**這一層。

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | 以超級使用者 `SHOW hba_file;` | 伺服器實際讀的是哪個 `pg_hba.conf` (不一定是你在編輯的那個) |
| 2 | `SELECT line_number, type, database, user_name, address, auth_method FROM pg_hba_file_rules;` | 規則是**由上往下第一條符合的決定**;看哪一行接住了你的連線、方法是 `trust` / `peer` / `scram-sha-256` |
| 3 | 確認自己走的是 `local` (socket,沒給 `-h`) 還是 `host` (TCP,給了 `-h`) | 同一個使用者走 socket 是 `peer`、走 TCP 是 `scram-sha-256`,行為完全不同 |

腳本會印出你目前環境的規則,Docker 官方 image 長這樣 (本機 `trust`、遠端 `scram-sha-256`):

```
117 | local | {all} | {all} |           | trust
119 | host  | {all} | {all} | 127.0.0.1 | trust
128 | host  | {all} | {all} | all       | scram-sha-256
```

**根因對照**:
- `Peer authentication failed`:`peer` 只認「作業系統使用者名 = 資料庫角色名」,你用 `rexwang` 這個 OS 帳號想連 `app` 角色當然不行。Linux 套件版預設如此,所以要 `sudo -u postgres psql`。
- `password authentication failed`:密碼錯、角色沒設密碼 (`ALTER ROLE app PASSWORD '…'`)、或連線走 TCP 但你以為是 socket。
- `no pg_hba.conf entry`:沒有任何一行符合 (位址 / 資料庫 / 使用者組合),要加規則。

**修正**:改 `pg_hba.conf` 後**不用重啟**,`SELECT pg_reload_conf();` 即生效;密碼放 `~/.pgpass` (`chmod 600`) 而不是指令列。

**驗證**:用同一條連線指令再試;`pg_hba_file_rules` 的 `error` 欄位為 NULL 表示檔案語法正確。

### 情境 E:port already in use / 連到「另一個」伺服器

**症狀**:`brew services start` 顯示 started,但 `pg_isready` 沒回應,日誌裡:

```
LOG:  could not bind IPv4 address "127.0.0.1": Address already in use
HINT: Is another postmaster already running on port 5432?
```

或者更陰險的:連得上,但 `SHOW server_version` 是 16、資料庫清單不對 — 你連到的是**另一套** PostgreSQL。

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | `lsof -nP -iTCP:5432 -sTCP:LISTEN` / `ss -ltnp \| grep 5432` | 占著埠的 COMMAND / PID:可能是 `postgres` (另一版本)、`com.docker` (容器映射了 5432) |
| 2 | `psql -d postgres -c "SHOW server_version; SHOW data_directory;"` | 版本或資料目錄跟你預期的不同 — 證實連錯伺服器 |
| 3 | `brew services list`;`docker ps` | 找出誰是多出來的那個 |

**根因**:同時裝了 `postgresql@16` 與 `@17`、Docker 容器也映射了 5432、或上一個 postgres 沒關乾淨。

**修正**:停掉不要的 (`brew services stop postgresql@16` / `docker stop …`),或讓其中一個改埠:`postgresql.conf` 的 `port = 5433`,連線時 `-p 5433` 或 `export PGPORT=5433`。

**驗證**:`SHOW server_version` 與 `SHOW data_directory` 是你要的那套;日誌不再出現 `Address already in use`。

### 情境 F:中文亂碼

**症狀**:存進去的「中文」讀出來是 `ä¸­æ` 之類的東西;或是含中文的 SQL 一送出就報錯。

亂碼有**三層**可能出錯:資料庫編碼 (`server_encoding`)、連線編碼 (`client_encoding`)、終端機 locale。腳本真實重現了前兩層:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | `SHOW server_encoding;` | 本教程的資料庫是 `UTF8`;若是 `LATIN1` / `SQL_ASCII`,中文根本存不了 (見 F-2) |
| 2 | `SHOW client_encoding;`;`echo $LANG` | 兩者要一致且為 UTF8;`client_encoding` 由 `LANG` / `PGCLIENTENCODING` 決定,**連到非 UTF8 資料庫時會自動跟著資料庫走** |
| 3 | 若 1、2 都是 UTF8 卻仍亂碼 | 問題在終端機:確認 terminal 的字元編碼設定與字型 |

**F-1** `client_encoding` 被設成 `LATIN1` 後,含中文的查詢連送都送不出去:

```
ERROR:  character with byte sequence 0xe4 0xb8 0xad in encoding "UTF8"
        has no equivalent in encoding "LATIN1"
```

**F-2** 資料庫編碼是 `LATIN1`,中文有兩種下場 (腳本真實執行):
- **F-2a 靜默壞掉**:連到 LATIN1 資料庫時 `client_encoding` 自動變成 `LATIN1`,伺服器**不做轉換**,UTF8 位元組原封不動塞進去。之後用 UTF8 客戶端讀出:`ä¸­æ | bytes=6 | chars=6` — 2 個中文字變成 6 個字元,**資料已經壞了,不是顯示問題**。
- **F-2b 至少會報錯**:`PGCLIENTENCODING=UTF8` 明確告訴伺服器客戶端是 UTF8,它嘗試轉換、轉不了就報上面那個 `has no equivalent` 錯誤 — 難看,但資料沒壞。

**根因**:資料庫建立時的 `ENCODING` 決定它能存什麼;`client_encoding` 決定伺服器要不要 / 怎麼轉換。兩者任一不是 UTF8,中文就有風險。

**修正**:資料庫一律 `CREATE DATABASE … ENCODING 'UTF8' TEMPLATE template0` (`setup/01` 已這樣寫;既有的非 UTF8 資料庫無法改編碼,只能 dump → 重建 → restore);客戶端 `SET client_encoding TO 'UTF8'` 或 `export LANG=en_US.UTF-8`。

**驗證**:`SELECT '中文測試'` 原樣回來,`length('中文') = 2`、`octet_length('中文') = 6`。

## 章節腳本

- [`scripts/01-verify-install.sh`](./scripts/01-verify-install.sh) — 環境驗證腳本
- [`scripts/02-psql-cheatsheet.sql`](./scripts/02-psql-cheatsheet.sql) — psql 常用指令範例
- [`scripts/03-troubleshooting-scenarios.sh`](./scripts/03-troubleshooting-scenarios.sh) — 1.9 六個排查情境 (C、F 真實執行,其餘印診斷指令)

---

下一章 ➡ [第 2 章:pgAdmin 介紹與基本操作](../02-pgadmin-intro/)
