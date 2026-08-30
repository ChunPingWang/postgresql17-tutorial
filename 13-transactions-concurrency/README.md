# 第 13 章 交易與並發控制

> 目標:理解交易解決什麼問題、**在多人同時寫入時要先決定哪些事**、隔離等級與鎖的取捨,以及當查詢卡住、死鎖、庫存對不上時怎麼有系統地排查。
>
> 🧰 **前置準備**:本章範例使用 `bookstore` 資料庫 (`shop` schema 與範例資料)。尚未建立的話,先在 repo 根目錄執行 `psql -d postgres -f setup/01-create-tutorial-db.sql` 與 `psql -d bookstore -f setup/02-sample-data.sql`,詳見[第 1 章 1.8 節](../01-installation/README.md#18-建立教學用資料庫)。
>
> 📐 **本章讀法**:每一節都先講「為什麼會需要這個」,再講「怎麼做」。13.2 是動手前的決策清單,13.11 是四個可以在單一腳本裡重現的並發故障與排查順序 — 並發問題平常最難重現,建議一定要跑一次。

## 13.1 為什麼需要交易

**沒有交易會發生什麼**:一筆訂單至少要寫兩張表 — `orders` 插一列、`books` 扣庫存。如果插完訂單後程式當掉、或扣庫存時違反 `stock >= 0` 的 CHECK,你會得到一張「有訂單沒扣庫存」的帳。更糟的是同一時間還有別人在買同一本書,兩邊各自讀到庫存 10、各自寫回 9 — 賣了兩本只扣一本,而且**沒有任何錯誤訊息**。

**交易怎麼解決**:交易把多個 SQL 包成一個「全部成功或全部不算」的單位,並保證同時進行的交易彼此看不到對方的半成品。這就是 ACID:

| 特性 | 說明 | 沒有它會怎樣 |
|------|------|-------------|
| **A**tomicity (原子性) | 全成功或全失敗,沒有「部分完成」 | 訂單寫了、庫存沒扣 |
| **C**onsistency (一致性) | 交易前後資料庫都符合所有約束 | 庫存變負數、FK 指向不存在的列 |
| **I**solation (隔離性) | 並發交易互不干擾 (視等級而定) | 讀到別人還沒 COMMIT 的資料、lost update |
| **D**urability (持久性) | 提交後即使當機也不丟失 | COMMIT 回覆成功,重開機後資料不見 |

**但隔離不是免費的**,這是整章的核心取捨:隔離得越嚴格,交易之間就越常互相等待 (鎖) 或互相撞掉 (serialization failure);隔離得越鬆,程式就要自己處理並發的邊角案例。下一節就是做這個取捨的清單。

## 13.2 設計前的決策條件與考量重點

**為什麼要先想再寫**:並發 bug 有兩個特徵 — 測試環境幾乎不會出現 (只有一個人在用)、上線後出現也不會報錯 (只是數字對不上、或偶爾卡住)。事後排查的成本遠高於事前花五分鐘回答下面幾個問題。

### 先確認的前提

| 問題 | 為什麼重要 | 怎麼確認 |
|------|-----------|---------|
| **同一列會不會被多人同時改?** | 只有「同時改同一列」才有 lost update 與鎖等待;純新增 (INSERT log) 幾乎沒有並發問題 | 找出被 UPDATE 的「熱點列」:庫存、餘額、計數器、狀態欄位 |
| **讀完之後要不要根據讀到的值寫回?** | 「先 SELECT 再算再 UPDATE」是 lost update 的標準寫法;讀寫之間的空窗別人可以插進來 | 程式碼裡找 `SELECT ... ; 計算 ; UPDATE ... SET col = <絕對值>` |
| **交易會開多久?中間會不會等外部系統?** | 交易開著就持有鎖、也擋住 VACUUM;交易內呼叫 API、等使用者按鈕,是「idle in transaction」的來源 | 看 ORM 的交易邊界;`pg_stat_activity` 觀察 `idle in transaction` 的數量與時間 |
| **失敗可以重試嗎?** | REPEATABLE READ / SERIALIZABLE 靠「撞到就中止」保證正確,程式**必須**重試;不能重試的流程只能用鎖 | 交易是否冪等?有沒有外部副作用 (寄信、扣款) |
| **衝突多不多?** | 衝突少 → 樂觀 (版本號 / SERIALIZABLE) 便宜;衝突多 → 悲觀鎖 (FOR UPDATE) 才不會一直重試 | 估計同一列每秒被改幾次 |
| **會不會有多個交易改「同一組」列?** | 兩個交易以不同順序鎖同兩列就會死鎖 | 批次作業、轉帳 (A→B 與 B→A)、多列更新的順序 |

### 決策對照:什麼情況選什麼

| 情況 | 選擇 | 理由 |
|------|------|------|
| 一般 OLTP,每個交易只碰自己的列 | **READ COMMITTED** (預設) + `SET col = col - 1` 的原子寫法 | 最少等待;讓 DB 在列鎖下用最新值計算,就沒有 lost update (13.11 情境 C) |
| 報表 / 多次查詢要看同一個一致快照 | **REPEATABLE READ** | 整個交易看同一份快照;寫入衝突會報 `40001`,只讀交易不會 |
| 業務規則橫跨多列 (「總額不能超過額度」、「同時段只能一個預約」) | **SERIALIZABLE** + 重試 | 這類規則靠列鎖擋不住 (write skew);SSI 會自動偵測並中止其中一方 |
| 讀完要改、衝突頻繁、不能重試 | **`SELECT ... FOR UPDATE`** (悲觀鎖) | 先鎖再讀,別人排隊等,沒有重試成本;代價是等待 |
| 衝突少、流程長 (使用者編輯表單) | **樂觀鎖:版本號欄位** `UPDATE ... WHERE id = ? AND version = ?` | 不持有 DB 鎖;寫回時 `UPDATE 0` 就代表被別人改過,由程式決定怎麼合併 |
| 多個 worker 從同一張表領任務 | **`FOR UPDATE SKIP LOCKED`** | 每個 worker 鎖住自己那列、別人直接跳過,不排隊也不重複 (13.11 情境 D) |
| 「鎖不到就立刻放棄」(例如避免 UI 卡住) | **`FOR UPDATE NOWAIT`** 或 `lock_timeout` | 立即得到 `55P03`,程式可以改走別條路 |
| 保證同一批次任務只有一個程序在跑、鎖的對象不是某一列 | **Advisory Lock** (`pg_try_advisory_lock`) | 鎖的是應用層的邏輯 ID,不必為了鎖而建表 |
| 多列更新 (轉帳、批次) | **固定加鎖順序** (例如 id 由小到大) | 所有交易同方向排隊就不會互鎖 (13.11 情境 B) |

### 上線時的考量

- **交易越短越好**:交易內不要呼叫外部 API、不要等使用者。持有的列鎖會擋住別人;開著的交易 (即使只讀) 會讓 VACUUM 無法回收它之後產生的死元組,表越來越胖 (第 18 章)。
- **三個 timeout 一定要設** (在 `postgresql.conf` 或連線層級):
  - `idle_in_transaction_session_timeout`:砍掉「開了交易卻沒在做事」的連線 — 這是擋住別人最常見的元兇 (13.11 情境 A)
  - `lock_timeout`:等鎖超過多久就放棄,讓程式報錯而不是無限等
  - `statement_timeout`:單一語句上限,避免一條失控查詢拖垮全站
- **ORM / 連線池的 autocommit**:很多框架預設「每個請求一個交易」且請求結束才 COMMIT;搭配連線池時,交易可能在池裡繼續開著。確認框架的交易邊界跟你想的一樣。
- **重試要有上限與退避**:`40001` (serialization failure) 與 `40P01` (deadlock) 都是「請重試」,但無限重試會把 DB 打爆;3~5 次 + 隨機退避。
- **鎖順序寫進規範**:「多列更新一律依主鍵排序」這種規則要進 code review checklist,死鎖幾乎都是不同人寫的兩段程式碼順序相反造成的。
- **監控**:`pg_stat_activity` 的 `wait_event_type = 'Lock'` 數量、`idle in transaction` 數量與最長時間、伺服器 log 的 `deadlock detected` 次數;`log_lock_waits = on` 會把等超過 `deadlock_timeout` 的鎖記下來。

## 13.3 基本交易語法

**為什麼**:PostgreSQL 預設每一句 SQL 自成一個交易 (autocommit)。要讓多句「一起成功、一起失敗」,必須明確用 `BEGIN` 把它們框起來。

```sql
BEGIN;              -- 開始交易
-- ... SQL ...
COMMIT;             -- 提交 (確認)
ROLLBACK;           -- 回滾 (取消)

-- 或用 START TRANSACTION (等價)
START TRANSACTION;
```

### SAVEPOINT

**為什麼**:交易內任何一句出錯,整個交易就進入 aborted 狀態,後面的語句全部被拒絕、只能 ROLLBACK。有時候你只想「放棄剛剛那一步、保留前面做的」— 例如批次匯入,一列失敗不該讓前面 999 列白做。

**怎麼做**:`SAVEPOINT` 在交易內設一個回復點,`ROLLBACK TO` 只退到那裡。PL/pgSQL 的 `BEGIN ... EXCEPTION` 區塊底層就是 savepoint (第 11 章)。

```sql
BEGIN;
INSERT INTO orders ...;
SAVEPOINT sp1;
UPDATE books SET stock = stock - 1 WHERE id = 1;
-- 若這邊失敗,可以 ROLLBACK TO sp1 不影響前面的 INSERT
ROLLBACK TO SAVEPOINT sp1;
RELEASE SAVEPOINT sp1;
COMMIT;
```

> Savepoint 不是免費的:每個 savepoint 都是一個子交易,大量使用 (例如每列一個) 會拖慢效能並消耗交易 ID。批次匯入更好的做法是先驗證再插入,或用 `ON CONFLICT`。

## 13.4 並發問題

**為什麼要先認識問題**:隔離等級的定義就是「防哪幾種問題」。不知道問題長什麼樣,就無法判斷自己需要哪一級。這四種問題由輕到重:

| 問題 | 說明 | 實際長什麼樣 |
|------|------|-------------|
| **Dirty Read** | 讀到另一個未提交交易寫的資料 | 看到一筆之後被 ROLLBACK 的訂單 (PostgreSQL 任何等級都不會發生) |
| **Non-repeatable Read** | 同一 query 在交易內執行兩次,結果不同 | 報表第一頁算的總額跟第二頁對不上 |
| **Phantom Read** | 同一查詢條件在交易內兩次,第二次多了(或少了)列 | 「檢查沒有重疊的預約」通過後,別人剛好插進一筆 |
| **Serialization Anomaly** | 並發結果無法等價於任何一種順序執行 | 兩個醫生同時看到「還有另一人值班」而都請假 (write skew) |

還有一種不在標準定義裡、卻最常見的:**Lost Update** — 兩個交易都「讀 → 算 → 寫回絕對值」,後寫的蓋掉先寫的。任何隔離等級下,只要用這種寫法都可能發生 (13.11 情境 C)。

## 13.5 隔離等級

**為什麼有不同等級**:防的問題越多,DB 要追蹤的東西越多、交易被中止的機會越大。PostgreSQL 讓你依交易選,而不是全站一刀切 — 報表用嚴格的、下單用寬鬆的。

```sql
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;   -- 預設
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
-- (PostgreSQL 不實作 READ UNCOMMITTED,等同 READ COMMITTED)
-- 也可以在 BEGIN 時一起指定:BEGIN ISOLATION LEVEL REPEATABLE READ;
```

| 等級 | Dirty Read | Non-rep Read | Phantom Read | 代價 |
|------|-----------|--------------|--------------|------|
| READ COMMITTED | 不可能 | 可能 | 可能 | 幾乎沒有;每句看最新已提交資料 |
| REPEATABLE READ | 不可能 | 不可能 | 不可能 (PG) | 寫到別人改過的列 → `40001`,要重試 |
| SERIALIZABLE | 不可能 | 不可能 | 不可能 | 額外追蹤讀寫依賴;偶發 `40001`,要重試 |

> PostgreSQL 的 REPEATABLE READ 用 MVCC 實作,連 Phantom Read 也防住了。SERIALIZABLE 則用 SSI (Serializable Snapshot Isolation),多防的是 write skew 這類「各自看都對、合起來錯」的情況。

**怎麼選**:13.2 的決策表。原則是預設 READ COMMITTED,只在「同一交易多次讀要一致」時升到 REPEATABLE READ,「規則橫跨多列」時才用 SERIALIZABLE — 而且**用了就一定要寫重試**。

## 13.6 MVCC (多版本並發控制)

**為什麼要知道這個**:很多人以為「讀會擋寫、寫會擋讀」。在 PostgreSQL 不是 — 理解 MVCC 你才會知道為什麼讀永遠不會卡住、為什麼長交易會讓表變胖、為什麼 `UPDATE` 其實是「新增一個版本」。

**怎麼運作**:PostgreSQL **不用讀鎖** (Reader never blocks writer),而是用 MVCC:
- 每列有 `xmin` (建立它的交易 ID) 和 `xmax` (刪除/更新它的交易 ID)
- 每個交易看到的是**快照**:READ COMMITTED 每句一份、REPEATABLE READ 整個交易一份
- UPDATE = 舊版本標記 `xmax` + 寫一個新版本;舊版本等到沒人需要後由 `VACUUM` 清理 — 所以開很久的交易會讓 VACUUM 清不掉 (第 18 章)

```sql
-- 可以看到隱含的系統欄位
SELECT xmin, xmax, ctid, id, title FROM shop.books LIMIT 3;
```

## 13.7 鎖 (Locking)

**為什麼還需要鎖**:MVCC 解決了讀寫互擋,但「兩個人同時改同一列」還是得有人先有人後 — 那就是列鎖。另外 DDL (`ALTER TABLE`) 要改結構,期間不能有人讀寫 — 那是表鎖。鎖是自動取得的,你要懂的是**哪些操作會拿什麼鎖、跟誰衝突**,因為卡住的查詢就是卡在這裡。

### 資料表鎖

| 鎖等級 | 典型操作 | 跟誰衝突 |
|--------|---------|---------|
| ACCESS SHARE | `SELECT` | 只跟 ACCESS EXCLUSIVE 衝突 — 所以讀幾乎不會被擋 |
| ROW SHARE | `SELECT FOR UPDATE/SHARE` | EXCLUSIVE 以上 |
| ROW EXCLUSIVE | `INSERT/UPDATE/DELETE` | SHARE 以上 — 建索引時寫入會等 |
| SHARE UPDATE EXCLUSIVE | `VACUUM`, `CREATE INDEX CONCURRENTLY`, `ANALYZE` | 自己以上 |
| SHARE | `CREATE INDEX` | 寫入 (ROW EXCLUSIVE) — 這是一般建索引擋寫的原因 (第 9 章) |
| EXCLUSIVE | 少見 | 除了 ACCESS SHARE 之外全部 |
| ACCESS EXCLUSIVE | `ALTER TABLE`, `DROP TABLE`, `TRUNCATE`, `VACUUM FULL` | **全部,連 SELECT 都擋** |

```sql
-- 顯式鎖表 (通常不需要;要做的多半是 DDL 前確認沒人在用)
LOCK TABLE shop.books IN SHARE MODE;
```

> 表鎖排隊會**連鎖**:一個 `ALTER TABLE` 在等一條長 SELECT 結束,後面所有新的 SELECT 都會排在 ALTER 後面 — 網站看起來像整個掛掉。DDL 前設 `lock_timeout`,拿不到就放棄改天再來。

### 列鎖 (Row Lock)

**為什麼**:`UPDATE` 會自動鎖住被改的列到交易結束。但「先讀、再決定怎麼改」的流程,讀的時候沒鎖,別人可以插進來 (13.11 情境 C)。`SELECT ... FOR UPDATE` 讓你**在讀的時候就先鎖**。

```sql
-- FOR UPDATE:取得 exclusive 鎖,阻止其他人修改或再 FOR UPDATE
SELECT * FROM shop.books WHERE id = 1 FOR UPDATE;

-- FOR SHARE:允許其他人讀 (含 FOR SHARE),但不能修改 — 「確認這列存在且不會被刪」時用
SELECT * FROM shop.books WHERE id = 1 FOR SHARE;

-- SKIP LOCKED:跳過已被鎖的列 (任務佇列常用,見 13.11 情境 D)
SELECT * FROM shop.orders WHERE status = 'pending'
ORDER BY id LIMIT 1
FOR UPDATE SKIP LOCKED;

-- NOWAIT:若鎖不到立即報錯 (SQLSTATE 55P03),不排隊
SELECT * FROM shop.books WHERE id = 1 FOR UPDATE NOWAIT;
```

## 13.8 Deadlock

**為什麼會發生**:兩個交易各自鎖住一列、又各自要對方那一列 — 誰也不放、誰也拿不到。這不是 bug 造成的「壞掉」,而是兩段各自正確的程式碼以相反順序加鎖的必然結果。PostgreSQL **自動偵測並中止其中一個** (等待超過 `deadlock_timeout`,預設 1 秒,才開始檢查),被中止的那方收到 `40P01 deadlock detected`。

```sql
-- Session A        |  Session B
BEGIN;             |  BEGIN;
UPDATE books       |
SET stock=1        |
WHERE id=1;        |  UPDATE books SET stock=1 WHERE id=2;
                   |  UPDATE books SET stock=1 WHERE id=1;  -- 等 A
UPDATE books       |
SET stock=1        |
WHERE id=2;        |  -- A 等 B → DEADLOCK!
```

**防止死鎖**:所有交易**按相同順序**加鎖 (例如永遠先鎖 id 小的);一次要鎖多列時用 `SELECT ... WHERE id IN (...) ORDER BY id FOR UPDATE` 先按序鎖好再更新。13.11 情境 B 會實際重現並示範修正。

## 13.9 查看鎖定狀態

**為什麼**:「查詢卡住」的第一個問題永遠是「被誰卡住」。`pg_stat_activity` 告訴你每條連線在做什麼、在等什麼;`pg_blocking_pids(pid)` 直接回答「這個 pid 被哪些 pid 擋住」— 比手動 JOIN `pg_locks` 準確得多。

```sql
-- 排查第一步:誰在等、被誰擋、擋人的那個在做什麼
SELECT pid, state, wait_event_type, wait_event,
       pg_blocking_pids(pid) AS blocked_by,
       now() - xact_start    AS xact_age,
       left(query, 60)       AS query
FROM pg_stat_activity
WHERE datname = current_database() AND pid <> pg_backend_pid()
ORDER BY pid;

-- 目前所有鎖
SELECT pid, locktype, relation::regclass, mode, granted
FROM pg_locks
WHERE relation IS NOT NULL
ORDER BY relation;

-- 正在等鎖的查詢 (傳統寫法;新版直接用上面的 pg_blocking_pids 即可)
SELECT blocked_locks.pid AS blocked_pid,
       blocking_locks.pid AS blocking_pid,
       blocked_activity.query AS blocked_query,
       blocking_activity.query AS blocking_query
FROM pg_locks blocked_locks
JOIN pg_stat_activity blocked_activity ON blocked_activity.pid = blocked_locks.pid
JOIN pg_locks blocking_locks ON blocking_locks.locktype = blocked_locks.locktype
    AND blocking_locks.granted = true
    AND blocked_locks.granted = false
    AND blocking_locks.pid <> blocked_locks.pid
JOIN pg_stat_activity blocking_activity ON blocking_activity.pid = blocking_locks.pid;
```

## 13.10 Advisory Lock

**為什麼**:有些「互斥」的對象不是某一列 — 例如「每晚的結帳批次只能有一個程序在跑」、「同一個客戶的匯入只能一次一個」。為了鎖它們而建一張表、插一列來 `FOR UPDATE`,很彆扭。Advisory lock 讓你直接對一個**應用層定義的整數 ID** 加鎖。

```sql
-- Session-level (直到斷線或明確 unlock 才釋放)
SELECT pg_advisory_lock(12345);
SELECT pg_advisory_unlock(12345);

-- Transaction-level (COMMIT/ROLLBACK 自動釋放,較不容易忘記解鎖)
SELECT pg_advisory_xact_lock(12345);

-- 嘗試取鎖,失敗回 false — 批次任務用這個:拿不到就代表已有人在跑,直接退出
SELECT pg_try_advisory_lock(12345);
```

> 用 session-level 時,連線池會讓「斷線自動釋放」失效 (連線沒斷、只是還給池子) — 記得明確 unlock,或改用 xact-level。

## 13.11 問題排查:情境模擬與排查順序

**為什麼要練這個**:並發問題有三個難點 — 測試環境重現不了 (沒有並發)、生產環境不會報錯 (只是慢或數字錯)、出事的當下最需要的是「先看什麼」而不是背語法。本節先給一套通用排查順序,再用四個情境走一遍。

> 🧪 所有情境都在 [`scripts/04-troubleshooting-scenarios.sql`](./scripts/04-troubleshooting-scenarios.sql) 裡。它用 contrib 的 `dblink` 在同一支腳本裡開兩條額外連線 (s1 / s2) 模擬兩個並發的應用程式,所以**不用開兩個終端機**就能重現卡住、死鎖、lost update、重複處理。用自己的 `public.demo_*` 表,不碰 `shop.*`,跑完自動清掉;刻意製造的錯誤都被接住印成 NOTICE,整支腳本 0 個 ERROR。腳本開頭有 dblink 連線字串的說明 (Docker 免密碼;Homebrew 把 `user=` 改成自己的帳號)。

### 通用排查順序:「查詢卡住 / 資料對不上」

順序的邏輯是**先看現場、再看歷史、最後才改程式**:

```
1. 現場:誰在等、被誰擋?
   → pg_stat_activity:wait_event_type = 'Lock' 的是受害者,
     pg_blocking_pids(pid) 回的是兇手;看兇手的 state (idle in transaction?) 與 xact_start 多久了
2. 鎖的種類:等的是列 (transactionid / tuple) 還是表 (relation)?
   → pg_locks WHERE granted = false;表鎖多半是 DDL / VACUUM FULL 引起
3. 有沒有錯誤訊息?SQLSTATE 是什麼?
   → 40P01 deadlock:讀 DETAIL,它寫明誰等誰
   → 40001 serialization failure:REPEATABLE READ / SERIALIZABLE 的正常現象,程式要重試
   → 55P03 lock_not_available:NOWAIT / lock_timeout 觸發
   → 什麼都沒有、只是數字錯:八成是 lost update 或沒鎖的「讀 → 算 → 寫」
4. 歷史:伺服器 log (deadlock detected、log_lock_waits)、應用程式 log 的交易邊界
5. 對照程式碼:交易多長?中間有沒有等外部?加鎖順序?SELECT 有沒有 FOR UPDATE?
6. 才動手修:
   緊急 → ROLLBACK / pg_terminate_backend 擋人的連線
   治本 → 三個 timeout、原子寫法、固定鎖順序、SKIP LOCKED、重試
7. 驗證:重跑腳本 / 壓測,確認等待數歸零、數字對得上
```

### 情境 A:查詢卡住不動 (被 idle in transaction 的連線擋住)

**症狀**:應用程式的一個 `UPDATE` 沒報錯、也沒回來;DB 的 CPU 很閒;其他不相干的查詢都正常。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | `pg_stat_activity` + `pg_blocking_pids` | pid 323 `active`、`wait_event_type = Lock`、`wait_event = transactionid`、`blocked_by = {322}` |
| 2 | 看 pid 322 在做什麼 | `state = idle in transaction`,最後一句是 `UPDATE ... WHERE id = 1` — 改完就沒動作了 |
| 3 | `pg_locks WHERE granted = false` | 323 等的是 `transactionid` 的 `ShareLock` — 等「對方的交易結束」,不是表鎖 |

**根因**:Session 1 開了交易、改了一列、然後沒有 COMMIT (等使用者操作、程式卡在外部呼叫、或 ORM 的交易邊界比想像中大)。它改過的列被鎖到交易結束為止,Session 2 要改同一列只能等。`idle in transaction` 就是「交易開著但沒在做事」— 卡住別人最常見的元兇。

**修正 (緊急)**:讓那個交易結束 — 能碰到那條連線就 `ROLLBACK`,碰不到就 `SELECT pg_terminate_backend(322)`。Session 2 立刻回 `UPDATE 1`,等待數歸零。

**修正 (治本)**:`idle_in_transaction_session_timeout`。情境 A-2 把它設成 500ms,同樣的流程 1 秒後 Session 1 收到 `FATAL: terminating connection due to idle-in-transaction timeout`,Session 2 自動通了。生產環境一般設 1~5 分鐘,依應用的正常交易長度而定。

**驗證**:`SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock'` 為 0;庫存 10 → 8 (兩次扣款都成功)。

### 情境 B:deadlock detected

**症狀**:兩個批次同時跑,其中一個隨機失敗,錯誤是 `ERROR: deadlock detected`;單獨跑都正常。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | 讀錯誤的 DETAIL (應用程式 log 或伺服器 log 都有) | `Process 349 waits for ShareLock on transaction 1015; blocked by process 348. Process 348 waits for ShareLock on transaction 1014; blocked by process 349.` — 兩個 pid 互等 |
| 2 | 伺服器 log 的 `HINT: See server log for query details` | 兩邊各卡在哪一句 SQL |
| 3 | 對照那兩段程式碼的加鎖順序 | s1:先 id=1 再 id=2;s2:先 id=2 再 id=1 |

**根因**:兩段程式碼各自正確,但鎖同一組列的**順序相反**。等超過 `deadlock_timeout` (1s) 後 PostgreSQL 偵測到環,中止其中一方 (這次是 Session 1;誰先等超時誰被中止),另一方繼續。被中止的那方的資料**沒有寫進去**。

**修正**:所有交易依同一順序加鎖 (id 由小到大)。腳本裡把 s2 改成也先鎖 id=1:它只是排隊等 s1 COMMIT,然後正常完成 — 「排隊」跟「互鎖」的差別就在順序。多列更新用 `SELECT ... WHERE id IN (...) ORDER BY id FOR UPDATE` 先按序鎖好。

**驗證**:兩個交易都成功,兩列庫存各被扣兩次 (10 → 8)。另外把 `log_lock_waits = on` 打開,等超過 1 秒的鎖會先出現在 log,死鎖發生前就能看到徵兆。

### 情境 C:庫存扣錯 — Lost Update

**症狀**:兩個客戶同時各買一本,庫存卻只少一本;沒有任何錯誤;對帳時才發現訂單數與庫存變化對不上。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | 對帳:訂單數 vs 庫存差 | 賣了 2 本、庫存 10 → 9 |
| 2 | 通用順序第 3 步:沒有錯誤、只是數字錯 → 找「讀 → 算 → 寫回絕對值」的程式碼 | `SELECT stock` → 程式算 `stock - 1` → `UPDATE ... SET stock = 9` |
| 3 | 用腳本重現 | s1 讀到 10、s2 讀到 10,兩邊都算出 9、都寫回 9 |

**根因**:READ COMMITTED 下,`SELECT` 不鎖列,兩個交易讀到同一個值;各自在程式裡計算後寫回**絕對值**,後寫的蓋掉先寫的。DB 完全按規格運作 — 問題出在「讀」與「寫」之間的計算沒有被保護。

**修正 1 (最省事)**:把計算搬進 UPDATE:`SET stock = stock - 1`。UPDATE 會先鎖列;READ COMMITTED 下,排隊的那個交易在拿到鎖後會**重新讀最新值**再計算 (腳本裡 s2 等 s1 COMMIT 後算出 8)。適用於「新值只依賴舊值」的情況。

**修正 2 (計算複雜、要在程式裡做)**:`SELECT ... FOR UPDATE` 先鎖再讀 (13.7),或改用 REPEATABLE READ:腳本裡 s2 在 RR 下讀到 10,s1 改成 9 並 COMMIT 後,s2 的 UPDATE 收到 `SQLSTATE 40001: could not serialize access due to concurrent update`;程式 ROLLBACK 重試,重新讀到 9、寫回 8。**用 RR/SERIALIZABLE 一定要寫重試**,否則使用者看到的就是一個莫名其妙的錯誤。

**驗證**:兩次並發扣款後庫存為 8。

### 情境 D:任務佇列 — 同一個任務被兩個 worker 各做一次

**症狀**:客戶收到兩封一樣的通知信;`jobs` 表看起來正常,每個任務都是 `done`。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | 從執行紀錄找重複 (`GROUP BY job_id HAVING count(*) > 1`) | `job 1 | 2 次 | {worker1, worker2}` |
| 2 | 看 worker 取件的 SQL 有沒有鎖 | `SELECT id ... WHERE status = 'pending' ORDER BY id LIMIT 1` — 沒有 `FOR UPDATE` |
| 3 | 用腳本重現 | 兩個 worker 同時取件,都拿到 job 1 |

**根因**:`SELECT` 不加鎖,兩個 worker 在對方 `UPDATE status = 'done'` 之前都看到 job 1 是 pending。之後兩個 UPDATE 各自成功 (只是把 done 再寫成 done),DB 不會警告 — 跟情境 C 是同一類問題,只是對象從「數字」變成「任務」。

**修正**:`SELECT ... FOR UPDATE SKIP LOCKED`。worker1 鎖住 job 1;worker2 的查詢看到 job 1 被鎖就**直接跳過**拿 job 2,沒有等待 (腳本量到 0.2 ms)。如果只加 `FOR UPDATE` 不加 `SKIP LOCKED`,worker2 會排隊等 worker1 COMMIT — 正確但 worker 之間互相串行,佇列失去平行度。

**驗證**:執行紀錄每個 job 恰好一次;兩個 worker 拿到不同的 job。

**延伸**:任務完成的 `UPDATE` 與取件要在**同一個交易**內 (鎖才會持續到標記完成);worker 當掉時交易 ROLLBACK,任務自動回到 pending 被別人撿走 — 這是 SKIP LOCKED 佇列比「先標記 processing 再處理」更穩的原因。

## 章節腳本

- [`scripts/01-transactions-savepoint.sql`](./scripts/01-transactions-savepoint.sql) — 交易基礎與 SAVEPOINT
- [`scripts/02-isolation-levels.sql`](./scripts/02-isolation-levels.sql) — 隔離等級 (需兩個 session 觀察差異)
- [`scripts/03-row-locking.sql`](./scripts/03-row-locking.sql) — 列鎖 / SKIP LOCKED / NOWAIT / Advisory Lock
- [`scripts/04-troubleshooting-scenarios.sql`](./scripts/04-troubleshooting-scenarios.sql) — 13.11 四個排查情境 (dblink 模擬雙 session,可重現)

---

下一章 ➡ [第 14 章:CTE 與視窗函數](../14-cte-window-functions/)
