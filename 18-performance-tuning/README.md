# 第 18 章 效能調校

> 目標:能用 EXPLAIN ANALYZE 讀執行計畫、設定 postgresql.conf 關鍵參數、用 VACUUM 維護資料庫健康,並了解 OS 與容器層級的調校重點。
>
> 🧰 **前置準備**:本章範例使用 `bookstore` 資料庫 (`shop` schema 與範例資料)。尚未建立的話,先在 repo 根目錄執行 `psql -d postgres -f setup/01-create-tutorial-db.sql` 與 `psql -d bookstore -f setup/02-sample-data.sql`,詳見[第 1 章 1.8 節](../01-installation/README.md#18-建立教學用資料庫)。

## 18.1 效能診斷流程

```
查詢慢 → EXPLAIN ANALYZE → 找慢節點 → 加索引/改 SQL/改設定 → 再測
```

## 18.2 EXPLAIN 進階閱讀

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
- `rows` — 估計回傳列數 (估計偏差大是問題根源!)
- `actual time=啟動..總耗時 ms`
- `loops=N` — 該節點執行 N 次

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

## 18.3 VACUUM 與 ANALYZE

PostgreSQL 的 MVCC 會產生「死行 (dead tuples)」,`VACUUM` 回收它們。

```sql
-- 基本 VACUUM (不鎖表)
VACUUM shop.books;

-- VACUUM + ANALYZE 一起 (更新統計資料)
VACUUM ANALYZE shop.books;

-- FULL:完全重建表 (鎖表!非必要不用)
VACUUM FULL shop.books;

-- 只更新統計 (讓 planner 有準確資訊)
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

## 18.4 Autovacuum 設定

`postgresql.conf` 的關鍵參數:
```ini
autovacuum = on
autovacuum_vacuum_threshold = 50    # 50 個 dead tuple 才觸發
autovacuum_vacuum_scale_factor = 0.2  # + 20% 的表大小
autovacuum_analyze_threshold = 50
autovacuum_analyze_scale_factor = 0.1

# 針對特定高寫入表調整
ALTER TABLE shop.order_items SET (autovacuum_vacuum_scale_factor = 0.01);
```

## 18.5 postgresql.conf 效能參數

![資料表大小統計](./screenshots/02-table-sizes.png)

![PostgreSQL 效能參數](./screenshots/03-perf-settings.png)

```ini
# 記憶體
shared_buffers = 256MB          # 通常 25% 實體記憶體
work_mem = 4MB                  # 每個排序/hash 操作
maintenance_work_mem = 64MB     # VACUUM/CREATE INDEX 用
effective_cache_size = 768MB    # OS cache 估計值 (讓 planner 更準)

# WAL
wal_buffers = 16MB
checkpoint_completion_target = 0.9
max_wal_size = 1GB

# Planner
random_page_cost = 1.1          # SSD 設 1.1 (HDD 預設 4)
effective_io_concurrency = 200  # SSD 設高

# 連線
max_connections = 100           # 搭配 PgBouncer 可設低
```

修改 `shared_buffers` 等需要重啟。`work_mem` 等可 `ALTER SYSTEM SET ... ; SELECT pg_reload_conf();`。

## 18.6 慢查詢日誌

```ini
# postgresql.conf
log_min_duration_statement = 1000   # 超過 1 秒記錄
log_line_prefix = '%t [%p]: [%l-1] db=%d,user=%u,app=%a,client=%h '
```

配合 `pg_stat_statements`:
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

## 18.7 連線池與 PgBouncer

PostgreSQL 每個連線都是一個 process (~5MB),高並發要用連線池:

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

## 18.8 Keyset 分頁 (效能正確的分頁)

```sql
-- ❌ OFFSET 大時極慢 (掃描 OFFSET + LIMIT 列)
SELECT * FROM shop.books ORDER BY id LIMIT 10 OFFSET 10000;

-- ✅ Keyset:記住上一頁最後的 id
SELECT * FROM shop.books
WHERE id > :last_id     -- 上一頁最後一筆
ORDER BY id
LIMIT 10;               -- 永遠快!
```

## 18.9 其他調校技巧

```sql
-- 強制 planner 選特定 join 策略 (除錯用)
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

## 18.10 作業系統與容器層級調校

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

搭配第 18.5 節:SSD 環境記得 `random_page_cost = 1.1`、`effective_io_concurrency = 200`。

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

- **context switch**:活躍連線數遠超過核心數時,行程切換開銷吃掉吞吐 — 這正是 18.7 節 PgBouncer 把 `default_pool_size` 設在核心數 2~4 倍的理由。
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

## 章節腳本

- [`scripts/01-explain-analyze.sql`](./scripts/01-explain-analyze.sql)
- [`scripts/02-vacuum-stats.sql`](./scripts/02-vacuum-stats.sql)
- [`scripts/03-pg-stat-statements.sql`](./scripts/03-pg-stat-statements.sql)

---

**🎉 恭喜完成 PostgreSQL 完整教程!**

回顧所學:
- 基礎:安裝、pgAdmin、資料庫/Schema、資料型別、資料表設計
- SQL:CRUD、JOIN、聚合、索引、視圖
- 進階:Function/Procedure、Trigger、交易、CTE/Window Function
- 應用:JSON、全文搜尋、權限管理、備份還原、效能調校
