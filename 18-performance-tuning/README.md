# 第 18 章 效能調校

> 目標:遇到「資料庫很慢」時知道**從哪裡開始查、先改什麼**;能讀 EXPLAIN ANALYZE、用 VACUUM 維持健康、設定 postgresql.conf 關鍵參數,並了解 OS 與容器層級的調校重點。
>
> 🧰 **前置準備**:本章範例使用 `bookstore` 資料庫 (`shop` schema 與範例資料)。尚未建立的話,先在 repo 根目錄執行 `psql -d postgres -f setup/01-create-tutorial-db.sql` 與 `psql -d bookstore -f setup/02-sample-data.sql`,詳見[第 1 章 1.8 節](../01-installation/README.md#18-建立教學用資料庫)。
>
> 📐 **本章讀法**:每一節都先講「為什麼會需要這個」,再講「怎麼做」。18.1 是一套由便宜到昂貴的診斷順序,18.2 是動手調任何東西之前的決策清單,18.12 是五個可以實際重現的故障情境 — 建議先讀 18.1~18.2 建立判斷框架,再看各節的工具。

## 18.1 效能診斷流程

**為什麼需要一套順序**:「資料庫很慢」是最常見也最模糊的抱怨。沒有順序時,人會直覺去改參數、加記憶體、換硬體 — 這些都貴、都要重啟、而且多半不是原因。經驗上八成的「資料庫慢」是**一條查詢**或**一張表**的問題,用免費的觀察就能定位。順序的原則:**先確認事實、先看便宜的、先改影響範圍小的**。

```
0. 真的是資料庫嗎?
   → 應用端量到的延遲 vs pg_stat_statements 的 mean_exec_time;網路、連線池、應用 GC 都可能是元凶
1. 是哪一條 SQL?
   → pg_stat_statements 依 total_exec_time 排序 (18.7);慢查詢日誌 log_min_duration_statement
   → 「最常跑」與「最貴」是兩個榜,先看總耗時
2. 這條 SQL 的計畫長什麼樣?
   → EXPLAIN (ANALYZE, BUFFERS) (18.3):Seq Scan?rows 估計 vs 實際?Buffers read 多少?Sort 落到 Disk?
3. 索引與統計
   → 缺索引、索引用不到 (第 9 章 9.11)、ANALYZE 過期 (rows 估計差很多)
4. 有沒有在等?
   → pg_stat_activity 的 wait_event、pg_blocking_pids() (第 13 章):慢可能只是「在等別人」
5. 表健不健康?
   → n_dead_tup、表大小異常成長、autovacuum 有沒有在跑 (18.4~18.5)
6. 資源與設定
   → 連線數、work_mem、shared_buffers、random_page_cost (18.6、18.8);這時才動 postgresql.conf
7. 主機與環境
   → CPU steal、swap、I/O 延遲、容器限制 (18.11)
8. 每一步改完都量一次
   → 同一條查詢、同一組資料、EXPLAIN ANALYZE 前後對照;沒變好就退回,不要疊加猜測
```

18.12 的每個情境都是這個順序的實際演練。

## 18.2 設計前的決策條件與考量重點

**為什麼要先想再調**:效能調校的每個動作都有副作用 — 加大 `work_mem` 可能把主機記憶體吃光、`VACUUM FULL` 會鎖表、改 `random_page_cost` 影響**所有**查詢的計畫。調錯比不調更糟,而且調參數的效果往往不如改一條 SQL。動手前先回答下面的問題。

### 先確認的前提

| 問題 | 為什麼重要 | 怎麼確認 |
|------|-----------|---------|
| **有基準線嗎?** | 沒有「改之前多快」就無法證明改了有用;也無法在變糟時回退 | 固定一組代表性查詢 + 固定資料,記下 `EXPLAIN (ANALYZE, BUFFERS)` 的時間與 Buffers;pg_stat_statements 快照 |
| **問題在哪一層?** | 應用、連線池、網路、DB、OS 各有各的工具;在錯的層調參數是白工 | 應用端量測 vs `pg_stat_statements.mean_exec_time`;`pg_stat_activity.wait_event` |
| **是一條查詢還是整體?** | 一條查詢的問題用索引/改寫解決,不要碰全域設定 | pg_stat_statements 前幾名佔總時間的比例 (18.12 情境 A) |
| **資料有多大、會長多快?** | 全在記憶體裡和超過記憶體是兩個世界;今天有效的設定一年後可能失效 | `pg_database_size`、`pg_stat_user_tables.n_live_tup` 趨勢 |
| **讀寫比例與尖峰形狀?** | OLTP (大量小查詢) 與報表 (少量大查詢) 的最佳設定相反 (work_mem、平行度、連線數) | `pg_stat_statements` 的 calls vs mean_exec_time 分布 |
| **可以重啟嗎?可以鎖表嗎?** | `shared_buffers` 要重啟;`VACUUM FULL`、`REINDEX` 要獨佔鎖;決定你能用哪些工具 | 維護窗口、是否有 replica 可切換 |

### 決策對照:什麼情況先做什麼

| 情況 | 選擇 | 理由 |
|------|------|------|
| 一條查詢慢、其他都正常 | 先改 SQL / 加索引 (第 9 章),不動設定 | 影響範圍最小、效果最大;參數是全域的,為一條查詢調參數會傷到其他查詢 |
| 很多查詢都慢、`Buffers: shared read` 很高 | 檢查 `shared_buffers` 與 `effective_cache_size`,先確認資料是否根本裝不進記憶體 | cache 命中率低是整體慢的典型原因;但若資料比記憶體大很多,加索引縮小讀取量比調參數有效 |
| 計畫出現 `Sort Method: external merge Disk`、`Batches > 1` | 對該查詢/該 role 調 `work_mem` (`SET LOCAL`、`ALTER ROLE`),不要全域調大 | work_mem 是每個節點、每個連線各自使用,全域 × 連線數 × 節點數會把記憶體吃光 (18.12 情境 C) |
| 有索引但 planner 偏好 Seq Scan、SSD 主機 | `random_page_cost = 1.1`、`effective_io_concurrency = 200` | 預設值 4 是機械硬碟的假設,SSD 上高估了索引成本 (18.12 情境 E) |
| 表大小異常成長、`n_dead_tup` 高 | 檢查 autovacuum 是否追得上,對熱表用表級 `autovacuum_vacuum_scale_factor` | 全域門檻 (20%) 對大表太寬鬆;bloat 讓每次掃描多讀幾倍頁面 (18.12 情境 B) |
| 連線數逼近 `max_connections`、大量 idle | 連線池 (PgBouncer) + `idle_in_transaction_session_timeout`,不要調大 `max_connections` | 每條連線是一個 process,idle 連線純耗記憶體;調大上限只是把問題往後推 (18.12 情境 D) |
| 單表幾億列、查詢永遠只碰最近的資料 | 分區 (partition) 依時間切 + 各分區索引 | 索引在超大表上也會很深、VACUUM 很慢;分區讓舊資料可以整塊 DROP |
| 讀取流量遠大於寫入 | Streaming replication 讀寫分離 | 單機垂直擴充有上限;報表查詢丟到 replica 不影響主庫 |
| 資料很小 (幾萬列)、查詢都在 ms 級 | **不要調** | 沒有問題就沒有調校;先把時間花在觀測工具上 |

### 上線與實務考量

- **先開觀測,再談調校**:`pg_stat_statements` (要進 `shared_preload_libraries`)、`track_io_timing = on`、`log_min_duration_statement`、`auto_explain` — 沒有這些,下次出事還是只能猜。
- **一次只改一件事**,改完量一次;兩個參數一起改,變好變壞都不知道是誰的功勞。
- **`ALTER SYSTEM` 優於直接改檔**:留下 `postgresql.auto.conf` 的紀錄,`pg_settings.source` 能看到每個值從哪來;能 `pg_reload_conf()` 的不要重啟。
- **參數有作用範圍**:全域 → 資料庫 (`ALTER DATABASE ... SET`) → 角色 (`ALTER ROLE ... SET`) → session (`SET`) → 交易 (`SET LOCAL`)。越小的範圍越安全,報表 role 專用的 `work_mem` 就是典型用法。
- **強制 planner 的開關 (`enable_seqscan = off` 等) 只用來診斷**,不要留在生產;它證明「索引版本更快」之後,真正的修正是改成本參數或改 SQL。
- **`VACUUM FULL`、`REINDEX`、`CLUSTER` 都要獨佔鎖**,生產環境用 `pg_repack` / `REINDEX CONCURRENTLY`,並排在維護窗口。
- **升級主機前先確認瓶頸**:CPU 100% 可能是一條爛查詢、I/O 等待可能是缺索引;加硬體讓爛查詢跑快一點,問題還在。

## 18.3 EXPLAIN 進階閱讀

**為什麼**:第 9 章已經用 EXPLAIN 看「有沒有用到索引」;調校時要看的更多 — 每個節點花了多少時間、讀了多少頁面、估計與實際差多少。`ANALYZE` 讓它真的執行並回報實際數字,`BUFFERS` 顯示讀了多少 cache / 磁碟頁面;沒有這兩個選項的 EXPLAIN 只是 planner 的猜測。

![EXPLAIN 查詢計畫範例](./screenshots/01-explain.png)

```sql
EXPLAIN (
    ANALYZE,     -- 實際執行並量測時間
    BUFFERS,     -- 顯示 buffer 命中/未命中
    VERBOSE,     -- 顯示輸出欄位
    FORMAT JSON  -- 輸出 JSON (方便程式解析)
)
SELECT b.title, a.name
FROM shop.books b
JOIN shop.authors a ON a.id = b.author_id
WHERE b.price > 500;
```

**關鍵節點解讀**:

```
Seq Scan on books (cost=0.00..1.18 rows=4 width=40)
  Filter: (price > 500)
  Rows Removed by Filter: 4
```

- `cost=啟動..總成本` — 估計成本 (非秒)
- `rows` — 估計回傳列數 (**估計偏差大是問題根源!** 差 10 倍以上就先 ANALYZE)
- `actual time=啟動..總耗時 ms`
- `loops=N` — 該節點執行 N 次;`actual time` 是每次的平均,總時間要乘 N (Nested Loop 的 inner 常常在這裡出問題)
- `Buffers: shared hit=A read=B` — hit 是 cache 命中,read 是要碰磁碟;`temp read/written` 是排序或雜湊溢出到 temp 檔
- `Sort Method: external merge Disk` / `Batches: N` — work_mem 不夠 (18.12 情境 C)

**怎麼找慢節點**:從最內層往外看,找「actual time 佔比最大」和「rows 估計與實際差最多」的節點;前者是時間花在哪,後者是 planner 為什麼選錯。

常見節點:
| 節點 | 說明 |
|------|------|
| Seq Scan | 全表掃描 |
| Index Scan | 用索引,再回表取列 |
| Index Only Scan | 用索引不回表 (最快) |
| Bitmap Index Scan + Heap Scan | 批次 bitmap 方式 |
| Hash Join | 雜湊連接 (中大型 JOIN) |
| Merge Join | 排序合併 (已排序輸入) |
| Nested Loop | 巢狀迴圈 (小表 inner) |
| Sort | 需要排序 (警惕大表) |
| Hash | 建雜湊表 |
| Materialize | 物化子查詢結果 |

## 18.4 VACUUM 與 ANALYZE

**為什麼**:PostgreSQL 的 MVCC (第 13 章) 不會就地覆寫資料 — UPDATE 是「寫一份新版本、把舊版本標成過期」,DELETE 也只是標記。這些「死行 (dead tuples)」不會自己消失:它們佔著頁面、讓 Seq Scan 多讀、讓索引變胖,直到 `VACUUM` 回收。而 `ANALYZE` 是另一件事:重新取樣資料分布,讓 planner 的 `rows` 估計準確 — 估計不準,計畫就選錯 (第 9 章 9.11 情境 B)。

**怎麼做**:

```sql
-- 基本 VACUUM (不鎖表)
VACUUM shop.books;

-- VACUUM + ANALYZE 一起 (更新統計資料)
VACUUM ANALYZE shop.books;

-- FULL:完全重建表 (鎖表!非必要不用)
-- 一般 VACUUM 只把空間標成可重用,檔案不會縮;要還空間給 OS 才用 FULL (或 pg_repack)
VACUUM FULL shop.books;

-- 只更新統計 (讓 planner 有準確資訊);大量寫入/批次之後主動跑
ANALYZE shop.books;
ANALYZE;   -- 整個 DB

-- 查看各表 vacuum 狀態
SELECT
    schemaname, relname,
    n_live_tup, n_dead_tup,
    last_vacuum, last_autovacuum,
    last_analyze
FROM pg_stat_user_tables
WHERE schemaname = 'shop'
ORDER BY n_dead_tup DESC;
```

`n_dead_tup` 是統計估計;要精確數字用 contrib 的 `pgstattuple('shop.books')` (會掃整張表,大表慎用)。18.12 情境 B 完整走一遍 bloat 的診斷與修復。

## 18.5 Autovacuum 設定

**為什麼**:手動 VACUUM 不可能每張表都記得跑,所以有 autovacuum 背景程序自動做。問題在門檻:預設「dead tuple 超過 50 + 表的 20%」才觸發 — 對一億列的表,要累積兩千萬個死行才動手,期間表已經胖了 20%。**高寫入的大表要把門檻調低**,而且是對那張表調,不是全域。

**怎麼做**:`postgresql.conf` 的全域參數,以及表級覆寫:

```ini
autovacuum = on
autovacuum_vacuum_threshold = 50    # 50 個 dead tuple 才觸發
autovacuum_vacuum_scale_factor = 0.2  # + 20% 的表大小
autovacuum_analyze_threshold = 50
autovacuum_analyze_scale_factor = 0.1

# 針對特定高寫入表調整
ALTER TABLE shop.order_items SET (autovacuum_vacuum_scale_factor = 0.01);
```

autovacuum「有開但追不上」的徵兆:`last_autovacuum` 很久以前、`n_dead_tup` 持續上升、`pg_stat_progress_vacuum` 一直有同一張表。常見原因是長交易擋住回收 (第 13 章 idle in transaction) 或 `autovacuum_vacuum_cost_delay` 讓它跑太慢。

## 18.6 postgresql.conf 效能參數

**為什麼**:預設值是為了「在任何機器上都能啟動」而不是「跑得快」— `shared_buffers = 128MB` 在 64GB 的主機上等於沒用 cache。但參數是全域的,調錯影響所有查詢;而且每個參數背後都是一個資源取捨。先理解每個參數在換什麼,再依主機規格設定。

![資料表大小統計](./screenshots/02-table-sizes.png)

![PostgreSQL 效能參數](./screenshots/03-perf-settings.png)

```ini
# 記憶體
shared_buffers = 256MB          # 通常 25% 實體記憶體;PostgreSQL 自己的 cache,要重啟
work_mem = 4MB                  # 每個排序/hash 節點;每個連線可同時用多份 → 全域別設大 (18.12 情境 C)
maintenance_work_mem = 64MB     # VACUUM/CREATE INDEX 用,同時只有少數在跑,可以大方 (256MB~1GB)
effective_cache_size = 768MB    # 不是配置,是「告訴 planner OS cache 大概有多少」;設 50~75% 記憶體讓它敢用索引

# WAL
wal_buffers = 16MB
checkpoint_completion_target = 0.9   # 把 checkpoint 的寫入攤平,避免 I/O 尖峰
max_wal_size = 1GB                   # 太小會頻繁 checkpoint;寫入量大的系統設幾 GB

# Planner
random_page_cost = 1.1          # SSD 設 1.1 (HDD 預設 4);決定 planner 多願意用索引 (18.12 情境 E)
effective_io_concurrency = 200  # SSD 設高:Bitmap Heap Scan 可以預讀多少頁

# 連線
max_connections = 100           # 每條連線一個 process;搭配 PgBouncer 可設低 (18.12 情境 D)
```

修改 `shared_buffers` 等需要重啟。`work_mem` 等可 `ALTER SYSTEM SET ... ; SELECT pg_reload_conf();`。用 `SELECT name, setting, source FROM pg_settings WHERE name = '...'` 確認生效與來源。

## 18.7 慢查詢日誌

**為什麼**:調校的第一個問題永遠是「是哪一條 SQL」(18.1 第 1 步)。有兩個互補的工具:**慢查詢日誌**記錄「單次超過 N 毫秒」的查詢,抓得到偶發的極慢查詢;**`pg_stat_statements`** 累計每種查詢的次數與總時間,抓得到「每次只要 5ms 但一秒跑一萬次」的隱形殺手 — 後者在日誌裡永遠不會出現。

**怎麼做**:

```ini
# postgresql.conf
log_min_duration_statement = 1000   # 超過 1 秒記錄
log_line_prefix = '%t [%p]: [%l-1] db=%d,user=%u,app=%a,client=%h '
```

配合 `pg_stat_statements` (要先加入 `shared_preload_libraries` 並重啟):
```sql
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- 找最慢的 10 個查詢
SELECT
    left(query, 80) AS query,
    calls,
    round(mean_exec_time::numeric, 2) AS avg_ms,
    round(total_exec_time::numeric, 2) AS total_ms,
    rows
FROM pg_stat_statements
ORDER BY mean_exec_time DESC
LIMIT 10;
```

三個榜要一起看:`total_exec_time` (誰吃掉最多資源)、`mean_exec_time` (誰單次最慢)、`calls` (誰最常跑)。排查「整體變慢」先看第一個 (18.12 情境 A)。`shared_blks_read`、`temp_blks_written` 欄位則分別指向 cache 未命中與 work_mem 不足。

## 18.8 連線池與 PgBouncer

**為什麼**:PostgreSQL 每個連線都是一個 OS process (~5MB 常駐 + 各自的 work_mem),建立連線要 fork、要認證,幾十毫秒。應用程式開 500 條連線,DB 端就是 500 個 process 在搶 CPU 與記憶體 — 而其中真正在執行 SQL 的往往不到 20 條。連線池讓應用端保有很多「邏輯連線」,DB 端只維持少量「實體連線」輪流用。

**怎麼做**:

```bash
# 安裝 PgBouncer (macOS)
brew install pgbouncer

# pgbouncer.ini 範例
[databases]
bookstore = host=localhost port=5432 dbname=bookstore

[pgbouncer]
listen_port = 6432
pool_mode = transaction       # session / transaction / statement
max_client_conn = 200
default_pool_size = 20
```

`pool_mode = transaction` 最省連線,但 session 層級的狀態 (`SET`、prepared statement、advisory lock、temp table) 跨交易不保證在同一條實體連線上 — 應用要避免依賴它們。`default_pool_size` 一般抓 CPU 核心數的 2~4 倍。連線數失控的診斷見 18.12 情境 D。

## 18.9 Keyset 分頁 (效能正確的分頁)

**為什麼**:`OFFSET 10000` 不是「跳到第 10000 列」,而是「讀 10010 列然後丟掉前 10000 列」— 越後面的頁越慢,而且中間有資料插入時頁面會重複或漏掉。Keyset 分頁改用「上一頁最後一筆的鍵值」當起點,每頁都是一次索引定位,永遠一樣快。

```sql
-- ❌ OFFSET 大時極慢 (掃描 OFFSET + LIMIT 列)
SELECT * FROM shop.books ORDER BY id LIMIT 10 OFFSET 10000;

-- ✅ Keyset:記住上一頁最後的 id
SELECT * FROM shop.books
WHERE id > :last_id     -- 上一頁最後一筆
ORDER BY id
LIMIT 10;               -- 永遠快!
```

代價:不能直接跳到「第 N 頁」,排序鍵必須唯一 (或加上 PK 當 tie-breaker:`ORDER BY created_at, id`)。

## 18.10 其他調校技巧

**為什麼**:下面這些是診斷用的工具,不是修正 — `enable_*` 開關用來證明「如果 planner 選另一條路會不會更快」,統計視圖用來找出哪張表、哪個索引值得關注。

```sql
-- 強制 planner 選特定 join 策略 (除錯用,不要留在生產;見 18.12 情境 E)
SET enable_seqscan = off;
SET enable_hashjoin = off;

-- 查詢統計視圖
SELECT * FROM pg_stat_user_tables  WHERE schemaname = 'shop';
SELECT * FROM pg_stat_user_indexes WHERE schemaname = 'shop';

-- Table bloat 查詢
SELECT
    schemaname || '.' || relname AS table,
    pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
    pg_size_pretty(pg_relation_size(relid)) AS table_size,
    pg_size_pretty(pg_total_relation_size(relid) - pg_relation_size(relid)) AS index_size
FROM pg_stat_user_tables
WHERE schemaname = 'shop'
ORDER BY pg_total_relation_size(relid) DESC;
```

## 18.11 作業系統與容器層級調校

資料庫調校不只在 `postgresql.conf` — PostgreSQL 大量依賴 OS 的記憶體管理與磁碟 I/O,底層環境沒調好,上層參數調再多也有限。本節依「實體機/虛擬機 (Linux)」與「容器 (Docker)」分別說明。

### Linux 核心參數 (實體機/虛擬機通用)

```bash
# /etc/sysctl.d/99-postgresql.conf,改完執行 sudo sysctl --system 生效

# 降低 swap 傾向:資料庫的記憶體被 swap 出去是效能災難
vm.swappiness = 1

# 記憶體 overcommit 策略設為 2 (不過度承諾),避免 OOM killer 殺掉 postgres
vm.overcommit_memory = 2
vm.overcommit_ratio = 90

# 控制 dirty page 寫回:預設值太大,會累積大量 dirty page 後一次猛寫,
# 造成 checkpoint 時 I/O 尖峰。改用絕對值 (bytes) 讓寫回更平滑
vm.dirty_background_bytes = 67108864   # 64MB 開始背景寫回
vm.dirty_bytes = 536870912             # 512MB 強制同步寫回
```

**Huge Pages**:`shared_buffers` 較大 (數 GB) 時,用 huge pages 可減少頁表開銷與 TLB miss:

```bash
# 1. 先問 PostgreSQL 需要幾個 huge page (PG 15+ 提供)
postgres -D $PGDATA -C shared_memory_size_in_huge_pages

# 2. 設定核心保留 (數字用上面查到的值)
sudo sysctl -w vm.nr_hugepages=600     # 也寫進 /etc/sysctl.d/ 持久化

# 3. postgresql.conf 明確要求 (拿不到 huge page 就啟動失敗,避免默默退化)
huge_pages = on
```

注意:要用的是「標準 huge pages」,**Transparent Huge Pages (THP) 反而要關掉** — THP 的背景整理 (khugepaged) 會造成不可預期的延遲尖峰:

```bash
echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
# 持久化:寫進 systemd unit 或開機腳本;多數發行版預設是 madvise/always
```

**磁碟與檔案系統**:

```bash
# SSD/NVMe 用 none (或 mq-deadline),避免多餘的 I/O 排程開銷
cat /sys/block/nvme0n1/queue/scheduler
echo none | sudo tee /sys/block/nvme0n1/queue/scheduler

# 掛載 PGDATA 的檔案系統加 noatime,省掉每次讀取都更新 atime 的寫入
# /etc/fstab
/dev/nvme0n1p1  /var/lib/postgresql  ext4  noatime  0 2

# Seq Scan 依賴 OS 預讀,確認 read-ahead (單位 512B 磁區,4096 = 2MB)
blockdev --getra /dev/nvme0n1
sudo blockdev --setra 4096 /dev/nvme0n1
```

搭配第 18.6 節:SSD 環境記得 `random_page_cost = 1.1`、`effective_io_concurrency = 200`。

**檔案系統怎麼選**:PostgreSQL 把資料存成一般檔案,檔案系統的行為直接反映在 I/O 效能上。

| 檔案系統 | 適用性 | 說明 |
|----------|--------|------|
| ext4 | ✅ 主流首選 | 穩定、生產驗證充分 |
| XFS | ✅ 主流首選 | 大表、高並行寫入通常略優 (allocation group 平行度佳) |
| ZFS / Btrfs | ⚠️ 有代價 | Copy-on-Write:隨機寫有額外開銷、易碎片化;換來壓縮與快照 |
| NFS | ❌ 小心 | fsync 語意不完整時可能損壞資料,非必要不用 |

用 ZFS 時把 `recordsize` 設為 8K~16K 對齊 PostgreSQL 頁面 — 否則一次 8KB 寫入會觸發預設 128KB record 的讀-改-寫。

**Block 大小與對齊**:這裡有三層 block,對齊與否很重要:

```
PostgreSQL 頁面 8KB (編譯期固定)
  → 檔案系統 block 4KB
    → 磁碟實體磁區 512B 或 4KB
```

- 因為檔案系統 block (4KB) 小於 PostgreSQL 頁面 (8KB),一次頁面寫入**不是原子的** — 斷電可能只寫一半 (torn page)。這正是 `full_page_writes = on` 存在的原因:checkpoint 後每頁第一次修改要把整頁寫進 WAL,是不小的寫入放大。
- 若底層能保證 8KB 原子寫入 (如 ZFS 的 CoW 特性),`full_page_writes = off` 可顯著減少 WAL 量 — 但**關錯環境就是資料損壞**,不確定就別關。
- 分割區對齊不良 (舊工具建的分割區) 會讓每個 I/O 橫跨兩個實體磁區,吞吐直接打折,`fdisk -l` 檢查起始磁區是否為 2048 的倍數。

**儲存層 (本地碟 / SAN / 雲碟)**:儲存通常是資料庫最大的瓶頸 — COMMIT 路徑是同步的,WAL 沒 fsync 完成交易就不能返回,儲存延遲直接乘在 TPS 上。三個指標按重要性:

1. **fsync/寫入延遲** — 決定交易延遲。本地 NVMe 約 0.02~0.1ms,SAN/雲碟走網路後常見 0.5~2ms
2. **隨機讀 IOPS** — OLTP 的 Index Scan 都是 8KB 隨機讀,cache 未命中時全靠它
3. **循序吞吐** — 影響 Seq Scan、VACUUM、備份還原速度

| 儲存類型 | 延遲 | 說明 |
|----------|------|------|
| 本地 NVMe | 最低 | 現代部署首選,HA 交給 streaming replication |
| FC/iSCSI SAN | 中 | 傳統企業主流:集中管理、陣列快照、共享儲存 failover;但多系統共享會互搶 (noisy neighbor) |
| 雲端區塊儲存 (EBS 等) | 中 | 行為接近 SAN;IOPS 是買來的配額,注意 burst 用完降速 |
| NAS/NFS | — | 見上表,非必要不用 |

> ⚠️ **write-back cache 必須有電池/電容保護 (BBU)**:SAN 陣列或 RAID 卡的寫入快取若無斷電保護,等於對 fsync「說謊」— 跑分很快,斷電就是資料損壞。看到「fsync 特別快」先確認是 cache 有保護,不是沒真正落盤。

實務建議:

```bash
# WAL 放獨立 volume:循序的 WAL 寫入與隨機的資料讀寫分開 (SAN/雲碟尤其有感)
initdb --waldir=/mnt/wal-volume/pg_wal -D $PGDATA
# 既有叢集:停機後把 pg_wal 搬走再 symlink 回來

# 上線前實測,不要只看規格書
pg_test_fsync                          # PostgreSQL 附的 fsync 延遲測試
fio --name=randrw --bs=8k --rw=randrw --iodepth=32 \
    --size=4G --runtime=60 --filename=/var/lib/postgresql/fio.test
```

`random_page_cost` 在 SAN/雲碟上通常設 1.1~1.5,不要沿用 HDD 時代的預設 4。

**NUMA (多插槽伺服器)**:每顆 CPU 有自己的「本地」記憶體,跨插槽存取延遲約高 1.5~2 倍。PostgreSQL 的 `shared_buffers` 是一大塊共享記憶體,預設會集中配置在啟動時所在的 NUMA node — 其他 node 的 backend 存取它全是遠端存取。多路伺服器上這是最常被忽略的效能陷阱:

```bash
# /etc/sysctl.d/99-postgresql.conf

# 一定要關 zone_reclaim:開著時核心寧可回收本地 page cache 也不用遠端記憶體,
# 資料庫的 cache 會一直被丟掉
vm.zone_reclaim_mode = 0

# 關自動 NUMA balancing:核心搬移頁面「優化」局部性,
# 對共享記憶體型工作負載反而造成延遲尖峰
kernel.numa_balancing = 0
```

```bash
# 啟動時把 shared_buffers 平均分散到各 node
numactl --interleave=all pg_ctl start -D $PGDATA

# 檢查:node 數量、numa_miss 是否持續增長
numactl --hardware
numastat
```

單插槽機器、一般大小的雲端 VM 沒這問題;大型 VM (vCPU 超過一個實體插槽) 會暴露 vNUMA,同樣適用。

**CPU**:

- **單核時脈 vs 核心數**:一個查詢 (不含平行查詢) 只跑在一個 backend process 上 — OLTP 的查詢延遲取決於**單核效能**,核心數決定並發能力與平行查詢上限。選硬體/雲端機型:OLTP 偏好高時脈,分析型偏好多核。
- **governor 與省電機制**:預設的 `powersave`/`schedutil` 低載時降頻、進深度 C-state,喚醒要時間 — 表現為「壓力小反而延遲抖動」:

```bash
cpupower frequency-set -g performance     # 鎖 performance governor
cpupower idle-set -D 10                   # 限制深度 C-state (延遲敏感時)
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor   # 確認
```

- **context switch**:活躍連線數遠超過核心數時,行程切換開銷吃掉吞吐 — 這正是 18.8 節 PgBouncer 把 `default_pool_size` 設在核心數 2~4 倍的理由。
- **平行查詢對應**:`max_parallel_workers_per_gather`、`max_worker_processes` 跟實際核心數 (容器裡是 CPU 配額) 相符。

**最大檔案開啟數**:PostgreSQL 每個表、索引都是獨立檔案 (超過 1GB 再切段),每個 backend process 各自開啟用到的檔案,描述符消耗 = 連線數 × 各自觸碰的物件數,很容易上萬:

- PostgreSQL 內部有「虛擬檔案描述符」(VFD) 機制,達到上限會自己關舊檔開新檔,通常**不會崩潰**,但頻繁 open/close 是白白的 syscall 開銷 — 大量分區表 + 高連線數時會明顯拖慢查詢。
- 相關設定三層:OS 每 process 的 `ulimit -n`、全系統的 `fs.file-max`、PostgreSQL 的 `max_files_per_process` (預設 1000,實際取它與 ulimit 的較小者)。

```bash
# systemd 環境:/etc/systemd/system/postgresql.service.d/limits.conf
[Service]
LimitNOFILE=65536

# 容器環境
docker run --ulimit nofile=65536:65536 ...
```

### 虛擬機額外注意事項

| 項目 | 建議 |
|------|------|
| Memory ballooning | 對 DB VM 停用或設保留記憶體 — balloon 搶走記憶體等同於 swap 災難 |
| CPU steal time | `vmstat` 的 `st` 欄位持續 > 5% 表示宿主機超賣,查詢延遲會抖動 |
| 磁碟快取模式 | 虛擬磁碟避免 writeback 快取 (可能違反 fsync 持久性);cache=none 較安全 |
| 時鐘源 | `kvm-clock`/`tsc` 即可;時鐘不穩會影響 `EXPLAIN ANALYZE` 與日誌時間 |

### 容器 (Docker) 注意事項

```bash
docker run -d --name pg17 \
  --shm-size=1g \                      # 見下方說明
  --memory=4g --memory-swap=4g \      # 記憶體上限,swap 設成相同值 = 禁用 swap
  --stop-timeout 120 \                 # 給 PostgreSQL 足夠時間乾淨關機
  -v pgdata:/var/lib/postgresql/data \ # 資料一定要放 volume
  -e POSTGRES_PASSWORD=... \
  postgres:17
```

- **`--shm-size` 是最常見的坑**:Docker 預設 `/dev/shm` 只有 **64MB**,而平行查詢 (parallel query) 會透過它配置動態共享記憶體,太小會出現 `ERROR: could not resize shared memory segment ... No space left on device`。建議至少設 `256MB`,大型工作負載給到 `shared_buffers` 的等級。
- **cgroup 記憶體上限與 OOM**:`shared_buffers` + 各連線的 `work_mem` 加總若逼近 `--memory` 上限,容器內的 postgres 會被 OOM kill (日誌只看到 exit code 137)。上限抓 `shared_buffers` 的 3~4 倍以上較安全。
- **`effective_cache_size` 要照 cgroup 限制設**:PostgreSQL 偵測到的是宿主機總記憶體,不是容器上限;在 `--memory=4g` 的容器裡應手動設 `effective_cache_size = 3GB` 左右,而不是讓它以為有整台機器的 cache。
- **資料放 named volume 或 bind mount**,不要放在容器的 overlayfs 可寫層 — 除了容器刪除即遺失,copy-on-write 也拖慢 I/O。
- **CPU 限制影響平行查詢**:`--cpus=2` 時,把 `max_parallel_workers_per_gather`、`max_worker_processes` 調到與配額相符,避免 worker 之間互搶時間片。
- **宿主機核心參數仍然有效**:容器共用宿主機核心,上面的 `vm.swappiness`、THP、I/O scheduler 都要在**宿主機**上調,容器內改不了。

> Kubernetes 環境同理:`resources.limits.memory` 對應上述 cgroup 議題、`emptyDir{medium: Memory}` 掛載 `/dev/shm`、資料用 PVC。生產環境建議直接用 CloudNativePG 等 operator,這些細節多半已處理好。

### 快速檢查清單

```bash
free -h && cat /proc/sys/vm/swappiness            # swap 用量與傾向
cat /sys/kernel/mm/transparent_hugepage/enabled   # THP 應為 never
grep Huge /proc/meminfo                            # huge pages 保留與使用量
vmstat 1 5                                         # si/so 應為 0,VM 注意 st 欄位
df -h /dev/shm                                     # 容器內確認 shm 大小
mount | grep -E "postgres|pgdata"                  # 檔案系統類型與 noatime
ulimit -n                                          # 開檔數上限 (建議 ≥ 65536)
pg_test_fsync -s 5                                 # fsync 延遲實測 (本地 NVMe 應 < 0.1ms)
numastat | head -3                                 # 多路機器看 numa_miss 是否持續增長
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor  # 應為 performance
```

## 18.12 問題排查:情境模擬與排查順序

**為什麼要練這個**:效能問題的共同特徵是**沒有錯誤訊息** — 系統只是變慢、變胖、連不上。能不能照 18.1 的順序有系統地縮小範圍,決定你是十分鐘找到那條 ILIKE,還是花一個下午加記憶體。下面五個情境都是 18.1 順序的實際演練,每個都可以在本機重現。

> 🧪 所有情境都在 [`scripts/04-troubleshooting-scenarios.sql`](./scripts/04-troubleshooting-scenarios.sql) 裡,用自己的 demo 表 (`perf_*`,20 萬列),跑完自動清掉;所有參數變更都用 `SET LOCAL` 包在交易內。需要 `pg_stat_statements` 在 `shared_preload_libraries`、以及 contrib 的 `pgstattuple` 與 `dblink`。建議一段一段執行,對照下面的說明。

### 排查順序回顧

```
0. 真的是 DB 嗎 → 1. 哪條 SQL (pg_stat_statements) → 2. 計畫 (EXPLAIN ANALYZE, BUFFERS)
→ 3. 索引/統計 → 4. 在等誰 (pg_stat_activity) → 5. 表健康 (dead tuples)
→ 6. 資源與設定 → 7. 主機環境 → 8. 每步都量
```

| 情境 | 症狀 | 主要落在第幾步 |
|------|------|-------------|
| A | 「整個 DB 都慢」 | 1 → 2 → 3 |
| B | 表越來越大、掃描越來越慢 | 2 → 5 |
| C | temp 檔暴增、報表尖峰時段變慢 | 2 → 6 |
| D | 連線數逼近上限 | 4 → 6 |
| E | 有索引但 planner 不用 | 2 → 3 → 6 |

### 情境 A:「整個資料庫都變慢」,其實是一條查詢在吃資源

**症狀**:CPU 飆高、所有請求的延遲都上升。沒有人改過程式,也沒有人知道是哪條 SQL。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | `pg_stat_statements_reset()` 清出乾淨的觀察窗口,讓系統跑一段時間 | (模擬負載:50 次客戶查詢、200 次主鍵查詢、5 次客服「搜尋備註」) |
| 2 | 依 `total_exec_time` 排序 | `... WHERE note ILIKE $1`:**5 次呼叫、每次 59 ms、佔總時間 98.3%**;主鍵查詢 200 次只佔 0.3% |
| 3 | 對照依 `calls` 排序 | 最常跑的是主鍵查詢 (200 次、0.004 ms) — **最常跑的不是最貴的** |
| 4 | 拿到元凶 SQL,`EXPLAIN (ANALYZE, BUFFERS)` | `Seq Scan on perf_orders`,`Buffers: shared hit=2273`,60 ms — 每次都掃 20 萬列 |

**根因**:`ILIKE '%urgent-refund%'` 前置萬用字元用不到 B-Tree (第 9 章 9.11 情境 A-2)。它一天只跑幾次,但每次的成本是主鍵查詢的一萬倍;累計起來就是整台機器的 CPU。

**修正**:`CREATE INDEX ... USING gin (note gin_trgm_ops)`。

**驗證**:重置統計、重跑同樣負載:ILIKE 查詢平均 **59 ms → 0.03 ms**,總時間佔比 **98.3% → 1.8%**;榜首換成正常的客戶查詢 (4~6 ms 總計)。

**延伸思考**:`pg_stat_statements` 預設 `track = top`,函數或 DO 區塊裡的 SQL 不會分開統計;應用程式的查詢若透過 PL/pgSQL 函數執行,要設 `pg_stat_statements.track = all` 才看得到內部。

### 情境 B:表越來越大、全表掃描越來越慢

**症狀**:資料筆數沒變 (一直是 20 萬列),但表的檔案大小從 15 MB 變成 58 MB;跑報表的全表掃描讀的頁面越來越多。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | `pg_stat_user_tables`:大小、`n_live_tup`、`n_dead_tup` | 15 MB → 58 MB;`n_dead_tup ≈ 600,000` (估計值),`last_autovacuum` 是 NULL |
| 2 | `pgstattuple('perf_bloat')` 精確量測 | `dead_tuple_percent 23.5` + `free_percent 47.4` = **70.9% 是浪費的空間**;HOT pruning 已把部分死行變成 free space,所以兩個數字要加起來看 |
| 3 | 同一條 `count(*)` 的 `EXPLAIN (ANALYZE, BUFFERS)` | `Buffers: shared hit=1920` → **`7477`,讀了 4 倍的頁面** |
| 4 | 為什麼 autovacuum 沒處理?`pg_class.reloptions` | `{autovacuum_enabled=false}` (生產環境更常見的是門檻太高、或被長交易擋住) |

**根因**:三次全表 UPDATE,每次都在表尾寫新版本、留下一份舊版本。舊版本要等 VACUUM 回收;autovacuum 沒跑,表就以 4 倍的體積活下去,每次 Seq Scan 都要讀過那 3/4 的空頁面。

> 誠實的觀察:在這個規模、資料全在 cache 裡時,`count(*)` 的執行時間只從 14 ms 變 19 ms — 讀 cache 裡的空頁面很便宜。真正的傷害在表大到裝不進記憶體時:4 倍的頁面就是 4 倍的磁碟 I/O,而且索引也跟著胖。**Buffers 是比時間更早出現的訊號。**

**修正**:
1. `VACUUM (VERBOSE) perf_bloat` — 不鎖表;之後 `n_dead_tup = 0`、`dead_tuple_percent = 0`,但 `free_percent` 變 74.8%、**表仍然 58 MB**。VACUUM 只把空間標成可重用,不還給 OS。
2. `VACUUM FULL perf_bloat` — 重寫整張表,**58 MB → 15 MB**;代價是 `AccessExclusiveLock`,生產環境用 `pg_repack`。

**驗證**:`count(*)` 回到 `Buffers: 1870`。

**治本**:`ALTER TABLE ... SET (autovacuum_vacuum_scale_factor = 0.02, autovacuum_vacuum_threshold = 1000)` 讓這張熱表的 autovacuum 早一點動手 (18.5);批次作業後主動 `VACUUM ANALYZE`。

### 情境 C:temp 檔案暴增、報表在忙碌時段變慢

**症狀**:監控看到 `pg_stat_database.temp_bytes` 一直在長;報表查詢平常還可以,尖峰時段跟其他查詢一起慢。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | 記下 `pg_stat_database` 的 `temp_files` / `temp_bytes` (累計值) | 基準線 |
| 2 | 用 `work_mem = 1MB` 跑報表的 `EXPLAIN (ANALYZE, BUFFERS)` | `Sort Method: external merge Disk: 10576kB`,`temp read=2644 written=2661` |
| 3 | 再讀 `pg_stat_database` (先 `pg_stat_force_next_flush()`) 與 `pg_stat_statements.temp_blks_written` | 這一條查詢就寫了 **1 個 temp 檔、10 MB**;`temp_blks_written = 2661` (21 MB 含讀寫) |

**根因**:`work_mem` 是「每個排序 / 雜湊節點」的記憶體上限,20 萬列的排序需要 18 MB,超過就切成多段寫到 temp 檔做外部排序。預設 4 MB 對報表型查詢常常不夠。

**修正**:`BEGIN; SET LOCAL work_mem = '64MB'; ...` — 只對這條查詢放大。計畫變成 `Sort Method: quicksort Memory: 18645kB`,temp 寫入歸零。

> 誠實的觀察:這個規模下兩者的執行時間差不多 (200 ms vs 226 ms,記憶體版本甚至沒有比較快),因為 temp 檔還在 OS 的 page cache 裡。**「Disk」是訊號,不是罪證** — 真正的代價出現在 temp 檔超過 cache、落到實體磁碟,或幾十個報表同時排序互搶 I/O 的時候。判斷依據是 `temp_bytes` 的成長量與磁碟 I/O,不是單次查詢的毫秒數。

**為什麼不直接把全域 `work_mem` 調大**:它是每連線、每節點各自使用的。`64MB × max_connections 100 × 每連線 3 個節點 = 19 GB` — 這就是把主機記憶體吃光、觸發 OOM 的公式。做法:全域保守 (4~16 MB),報表 role 用 `ALTER ROLE reporter SET work_mem = '256MB'`,單次查詢用 `SET LOCAL`。

### 情境 D:連線數逼近上限,新請求連不進來

**症狀**:應用端偶發 `FATAL: sorry, too many clients already`;DB 主機記憶體吃緊,但 CPU 不高。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | `max_connections`、`superuser_reserved_connections`、目前 client backend 數 | 上限 100、保留 3、使用中 21 (模擬:一個應用開了 20 條連線) |
| 2 | `pg_stat_activity` 依 `application_name` + `state` 分組,看 `state_change` 的年齡 | `leaky_app`:**idle 15、idle in transaction 5**;真正 `active` 的只有 1 條 (psql 自己) |

**根因**:應用程式的連線池開太大 (或忘了關連線),20 條連線裡沒有一條在做事。每條 backend 是一個 process,idle 也佔記憶體;`idle in transaction` 更糟 — 它持有鎖、擋住 VACUUM 回收 (情境 B 的另一個成因)、擋住 DDL。

**修正**:
1. 緊急:`pg_terminate_backend(pid)` 砍掉 `idle in transaction` 的 5 條 — 先用 `application_name` 確認是誰,別砍到 replication 或備份。
2. 治本:`idle_in_transaction_session_timeout = '60s'` 讓 DB 自己收拾;`idle_session_timeout` 收拾純 idle;應用端縮小連線池、或改用 PgBouncer transaction pooling (18.8) — 應用端 200 條邏輯連線,DB 端只需 20 條。

**驗證**:分組查詢只剩 `idle 15`;應用端不再收到 too many clients。

**延伸思考**:調大 `max_connections` 不是修正 — 它只是把問題延後,同時每條連線的 `work_mem` 上限乘上更大的數字 (情境 C)。

### 情境 E:SSD 主機卻沿用 HDD 的 `random_page_cost`,planner 不愛用索引

**症狀**:`perf_orders.customer_id` 有索引,查「某個區域的客戶的訂單」只碰 5% 的列,但 EXPLAIN 選了 Seq Scan 20 萬列 + Hash Join。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | `pg_settings`:`random_page_cost`、`seq_page_cost`、`effective_cache_size` | `random_page_cost = 4` (預設,機械硬碟的假設) |
| 2 | `EXPLAIN (ANALYZE, BUFFERS)` | `Hash Join` ← `Seq Scan on perf_orders` (200,000 列),**21 ms** |
| 3 | 診斷用:`SET LOCAL enable_seqscan = off` 強迫走索引再跑一次 | `Nested Loop` ← `Bitmap Heap Scan`,**7 ms** — 索引版本快 3 倍,證明 planner 選錯了 |

**根因**:`random_page_cost = 4` 告訴 planner「隨機讀一頁比循序讀貴 4 倍」。這是機械硬碟的物理事實 (磁頭要移動),SSD 上隨機讀幾乎不比循序貴。planner 因此高估索引 (隨機讀) 的成本,在中等選擇度時偏向全表掃描。

**修正**:`SET LOCAL random_page_cost = 1.1` — planner **自己**改選 `Nested Loop` ← `Index Scan using idx_perf_orders_customer`,**3.5 ms** (比強制版本更好,因為它選了 Index Scan 而不是 Bitmap)。確認後持久化:`ALTER SYSTEM SET random_page_cost = 1.1; SELECT pg_reload_conf();`,或只對 SSD tablespace 設 `ALTER TABLESPACE fast_ssd SET (random_page_cost = 1.1)`。

**驗證**:不帶 `enable_seqscan = off` 的情況下計畫仍是 Nested Loop + Index Scan;`enable_*` 開關只用來證明,不留在生產 (18.10)。

**延伸思考**:`effective_cache_size` 是同一類參數 — 它不配置記憶體,只是告訴 planner「OS cache 大概有多大」;設太小 planner 也會認為索引的隨機讀都要碰磁碟。容器裡它抓到的是宿主機記憶體,要手動設 (18.11)。

## 章節腳本

- [`scripts/01-explain-analyze.sql`](./scripts/01-explain-analyze.sql) — EXPLAIN ANALYZE 實戰
- [`scripts/02-vacuum-stats.sql`](./scripts/02-vacuum-stats.sql) — VACUUM、ANALYZE 與統計視圖
- [`scripts/03-pg-stat-statements.sql`](./scripts/03-pg-stat-statements.sql) — pg_stat_statements 慢查詢分析
- [`scripts/04-troubleshooting-scenarios.sql`](./scripts/04-troubleshooting-scenarios.sql) — 18.12 五個排查情境 (可重現)

---

**🎉 恭喜完成 PostgreSQL 完整教程!**

回顧所學:
- 基礎:安裝、pgAdmin、資料庫/Schema、資料型別、資料表設計
- SQL:CRUD、JOIN、聚合、索引、視圖
- 進階:Function/Procedure、Trigger、交易、CTE/Window Function
- 應用:JSON、全文搜尋、權限管理、備份還原、效能調校
