# 第 17 章 備份與還原

> 目標:先想清楚「這個系統可以丟多少資料、可以停多久」,再據此選備份方式;能用 `pg_dump` / `pg_restore` 執行完整備份與還原,了解不同備份格式的使用時機,並且在還原出問題時知道怎麼有系統地排查。
>
> 🧰 **前置準備**:本章範例使用 `bookstore` 資料庫 (`shop` schema 與範例資料)。尚未建立的話,先在 repo 根目錄執行 `psql -d postgres -f setup/01-create-tutorial-db.sql` 與 `psql -d bookstore -f setup/02-sample-data.sql`,詳見[第 1 章 1.8 節](../01-installation/README.md#18-建立教學用資料庫)。 本章的範例 dump 檔 `backup_files/bookstore.sql` 反映的是完成第 10–12 章 (view / 函數 / trigger) 後的資料庫;你自己的 dump 內容會依已完成的章節而異,備份指令本身不受影響。
>
> 📐 **本章讀法**:每一節都先講「為什麼會需要這個」,再講「怎麼做」。17.2 是規劃備份前的決策清單,17.11 是五個可以在本機重現的故障情境與排查順序 — 建議先讀 17.1~17.2 建立判斷框架,再看指令。

## 17.1 為什麼需要備份,以及工具概覽

**沒有備份時會發生什麼**:資料庫會壞的方式比想像多 — 磁碟壞掉、雲端主機被回收、`UPDATE` 忘了寫 `WHERE`、migration 把欄位 DROP 掉、勒索軟體加密整台機器。前兩種靠 replica 還能救,後三種**replica 會忠實地把錯誤複製一份**。唯一能把資料帶回「壞掉之前」的,只有備份。

**備份解決什麼、不解決什麼**:備份是「某個時間點的資料副本,放在原系統之外」。它換來的是「可以回到過去」;代價是儲存空間、備份時的 I/O、以及**還原需要時間** — 這個時間通常遠比大家以為的長。所以備份不是「有做就好」,而是要對應到兩個數字:可以丟多少資料 (RPO)、可以停多久 (RTO),17.2 會展開。

**PostgreSQL 提供的工具**,依「備什麼」分兩大類 — 邏輯備份 (把資料轉成 SQL / 可攜格式) 與物理備份 (直接複製資料目錄檔案):

| 工具 | 範圍 | 格式 | 用途 |
|------|------|------|------|
| `pg_dump` | 單一資料庫 | SQL / custom / dir / tar | 主要備份工具 (邏輯) |
| `pg_dumpall` | 整個 cluster | SQL | 含 roles、tablespaces (邏輯) |
| `pg_restore` | 搭配 custom/dir/tar 格式 | — | 還原 pg_dump 備份 |
| `pg_basebackup` | 整個資料目錄 | 二進位 | 物理備份 / 複寫 |
| PITR | WAL archiving | — | 點時間還原 (物理 + WAL) |

## 17.2 設計前的決策條件與考量重點

**為什麼要先想再做**:備份策略錯了不會馬上有感覺 — 每天的 cron 都「成功」,直到真的要還原那天才發現:少了角色、版本不合、還原要 6 小時但老闆只給 30 分鐘、或者檔案根本是空的 (17.11 情境 E)。備份是**為還原而存在**的,規劃時要從「還原那一刻」倒推回來。

### 先確認的前提

| 問題 | 為什麼重要 | 怎麼確認 |
|------|-----------|---------|
| **RPO:可以丟多少資料?** | 決定備份頻率。「一天一次 pg_dump」代表最多丟 24 小時的資料;RPO 要到分鐘等級,只有 WAL archiving (PITR) 做得到 | 問業務方:「昨天中午之後的訂單全部消失,可以接受嗎?」 |
| **RTO:可以停多久?** | 決定備份**型態**。邏輯備份還原 = 重新執行所有 INSERT + 重建索引,100GB 可能要好幾小時;物理備份還原接近複製檔案的速度 | 實際還原一次,計時 — 不要用猜的 |
| **資料庫多大、成長多快?** | 邏輯備份的時間與還原時間都跟資料量線性成長;超過幾百 GB 邏輯備份通常就不實際 | `SELECT pg_size_pretty(pg_database_size('bookstore'))`,看歷史趨勢 |
| **要備的只有這個 DB 嗎?** | `pg_dump` 只備**一個資料庫的內容**,不含 roles、tablespaces、其他 DB。還原到新機器時「role 不存在」是最常見的第一個錯 (17.11 情境 A) | `\l` 看有幾個 DB,`\du` 看有幾個自訂角色 |
| **還原目標的版本是什麼?** | `pg_dump` 的版本必須 ≥ 來源 server;dump 出來的檔案可以還原到**同版或更新**的 server,不能往舊版還 (17.11 情境 C) | `pg_dump --version` 與 `SHOW server_version` |
| **誰、在哪裡、怎麼還原?** | 備份放在同一台機器上,機器壞了備份一起沒;沒有人知道還原步驟,等於沒有備份 | 寫成 runbook,異地存放,定期演練 |

### 決策對照:什麼情況選什麼

| 情況 | 選擇 | 理由 |
|------|------|------|
| 小型 DB (< 幾十 GB)、RPO 一天、可以停機還原 | `pg_dump -F c` 每日 + `pg_dumpall --roles-only` | 簡單、可攜、可選擇性還原;custom 格式已壓縮且支援平行還原 |
| 需要分鐘級 RPO、或要「還原到某個時間點」(誤刪前一秒) | `pg_basebackup` + WAL archiving (PITR) | 只有 WAL 能重播到任意時間點;邏輯備份只能回到備份當下 |
| 大型 DB (數百 GB 以上) | 物理備份 (`pg_basebackup` 或 pgBackRest / Barman) | 邏輯還原要重跑所有 INSERT 與索引重建,時間不可接受 |
| 跨大版本升級、搬到不同架構 / 不同 OS | `pg_dump` / `pg_dumpall` | 物理備份綁定版本與平台;邏輯備份是唯一可攜格式 |
| 只需要某幾張表、某個 schema、或只有資料 | `pg_dump -t` / `-n` / `-a`,custom 格式 + `pg_restore -t` | 邏輯備份可以切;物理備份只能整個 cluster 一起 |
| 有 replica 了,還需要備份嗎? | **需要** | Replica 會即時複製你的 `DROP TABLE`;它解決可用性,不解決「回到過去」 |
| 用雲端代管 (RDS / Cloud SQL) | 用平台快照 + PITR,**再加**定期 `pg_dump` 到別的帳號/雲 | 快照與帳號綁死:帳號被鎖、被刪、平台故障時快照一起沒 |
| dump 格式:plain SQL vs custom vs directory | 預設 **custom (`-F c`)**;大表要平行才用 directory (`-F d -j N`);要人工檢視 / 進版控才用 plain | plain 不能選擇性還原也不能平行;custom 兩者都行;directory 多了平行 dump |

### 上線時的考量

- **`pg_dump` 不含的東西**:roles、tablespaces、`postgresql.conf`、`pg_hba.conf`、extension 的檔案本身。新機器還原 = 角色 (`pg_dumpall --roles-only`) → 設定檔 → 資料,順序不能反 (17.11 情境 A)。
- **一致性**:單次 `pg_dump` 是一個 snapshot (整個備份看到同一時間點),但**多次 `pg_dump` 之間沒有一致性** — 分表分次備份會得到彼此對不上的資料。一個 DB 一次 dump。
- **版本**:用**新版**的 `pg_dump` 去備舊 server 可以,反過來會直接拒絕。升級前先確認 PATH 上的 client 是哪個版本。
- **壓縮與大小**:custom 格式預設已壓縮 (`-Z` 調等級);plain SQL 通常比 DB 本身還大。估算儲存成本時用實際 dump 檔大小 × 保留天數。
- **加密與異地**:dump 檔就是明文資料 (含個資)。傳輸與存放要加密,並遵守 3-2-1 (17.9)。
- **保留策略**:不是越多越好 — 每日 30 天 + 每週 12 週 + 每月 12 個月是常見的分層;法規要求另計。
- **還原演練**:**沒有還原過的備份不算備份。** 至少每季在乾淨環境完整還原一次,量 RTO,更新 runbook。17.10 的驗證腳本就是演練的最小版本。
- **監控備份本身**:備份腳本要回報「失敗」而不是只回報「跑完了」;檔案大小突然變 0 或變小 50% 要告警 (17.11 情境 E)。
- **誰會被叫醒**:備份失敗通知要有人收,還原 runbook 要有第二個人會做。

## 17.3 pg_dump — 邏輯備份

**為什麼叫邏輯備份**:`pg_dump` 不碰資料目錄,而是像一個 client 連進去,把 schema 與資料「讀出來」轉成可重放的格式 (SQL 語句或它自己的 archive 格式)。所以它可攜 (跨版本、跨平台)、可切 (只備某些表),但還原時要把所有資料重新 INSERT、索引重新建 — 大 DB 就慢。

**怎麼做**:預設用 custom 格式;需要什麼就切什麼。

```bash
# 純 SQL 格式 (可直接 psql 還原)
pg_dump -d bookstore -f bookstore_backup.sql

# Custom 格式 (推薦:壓縮、可選擇性還原、支援 -j 平行)
pg_dump -d bookstore -F c -f bookstore.pgdump

# Directory 格式 (多 worker 平行備份大表)
pg_dump -d bookstore -F d -j 4 -f backup_dir/

# 只備份資料 (不含 schema)
pg_dump -d bookstore -a -F c -f bookstore_data.pgdump

# 只備份 schema (不含資料)
pg_dump -d bookstore -s -F c -f bookstore_schema.pgdump

# 只備份特定表
pg_dump -d bookstore -t shop.books -t shop.authors -F c -f books_only.pgdump

# 只備份特定 schema
pg_dump -d bookstore -n shop -F c -f shop_schema.pgdump
```

### 常用選項

| 選項 | 說明 | 什麼時候用 |
|------|------|-----------|
| `-F c` | Custom 格式 (推薦) | 預設選這個 |
| `-F d` | Directory 格式 | 大表要 `-j` 平行 dump |
| `-F t` | tar 格式 | 幾乎沒有理由用;不壓縮、不能平行 |
| `-Z 5` | 壓縮等級 0-9 | CPU 與空間的取捨;預設等級已足夠 |
| `-j N` | 平行 dump worker | 只有 directory 格式支援 |
| `--no-owner` | 不含 OWNER 資訊 | 還原到角色不同的環境 (17.11 情境 A) |
| `--no-privileges` | 不含 GRANT 語句 | 同上 |
| `-T table` | 排除某表 | 排除巨大的 log 表 |

## 17.4 pg_restore — 還原

**為什麼需要一個獨立的還原工具**:plain SQL 直接用 `psql` 灌回去就好,但 custom / directory 格式是 archive,裡面有目錄 (TOC),`pg_restore` 靠它做到 `psql` 做不到的事 — 只還原某幾張表、平行還原、先看內容再決定、依相依順序重建。

**怎麼做**:

```bash
# 建立目標資料庫 (如果不存在)
createdb bookstore_restore

# 還原 (Custom 格式)
pg_restore -d bookstore_restore -F c bookstore.pgdump

# 還原 + verbose
pg_restore -d bookstore_restore -v bookstore.pgdump

# 只還原特定表
pg_restore -d bookstore_restore -t books bookstore.pgdump

# 平行還原 (Directory 格式必備)
pg_restore -d bookstore_restore -j 4 backup_dir/

# 先 DROP 再重建 (如果表已存在)
pg_restore -d bookstore_restore --clean --if-exists bookstore.pgdump

# 列出備份內容 (不還原)
pg_restore -l bookstore.pgdump
```

> ⚠️ **`pg_restore` 預設「遇錯略過、繼續往下」**,最後只印一行 `warning: errors ignored on restore: N`,exit code 是 1 但很容易被忽略。它「跑完了」不等於「還原成功」— 一定要對照 count(*) 或用 `-1` (single transaction) 讓它全有或全無 (17.11 情境 B)。

## 17.5 pg_dumpall — 備份整個 Cluster

**為什麼還需要它**:`pg_dump` 只看得到一個資料庫裡的東西;roles (帳號、密碼、成員關係) 與 tablespaces 是**整個 cluster 共用**的,不屬於任何一個 DB。所以「把 bookstore 還原到新機器」除了 `pg_dump` 的檔案,還需要角色定義 — 否則 `ALTER TABLE ... OWNER TO app_user` 與 `GRANT ... TO reporting` 全部失敗。

**怎麼做**:日常最常用的是 `--roles-only`,搭配每個 DB 各自的 custom 格式 dump。

```bash
# 包含所有 DB + roles + tablespaces
pg_dumpall -f cluster_backup.sql

# 只備份 roles (沒有 DB 資料)
pg_dumpall --roles-only -f roles.sql

# 還原整個 cluster
psql -f cluster_backup.sql postgres
```

`pg_dumpall` 的產出只能是 plain SQL — 不能選擇性還原、不能平行,大 cluster 不適合拿它當主要備份。

## 17.6 psql 還原 SQL 格式

**為什麼**:plain SQL 格式的 dump 就是一連串 SQL 語句,沒有 TOC,`pg_restore` 讀不了 (會報 `input file appears to be a text format dump. Please use psql.`);要用 `psql` 逐句執行。

**怎麼做**:

```bash
# 還原純 SQL 格式
psql -d bookstore_restore -f bookstore_backup.sql

# 遇到錯誤仍繼續
psql -d bookstore_restore -f bookstore_backup.sql -v ON_ERROR_STOP=0
```

plain SQL 的還原**預設也是遇錯繼續**;正式還原建議加 `-v ON_ERROR_STOP=1 --single-transaction`,錯了整個 rollback。

## 17.7 pg_basebackup — 物理備份

**為什麼**:邏輯備份還原 = 重新執行所有寫入。100GB 的 DB 可能要跑好幾小時,而且期間 CPU 與 I/O 全滿。物理備份直接複製資料目錄的檔案,還原就是「把檔案放回去、啟動」,速度是複製檔案的速度;它也是 PITR 與 streaming replication 的基礎。代價:綁定 PostgreSQL 主版本與 CPU 架構,不能只還原某張表。

**怎麼做**:

```bash
# 整個 data directory 的二進位複製
pg_basebackup -h localhost -U rexwang \
    -D /tmp/pg_basebackup \
    -P -X stream -Z gzip

# 搭配 WAL archiving 實現 PITR (Point-In-Time Recovery)
```

`-X stream` 讓備份期間產生的 WAL 一起被收進來,否則 base backup 本身可能不一致、無法啟動。

## 17.8 PITR 概念

**為什麼**:定期備份 (不管邏輯或物理) 只能回到「上次備份的時間點」— RPO 等於備份間隔。要做到「回到誤刪前一秒」,需要把備份之後**每一筆變更**都留著,還原時重播到指定時間 — 那份「每一筆變更」就是 WAL。

**怎麼做**:

1. 啟用 WAL archiving (`archive_mode = on`, `archive_command`)
2. 定期 `pg_basebackup`
3. 還原時:還原 base backup + 套用 WAL 到目標時間點

設定於 `postgresql.conf`:
```ini
wal_level = replica
archive_mode = on
archive_command = 'cp %p /mnt/wal_archive/%f'
```

`archive_command` 失敗時 PostgreSQL 會**一直重試並保留該 WAL**,archive 目的地掛掉會讓 `pg_wal` 目錄漲到把磁碟塞滿 — 要監控 `pg_stat_archiver.failed_count`。實務上用 pgBackRest / Barman / WAL-G 管理 base backup + WAL,比手寫 `cp` 可靠得多。

## 17.9 備份策略建議

**為什麼要分層**:單一種備份滿足不了所有需求 — 每日邏輯備份可攜但 RPO 差;WAL 歸檔 RPO 好但還原慢、不可攜、且要搭配 base backup。分層是讓不同的事故有不同的最短恢復路徑。

| 類型 | 頻率 | 保留 | 工具 | 對應的事故 |
|------|------|------|------|-----------|
| Full 邏輯備份 | 每日 | 30 天 | pg_dump -F c | 誤刪某張表、要搬到別的版本/平台 |
| Cluster 備份 | 每週 | 12 週 | pg_dumpall | 整台重建時的角色與設定 |
| 物理基礎備份 | 每日 | 7 天 | pg_basebackup | 磁碟壞掉,要快速整機恢復 |
| WAL 歸檔 | 即時 | 7 天 | archive_command | 回到誤操作前一秒 |

**3-2-1 原則**:3 份備份、2 種媒介、1 份異地。備份放在與 DB 同一顆磁碟、同一個雲端帳號,都不算「異地」。

## 17.10 驗證備份

**為什麼**:備份會壞的方式很多 — 檔案不完整、缺角色、版本不合、還原時間超出 RTO。這些**只有真的還原一次才會發現**。把驗證變成備份流程的一部分,而不是事故當天的驚喜。

**怎麼做**:最小驗證 = 三步:檔案讀得出目錄 → 還原到乾淨環境 → 比對筆數。

```bash
# 建立測試環境還原驗證
pg_restore -l bookstore.pgdump | head -20     # 列出內容
createdb bookstore_verify
pg_restore -d bookstore_verify bookstore.pgdump
psql -d bookstore_verify -c "SELECT COUNT(*) FROM shop.books;"
dropdb bookstore_verify
```

[`scripts/02-restore-verify.sh`](./scripts/02-restore-verify.sh) 把這三步自動化,可以直接掛進備份排程的最後一步。

## 17.11 問題排查:情境模擬與排查順序

**為什麼要練這個**:備份與還原的問題有個特徵 — **發現的時機最糟**。備份失敗是在半夜 cron 裡靜靜發生的,還原失敗是在生產事故當下、所有人盯著你的時候發生的。事前把常見的失敗模式各走一遍,事故當天才有腦袋做判斷。

> 🧪 所有情境都在 [`scripts/03-troubleshooting-scenarios.sh`](./scripts/03-troubleshooting-scenarios.sh) 裡,用自己的 `ts_` 前綴資料庫與角色,dump 檔寫到暫存目錄,跑完自動清掉,不碰 bookstore。情境 A、B、D、E 會刻意出現 ERROR;情境 C 只有一組 binary 時無法重現,腳本只印出診斷指令。

### 通用排查順序:「還原失敗 / 還原後資料不對」

順序的邏輯是**先確認備份檔本身、再確認目標環境、最後才看還原指令**:

```
1. 備份檔是好的嗎?
   → ls -l 看大小 (0 bytes?);pg_restore -l 讀得出目錄嗎?哪一天的檔案?
2. pg_restore 真的成功嗎?
   → exit code 是 0 嗎?stderr 最後有沒有 "errors ignored on restore: N"?
3. 錯誤是哪一類?讀第一個 ERROR,不要只看最後一個
   → role/schema does not exist → 目標環境缺東西 (情境 A)
   → already exists / duplicate key → 目標不是空的 (情境 B)
   → version mismatch → client/server 版本 (情境 C)
4. 目標環境長什麼樣?
   → \du 角色、\l 版本與 encoding、目標 DB 是不是空的
5. 我要的是「整個換掉」還是「只補幾筆」?
   → 整個換掉:--clean --if-exists 或 drop/recreate,加 -1
   → 只補幾筆:先還原到 scratch DB,再用 SQL 搬 (情境 D)
6. 修正後驗證
   → count(*) 對照、owner 對照、抽查幾筆資料、應用程式連得上
7. 回頭修備份流程
   → 為什麼沒早點發現?把這次的檢查加進 cron (情境 E)
```

### 情境 A:還原到新機器,pg_restore 噴出一堆 `role "…" does not exist`

**症狀**:把生產的 dump 拿到新 cluster 還原,錯誤刷不停:`ERROR: role "ts_owner" does not exist`、`role "ts_reader" does not exist`,最後 `warning: errors ignored on restore: 4`,exit code 1。但表好像有出來。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | 通用順序第 1~2 步:檔案沒問題,exit code = 1 | 4 個錯誤全是 `ALTER TABLE ... OWNER TO` 與 `GRANT ... TO` |
| 2 | 資料到底有沒有進去? | `ts_orders rows = 1000`,`owner = postgres` — **資料全在,只有 owner 與權限沒套上** |
| 3 | `pg_restore -l dump \| grep -E 'TABLE \|ACL '` 看 dump 引用了哪些角色 (每行最後一欄是 owner) | `TABLE public ts_orders ts_owner`、`ACL public TABLE ts_orders ts_owner` — dump 記得的 owner 是 `ts_owner`,新機器沒這個角色 |

**根因**:`pg_dump` 只備一個資料庫的內容,**不含角色** — 角色是 cluster 層級的。dump 裡的 `OWNER TO` / `GRANT` 語句指向的角色在新機器上不存在,那幾句就失敗,其餘照常。

**修正**(二選一,看你要不要保留原本的 owner / 權限):

```bash
# 修正 1:只要資料,owner 統一給執行還原的人
pg_restore -d ts_fresh --no-owner --no-privileges ts_src.pgdump

# 修正 2:要保留 owner/權限 → 先還原角色,再還原資料
pg_dumpall --roles-only > roles.sql        # 在來源機器
psql -d postgres -f roles.sql              # 在新機器,先跑這個
pg_restore -d ts_fresh ts_src.pgdump       # 再還原資料
```

**驗證**:修正 1 → exit code 0,`rows = 1000, owner = postgres`;修正 2 → exit code 0,`rows = 1000, owner = ts_owner`。

### 情境 B:還原「成功」了,但表裡的資料還是舊的

**症狀**:今天有人誤刪了 300 筆訂單 (1000 → 700)。把昨晚的備份還原回既有 DB,指令跑完了,`count(*)` 還是 700。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | 通用順序第 2 步:看 exit code 與 stderr 結尾 | `errors ignored on restore: 7`,exit code 1 — 它不是成功,只是跑完了 |
| 2 | 讀**第一個** ERROR | `relation "ts_customers" already exists` — 目標 DB 不是空的 |
| 3 | 接著讀資料段的 ERROR | `COPY failed for table "ts_orders": duplicate key value violates unique constraint "ts_orders_pkey"` — CREATE TABLE 失敗後 COPY 照跑,撞到既有主鍵,**整段 COPY 一筆都沒進去** |

**根因**:`pg_restore` 預設不會清目標;表已存在時 `CREATE TABLE` 失敗、`COPY` 撞主鍵、`ADD CONSTRAINT` 重複 — 每一步都失敗、每一步都被略過,最後表維持原狀。

**修正**:

```bash
# 修正 1:先 DROP 再重建
pg_restore -d ts_db --clean --if-exists ts_src.pgdump
# → exit code 0,rows = 1000

# 修正 2:-1 讓整個還原在一個交易內,錯一步就全部 rollback,不會出現「半套」
pg_restore -d ts_db -1 ts_src.pgdump                     # 沒 --clean → 第一個錯就中止,exit 1,rows 仍是 700
pg_restore -d ts_db -1 --clean --if-exists ts_src.pgdump # → exit code 0,rows = 1000
```

**驗證**:`count(*)` 回到 1000;正式環境還要抽查幾筆與應用程式連線。

**延伸思考**:`--clean` 是整表 DROP — 備份之後新增的資料會一起消失。「只想救回那 300 筆、其他不動」是另一個問題,見情境 D。

### 情境 C:`pg_dump: aborting because of server version mismatch`

> 這個情境需要兩組不同版本的 binary 才能重現,腳本只示範診斷指令;下面的錯誤訊息是 PostgreSQL 的原文。

**症狀**:在新機器上跑備份腳本,`pg_dump` 直接拒絕:
```
pg_dump: error: aborting because of server version mismatch
pg_dump: detail: server version: 17.11; pg_dump version: 16.9
```

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | `pg_dump --version` vs `psql -Atc 'SHOW server_version'` | client 16.x,server 17.x — **client 比 server 舊** |
| 2 | `command -v pg_dump` | `/usr/bin/pg_dump` — 系統套件自帶的舊版排在 PATH 前面,蓋掉了 Homebrew / 新版的 bin |

**根因**:`pg_dump` 必須看得懂 server 的系統目錄;新版 server 的目錄舊版 client 不認識,所以規則是 **client 版本 ≥ server 版本**(新 client 備舊 server 可以,反過來不行)。

**修正**:把正確的 bin 目錄放到 PATH 前面,或直接用全路徑:

```bash
export PATH="/opt/homebrew/opt/postgresql@17/bin:$PATH"     # 本教程的腳本開頭就是這樣寫
# 或
/opt/homebrew/opt/postgresql@17/bin/pg_dump -d bookstore -F c -f bookstore.pgdump
```

**驗證**:`pg_dump --version` 的主版本 ≥ `SHOW server_version` 的主版本,備份指令正常產出檔案。反方向 (把 17 的 dump 還原進 16 的 server) 也不支援 — 升級時 dump 一律用**新**版工具做。

### 情境 D:只想把誤刪的幾筆資料從備份救回來,不能動到其他資料

**症狀**:生產 DB 有人刪了 3 筆訂單 (id 10, 20, 30);備份之後又新增了一筆 (id 1001),不能丟。直接 `pg_restore -t ts_orders --data-only` 往生產灌:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | 通用順序第 5 步:我要的是「只補幾筆」 | `pg_restore -t` 是**整表 COPY**,沒有「只補缺的」選項 |
| 2 | 試了 `--data-only -t ts_orders` | `COPY failed ... duplicate key value violates unique constraint "ts_orders_pkey"` — 撞到第 1 筆就整段失敗,還是 998 筆 |
| 3 | 那加 `--clean`? | 會把整張表 DROP 掉重建 — 新增的 id 1001 會消失,而且 FK 指向這張表的話 DROP 也會失敗 |

**根因**:`pg_restore` 的粒度是「表」,不是「列」。它的資料段是 `COPY` 整張表,遇到主鍵衝突整段中止;要做列級的補救,得用 SQL。

**修正**:還原到 scratch DB,再用 SQL 精準搬回 — 不需要 dblink,`COPY ... TO STDOUT | COPY ... FROM STDIN` 就能把兩個 DB 接起來:

```bash
createdb ts_scratch
pg_restore -d ts_scratch --no-owner --no-privileges -t ts_orders ts_src.pgdump

psql -X -q -d ts_scratch -c "COPY (SELECT * FROM ts_orders WHERE id IN (10,20,30)) TO STDOUT" \
  | psql -X -q -d ts_live \
        -c "CREATE TEMP TABLE staging (LIKE ts_orders)" \
        -c "COPY staging FROM STDIN" \
        -c "INSERT INTO ts_orders SELECT * FROM staging ON CONFLICT (id) DO NOTHING"
dropdb ts_scratch
```

`ON CONFLICT DO NOTHING` 讓這個操作可以安全重跑;多個 `-c` 在同一個 session 執行,所以 TEMP TABLE 可以跨指令使用。

**驗證**:`rows = 1001,id 1001 仍在 = true` — 3 筆救回來,新資料沒動。

### 情境 E:排程備份每天都「成功」,要用時發現檔案是 0 bytes

**症狀**:cron 日誌每天印 `backup done`。真的要還原那天,`pg_restore -l nightly.pgdump` 說 `input file is too short (read 0, expected 5)`,檔案 0 bytes。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | 通用順序第 1 步:`ls -l` + `pg_restore -l` | 0 bytes;`pg_restore -l` exit code 1 |
| 2 | 看備份腳本:有沒有 `set -e`?stderr 去哪了?有沒有檢查 exit code? | `pg_dump ... 2>/dev/null` 然後無條件 `echo "backup done"` — **錯誤被吞掉,成功是印出來的** |
| 3 | 手動重跑一次備份指令,**這次看 stderr** | `FATAL: database "ts_livee" does not exist` — DB 名稱打錯 (cron 環境常見的還有:PATH 沒有 pg_dump、`.pgpass` 權限不對、`PGHOST` 沒設) |

**根因**:`pg_dump -f` 會先開檔再連線;連線失敗檔案就留在那裡,0 bytes。腳本沒檢查 exit code,又把 stderr 丟掉,所以「每天成功」。

**修正**:備份腳本三件事 — 遇錯即停、檢查產出、立刻驗證:

```bash
#!/usr/bin/env bash
set -euo pipefail                                   # 任何一步失敗就中止,exit code 非 0 → cron 會寄信
export PATH="/opt/homebrew/opt/postgresql@17/bin:$PATH"   # cron 的 PATH 極簡,自己設
# 密碼放 ~/.pgpass (權限 0600),不要寫在腳本或 crontab 裡

pg_dump -d bookstore -F c -f "$OUT"
pg_restore -l "$OUT" >/dev/null                     # 讀得出目錄才算備份成功
size=$(stat -c %s "$OUT" 2>/dev/null || stat -f %z "$OUT")
[ "$size" -gt 1024 ] || { echo "backup too small: $size bytes" >&2; exit 1; }
echo "backup OK: $size bytes"
```

**驗證**:修正版跑出 `backup OK: 7808 bytes, 2 張表有資料`,exit code 0;再把 DB 名稱故意打錯跑一次,確認它會以非 0 結束而不是印 done。**備份腳本要先測失敗的路徑,再測成功的。**

## 章節腳本

- [`scripts/01-backup-commands.sh`](./scripts/01-backup-commands.sh) — 各種 pg_dump 備份
- [`scripts/02-restore-verify.sh`](./scripts/02-restore-verify.sh) — 還原到測試 DB 並比對筆數
- [`scripts/03-troubleshooting-scenarios.sh`](./scripts/03-troubleshooting-scenarios.sh) — 17.11 五個排查情境 (可重現)

---

下一章 ➡ [第 18 章:效能調校](../18-performance-tuning/)
