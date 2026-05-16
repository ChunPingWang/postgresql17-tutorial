# 第 13 章 交易與並發控制

> 目標:掌握 ACID 特性、交易隔離等級、鎖的種類與死鎖處理。

## 13.1 ACID 特性

| 特性 | 說明 |
|------|------|
| **A**tomicity (原子性) | 全成功或全失敗,沒有「部分完成」 |
| **C**onsistency (一致性) | 交易前後資料庫都符合所有約束 |
| **I**solation (隔離性) | 並發交易互不干擾 (視等級而定) |
| **D**urability (持久性) | 提交後即使當機也不丟失 |

## 13.2 基本交易語法

```sql
BEGIN;              -- 開始交易
-- ... SQL ...
COMMIT;             -- 提交 (確認)
ROLLBACK;           -- 回滾 (取消)

-- 或用 START TRANSACTION (等價)
START TRANSACTION;
```

### SAVEPOINT

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

## 13.3 並發問題

| 問題 | 說明 |
|------|------|
| **Dirty Read** | 讀到另一個未提交交易寫的資料 |
| **Non-repeatable Read** | 同一 query 在交易內執行兩次,結果不同 |
| **Phantom Read** | 同一查詢條件在交易內兩次,第二次多了(或少了)列 |
| **Serialization Anomaly** | 並發結果無法等價於任何一種順序執行 |

## 13.4 隔離等級

```sql
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;   -- 預設
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
-- (PostgreSQL 不實作 READ UNCOMMITTED,等同 READ COMMITTED)
```

| 等級 | Dirty Read | Non-rep Read | Phantom Read |
|------|-----------|--------------|--------------|
| READ COMMITTED | 不可能 | 可能 | 可能 |
| REPEATABLE READ | 不可能 | 不可能 | 不可能 (PG) |
| SERIALIZABLE | 不可能 | 不可能 | 不可能 |

> PostgreSQL 的 REPEATABLE READ 用 MVCC 實作,連 Phantom Read 也防住了。SERIALIZABLE 則用 SSI (Serializable Snapshot Isolation)。

## 13.5 MVCC (多版本並發控制)

PostgreSQL **不用讀鎖** (Reader never blocks writer),而是用 MVCC:
- 每列有 `xmin` (建立交易 ID) 和 `xmax` (刪除交易 ID)
- 每個交易看到的是**交易開始時的快照**
- 舊版本由 `VACUUM` 清理

```sql
-- 可以看到隱含的系統欄位
SELECT xmin, xmax, ctid, id, title FROM shop.books LIMIT 3;
```

## 13.6 鎖 (Locking)

### 資料表鎖

| 鎖等級 | 典型操作 |
|--------|---------|
| ACCESS SHARE | `SELECT` |
| ROW SHARE | `SELECT FOR UPDATE/SHARE` |
| ROW EXCLUSIVE | `INSERT/UPDATE/DELETE` |
| SHARE UPDATE EXCLUSIVE | `VACUUM`, `CREATE INDEX CONCURRENTLY` |
| SHARE | `CREATE INDEX` |
| EXCLUSIVE | 少見 |
| ACCESS EXCLUSIVE | `ALTER TABLE`, `DROP TABLE` |

```sql
-- 顯式鎖表 (通常不需要)
LOCK TABLE shop.books IN SHARE MODE;
```

### 列鎖 (Row Lock)

```sql
-- FOR UPDATE:取得 exclusive 鎖,阻止其他人修改或再 FOR UPDATE
SELECT * FROM shop.books WHERE id = 1 FOR UPDATE;

-- FOR SHARE:允許其他人讀,但不能修改
SELECT * FROM shop.books WHERE id = 1 FOR SHARE;

-- SKIP LOCKED:跳過已被鎖的列 (任務佇列常用)
SELECT * FROM shop.orders WHERE status = 'pending'
ORDER BY id LIMIT 1
FOR UPDATE SKIP LOCKED;

-- NOWAIT:若鎖不到立即報錯
SELECT * FROM shop.books WHERE id = 1 FOR UPDATE NOWAIT;
```

## 13.7 Deadlock

當兩個交易互相等待對方釋放鎖,就形成死鎖。PostgreSQL **自動偵測並殺掉其中一個**。

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

**防止死鎖**:所有交易**按相同順序**加鎖 (例如永遠先鎖 id 小的)。

## 13.8 查看鎖定狀態

```sql
-- 目前所有鎖
SELECT pid, locktype, relation::regclass, mode, granted
FROM pg_locks
WHERE relation IS NOT NULL
ORDER BY relation;

-- 正在等鎖的查詢
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

## 13.9 Advisory Lock

應用層可自訂的邏輯鎖:

```sql
-- Session-level (直到斷線才釋放)
SELECT pg_advisory_lock(12345);
SELECT pg_advisory_unlock(12345);

-- Transaction-level (COMMIT/ROLLBACK 自動釋放)
SELECT pg_advisory_xact_lock(12345);

-- 嘗試取鎖,失敗回 false
SELECT pg_try_advisory_lock(12345);
```

常用於：確保只有一個程序跑批次任務。

## 章節腳本

- [`scripts/01-transactions-savepoint.sql`](./scripts/01-transactions-savepoint.sql)
- [`scripts/02-isolation-levels.sql`](./scripts/02-isolation-levels.sql)
- [`scripts/03-row-locking.sql`](./scripts/03-row-locking.sql)

---

下一章 ➡ [第 14 章:CTE 與視窗函數](../14-cte-window-functions/)
