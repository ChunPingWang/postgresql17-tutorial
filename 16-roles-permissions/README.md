# 第 16 章 角色與權限管理

> 目標:理解權限為什麼要分層、**開權限前要先決定哪些事**、如何用角色與 RLS 落實最小權限,以及當「明明授權了卻 permission denied」時怎麼有系統地排查。
>
> 🧰 **前置準備**:本章範例使用 `bookstore` 資料庫 (`shop` schema 與範例資料)。尚未建立的話,先在 repo 根目錄執行 `psql -d postgres -f setup/01-create-tutorial-db.sql` 與 `psql -d bookstore -f setup/02-sample-data.sql`,詳見[第 1 章 1.8 節](../01-installation/README.md#18-建立教學用資料庫)。
>
> 📐 **本章讀法**:每一節都先講「為什麼會需要這個」,再講「怎麼做」。16.2 是規劃權限前的決策清單,16.8 是五個可以實際重現的權限故障情境與排查順序 — 建議先讀 16.1~16.2 建立判斷框架,再看語法。

## 16.1 為什麼需要角色與權限

**沒有權限管理會發生什麼**:所有程式、所有人都用同一個超級使用者帳號連線,是最常見的起點,也是最常見的事故來源 — 應用程式的一個 SQL injection 就能 `DROP TABLE`;離職同事的連線字串還在某台機器上;報表工具不小心 `UPDATE` 了正式資料;出事後日誌裡全是同一個帳號,查不出是誰。**權限的目的不是防同事,是限制任何一個出錯點的爆炸半徑。**

**PostgreSQL 怎麼處理**:把「使用者」與「群組」統一成 **Role** (角色),權限則分層掛在資料庫 → schema → 表/欄位/函數上:

- 能登入的 role (`LOGIN`) = 使用者
- 不能登入的 role (`NOLOGIN`) = 群組,只用來集中管理權限
- 一個 role 可以是另一個 role 的成員 (預設繼承其權限)
- 角色是**整個 cluster 共用**的,權限授予則是每個資料庫各自的 — 這個差異在刪角色時會咬人 (16.8 情境 D)

**代價**:多幾個角色、每次 migration 要記得授權 (16.8 情境 A)、除錯時多一層「是不是權限問題」要排除。下一節就是把這些代價事先規劃掉。

## 16.2 設計前的決策條件與考量重點

**為什麼要先想再開**:權限開太寬不會報錯,只會在出事時才發現;開太窄則會在半夜上線時 `permission denied`。而且權限很難「事後收緊」— 一旦應用程式習慣了 superuser,收回時每個功能都可能斷。一開始就規劃,比事後遷移便宜得多。

### 先確認的前提

| 問題 | 為什麼重要 | 怎麼確認 |
|------|-----------|---------|
| **誰會連進來?人還是程式?** | 人需要個別帳號 (可稽核、可離職停用);程式需要固定角色 + 密碼輪替。混用會讓稽核失去意義 | 列出所有連線來源:應用程式、排程、報表工具、DBA、開發者 |
| **每個連線者「業務上」需要做什麼?** | 最小權限的前提是知道需求。報表只需 SELECT;應用程式通常不需要 DDL、不需要 DELETE 整表 | 對照應用程式實際發出的 SQL (`pg_stat_statements` 依 `userid` 分組) |
| **誰負責建表、改表 (migration)?** | 建物件的角色會成為 owner,而 owner 天生擁有全部權限且**預設繞過 RLS**。應用程式角色不該是 owner | 決定一個 migration/owner 角色,應用程式另用角色 |
| **有沒有多租戶 / 資料列層級的隔離需求?** | 決定要用 RLS、還是每租戶一個 schema/資料庫、還是在應用層過濾 | 租戶數量、是否共用表結構、是否有跨租戶查詢 |
| **連線從哪裡來?** | `pg_hba.conf` 依來源位址與方法控制;本機 socket 與跨網路的認證方式應該不同 | 網段清單、是否走連線池、是否需要 TLS/憑證 |
| **稽核與合規要求?** | 決定要不要 `log_connections`、pgaudit、密碼有效期限 | 看公司/法規要求,而不是事後補 |

### 決策對照:什麼情況選什麼

| 情況 | 選擇 | 理由 |
|------|------|------|
| 很多人/程式需要同一組權限 | **群組角色 (NOLOGIN)** 集中授權,登入角色只做成員 | 權限改一處生效;新人只要 `GRANT 群組 TO 新帳號` |
| 應用程式連線 | 專用 `LOGIN` 角色 + `CONNECTION LIMIT` + `statement_timeout`,**永遠不是 superuser、不是 owner** | 限制爆炸半徑;失控查詢自動被砍 |
| 建表 / migration | 獨立 owner 角色 (NOLOGIN),由 CI 或 DBA `SET ROLE` 使用 | owner 權限與應用程式權限分離;RLS 才不會被 owner 繞過 |
| 未來會持續新增表 | `ALTER DEFAULT PRIVILEGES FOR ROLE <owner> IN SCHEMA ...` | `GRANT ... ON ALL TABLES` 只對「當下已存在」的表有效 (16.8 情境 A) |
| 只需要看部分欄位 | 欄位層級 `GRANT SELECT (col1, col2)` 或 view | 不用複製資料就能隱藏敏感欄位 |
| 多租戶、共用表、租戶數多 | **RLS** + `FORCE ROW LEVEL SECURITY` + 應用程式每交易 `SET LOCAL app.tenant_id` | 一次定義、所有查詢路徑都受約束;租戶數上萬也不用上萬個 schema |
| 租戶少、需要各自備份/搬遷 | 每租戶一個 schema 或資料庫 | 隔離最徹底,但 migration 要跑 N 次 |
| 需要「受控提權」(例如讓一般使用者呼叫某個需要高權限的操作) | `SECURITY DEFINER` 函數 + **固定 `search_path`** | 只開一個窄門,而不是給整個權限 (16.8 情境 E) |
| 本機開發 | `pg_hba.conf` 用 `peer`/`trust` 限定 local socket | 方便,而且不暴露到網路 |
| 跨網路連線 | `scram-sha-256` + 限定來源網段;高安全需求用 `cert` | 密碼不以可逆形式傳輸;縮小可嘗試登入的來源 |

### 上線時的考量

- **PG 15 起 `public` schema 不再讓所有人 `CREATE`**:舊教學裡「任何人都能在 public 建表」已不成立;反過來,若你的舊 cluster 升級上來,`public` 仍是開放的,值得主動 `REVOKE CREATE ON SCHEMA public FROM PUBLIC` (16.8 情境 E 示範為什麼)。
- **密碼與有效期**:`VALID UNTIL` 給臨時帳號;正式帳號靠輪替流程,不靠永不過期。輪替時先建新密碼、切換應用程式、再收回舊的。
- **每個資料庫都要授權**:`GRANT CONNECT ON DATABASE` 與 schema/表授權是每個資料庫各自的;角色本身是 cluster 層級的。`DROP ROLE` 前要在**每個**資料庫 `REASSIGN OWNED` / `DROP OWNED` (16.8 情境 D)。
- **RLS 的三個常見漏洞**:owner、superuser、`BYPASSRLS` 角色預設不受約束;session 參數沒設時 policy 常常是「靜默 0 列」而不是報錯;連線池會重用 session,參數要用 `SET LOCAL` 綁在交易內 (16.8 情境 C)。
- **稽核**:`log_connections = on`、`log_disconnections = on` 成本很低;需要記錄「誰改了什麼」用 pgaudit 或第 12 章的稽核 trigger。
- **驗證再收工**:授權完用 `SET ROLE <角色>` 實際跑一次應用程式會用到的 SQL,不要只看 `\dp`。「權限存在」跟「這個角色真的做得到」是兩件事 — 少一層 (schema USAGE、sequence、function EXECUTE) 就會失敗 (16.8 情境 B)。

## 16.3 建立角色

**為什麼要區分 LOGIN / NOLOGIN、要有效期限**:不能登入的角色是「權限的容器」,把權限掛在它身上,人來人去只改成員關係;`VALID UNTIL` 讓臨時帳號自動失效,不必靠人記得收回;`SUPERUSER` 沒有任何權限檢查,連 RLS 都繞過,只該給 DBA 本人。

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

## 16.4 GRANT / REVOKE

### 物件權限

**為什麼是分層的**:要讀一張表,得先能連進資料庫 (`CONNECT`)、走進 schema (`USAGE`)、才輪到表本身 (`SELECT`)。任何一層缺了,錯誤訊息會說出卡在哪一層 — 「permission denied for **schema**」和「permission denied for **table**」是不同的問題 (16.8 情境 B)。`INSERT` 到有 `SERIAL` 的表還需要 sequence 的 `USAGE`,這是最常被漏掉的一層。

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

**為什麼需要**:`GRANT ... ON ALL TABLES IN SCHEMA` 只是把「執行當下存在的表」逐一授權,下週 migration 新增的表不會自動繼承 — 這是「上週還好好的,新功能一上線就 permission denied」的標準劇情 (16.8 情境 A)。

**怎麼做**:`ALTER DEFAULT PRIVILEGES` 定義「之後建的物件自動給誰什麼」。注意它綁定的是**建立物件的那個角色**:不寫 `FOR ROLE` 就是「執行這句的人自己建的物件」,若表實際是由 migration 角色建的,就要寫 `FOR ROLE migration_role`。

```sql
-- 未來在 shop schema 建立的表都自動給 readonly 讀取
ALTER DEFAULT PRIVILEGES IN SCHEMA shop
    GRANT SELECT ON TABLES TO readonly;

-- 表是由 migration 角色建的時候,要指定 FOR ROLE
ALTER DEFAULT PRIVILEGES FOR ROLE migration_role IN SCHEMA shop
    GRANT SELECT ON TABLES TO readonly;
```

### 成員關係

**為什麼用群組而不是逐人授權**:10 個開發者 × 30 張表 = 300 條 GRANT,而且新增一張表要補 10 條。改成「權限掛在群組、人只是成員」,新人一句 `GRANT readwrite TO 新人`,離職一句 `REVOKE`。

```sql
-- 把 alice 加入 readwrite 群組
GRANT readwrite TO alice;

-- alice 繼承 readwrite 的所有權限
-- 如果不要繼承:GRANT readwrite TO alice WITH INHERIT FALSE;

-- 移除
REVOKE readwrite FROM alice;
```

### 查看權限

**為什麼要會查**:排查權限問題的第一步永遠是「現在到底有什麼」,而不是再 GRANT 一次。`has_*_privilege()` 系列函數可以直接問「這個角色對這個物件有沒有這個權限」,比讀 ACL 字串快。

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

-- 直接問:這個角色做得到嗎?
SELECT has_database_privilege('alice', 'bookstore', 'CONNECT'),
       has_schema_privilege('alice', 'shop', 'USAGE'),
       has_table_privilege('alice', 'shop.books', 'SELECT');
```

## 16.5 最小權限原則 (Principle of Least Privilege)

**為什麼**:每多給一個權限,就是多一個「出錯時能造成的損害」。應用程式角色只給業務需要的操作,不給 DDL、不給不相關的表,SQL injection 或程式 bug 的爆炸半徑就被限制在那幾張表的那幾種操作。

**設計模式**:
```
superuser (你)
    ├── migration/owner 角色 (NOLOGIN)   ← 建表、改表,由 CI/DBA SET ROLE 使用
    └── 應用程式群組 (app_role)          ← 只有業務需要的操作
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

## 16.6 Row Level Security (RLS)

**為什麼**:「客戶只能看自己的訂單」如果只靠應用程式在每條 SQL 加 `WHERE customer_id = ?`,漏掉一條就是資料外洩,而且報表工具、ad-hoc 查詢根本不經過應用程式。RLS 把這個條件變成表的一部分:不管誰、從哪裡查,PostgreSQL 都自動套上。

**怎麼做**:`ENABLE ROW LEVEL SECURITY` 後,沒有任何 policy 允許的列一律看不到;policy 的 `USING` 決定看得到哪些列、`WITH CHECK` 決定寫得進哪些列。條件通常靠 session 參數 (`current_setting`) 帶入「現在是誰」。

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

**三個一定要知道的坑** (16.8 情境 C 會實際重現):
1. 表的 **owner、superuser、`BYPASSRLS` 角色預設不受 RLS 約束** — 用 owner 測試永遠「看起來沒生效」,要 `FORCE ROW LEVEL SECURITY` 或改用應用角色測。
2. 參數沒設時 `current_setting('app.x', true)` 回 NULL,`col = NULL` 不為 true → **靜默回 0 列**,不報錯。
3. 連線池會重用 session:參數用 `SET LOCAL` (或 `set_config(..., true)`) 綁在交易內,交易結束自動清掉,不會漏給下一個租戶。

## 16.7 pg_hba.conf — 連線認證

**為什麼**:角色與密碼只回答「你是誰」;`pg_hba.conf` 回答「從哪裡、用什麼方式,可以嘗試證明你是誰」。同一個帳號,本機 socket 可以 `peer` 免密碼,跨網路則必須 `scram-sha-256`,不在清單內的來源直接拒絕 — 這是縮小攻擊面的第一道門。規則**由上而下第一條符合的生效**,順序錯了會讓寬鬆規則先吃掉。

位於 `/opt/homebrew/var/postgresql@17/pg_hba.conf` (其他環境用 `SHOW hba_file;` 查):

```
# TYPE  DATABASE  USER  ADDRESS    METHOD
local   all       all              trust        # 本機 socket
host    all       all   127.0.0.1  scram-sha-256
host    all       all   ::1/128    scram-sha-256
```

常用 METHOD:
- `trust` — 不驗證密碼 (本機開發用)
- `peer` — 以 OS 使用者身份對應 (local socket 專用,Linux 套件預設)
- `md5` — MD5 雜湊密碼 (舊,建議改 scram)
- `scram-sha-256` — 更安全的密碼驗證 (推薦)
- `cert` — 用戶端憑證
- `reject` — 拒絕所有

修改後執行 `SELECT pg_reload_conf();` 或 `pg_ctl reload` 即可套用;`SELECT * FROM pg_hba_file_rules;` 可以檢查載入結果與語法錯誤。

## 16.8 問題排查:情境模擬與排查順序

**為什麼要練這個**:權限問題有兩種面貌 — 一種是明確的 `permission denied`,但訊息指的層級常被誤讀,於是「再 GRANT 一次」也沒用;另一種是 RLS 這類**完全不報錯**的靜默失敗,看起來像資料不見了。兩種都需要「先確認事實再動手」的順序。

> 🧪 所有情境都在 [`scripts/03-troubleshooting-scenarios.sql`](./scripts/03-troubleshooting-scenarios.sql) 裡,以超級使用者執行,用 `SET ROLE` 在同一個 session 扮演受限角色,demo 角色以 `ts_` 開頭、跑完自動清除。預期失敗的操作都包在 `DO ... EXCEPTION` 裡,所以腳本本身不會出現 ERROR。

### 通用排查順序:「permission denied / 看不到資料」

```
1. 把錯誤訊息讀完:它說的是 database / schema / table / column / sequence / function 哪一層?
   → 不同層級要補的權限不同,「再 GRANT 表一次」對 schema 的錯沒用
2. 現在的身份到底是誰?
   → SELECT current_user, session_user;  (SET ROLE、連線池、SECURITY DEFINER 都會改變它)
3. 逐層問「做得到嗎」,而不是讀 ACL 猜
   → has_database_privilege / has_schema_privilege / has_table_privilege / has_sequence_privilege
4. 物件是誰的?什麼時候建的?
   → pg_class.relowner;新建的表很可能沒被 ALTER DEFAULT PRIVILEGES 涵蓋
5. 沒報錯但資料不對 → 想 RLS
   → pg_class.relrowsecurity / relforcerowsecurity;pg_policies;誰是 owner / BYPASSRLS;session 參數現在的值
6. 才動手修
   → 補該層的 GRANT > 設 DEFAULT PRIVILEGES (含 FOR ROLE) > 修 policy / FORCE RLS > 調 pg_hba.conf
7. 驗證:SET ROLE <角色> 實際跑應用程式的 SQL,再 RESET ROLE
```

### 情境 A:上週授權過了,新加的表卻 permission denied

**症狀**:上線初期 `GRANT SELECT ON ALL TABLES IN SCHEMA` 一切正常;這週 migration 新增 `coupons` 表,應用程式立刻報 `permission denied for table coupons`,舊的表都還好好的。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | `SET ROLE ts_app` 重現 | `products` (舊表) 可讀 1 列;`coupons` (新表) `permission denied for table coupons (SQLSTATE 42501)` |
| 2 | 比對兩張表的 `relacl` | `products` 有 `ts_app=r/ts_owner`;`coupons` 的 `relacl` **是空的** |
| 3 | `pg_default_acl` 有沒有預設權限? | `0 rows` — 從來沒設過 |

**根因**:`GRANT ... ON ALL TABLES IN SCHEMA` 是「對當下存在的每張表各 GRANT 一次」,不是規則;之後建的表 ACL 是空的。

**修正**:`ALTER DEFAULT PRIVILEGES`。但有一個第二層陷阱:超級使用者直接下 `ALTER DEFAULT PRIVILEGES IN SCHEMA ts_perm GRANT SELECT ON TABLES TO ts_app` 之後,再建的 `shipments` **還是** `app_can_select = f` — 因為沒寫 `FOR ROLE`,這條規則只對「postgres 自己建的表」生效,而表是 `ts_owner` 建的。正確寫法:

```sql
ALTER DEFAULT PRIVILEGES FOR ROLE ts_owner IN SCHEMA ts_perm GRANT SELECT ON TABLES TO ts_app;
GRANT SELECT ON ALL TABLES IN SCHEMA ts_perm TO ts_app;   -- 已存在的表還是要補一次
```

**驗證**:之後建的 `returns` 表 `app_can_select = t`;`pg_default_acl` 出現 `for_role = ts_owner` 那一列。

### 情境 B:表明明 GRANT 了,還是 permission denied

**症狀**:`GRANT SELECT ON ts_perm.products TO ts_report` 下過了,查詢仍失敗 — 但仔細看訊息是 `permission denied for **schema** ts_perm`,不是 table。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | 重現並讀完訊息 | 錯的是 schema 層 |
| 2 | 分層問 `has_*_privilege` | `db_connect = t`、`schema_usage = **f**`、`table_select = t` |

**根因**:權限分層 — 走進 schema 需要 `USAGE`;表的 `SELECT` 有了但進不了門。同類漏層還有 `INSERT` 缺 sequence `USAGE`、呼叫函數缺 `EXECUTE`。

**修正**:`GRANT USAGE ON SCHEMA ts_perm TO ts_report;`

**驗證**:`SET ROLE ts_report` 後 `count(*)` = 1 列。

### 情境 C:RLS 政策「沒有作用」— 一下什麼都看不到,一下全看到

**症狀 C-1**:應用角色查 `tenant_orders` 回 **0 列**,沒有任何錯誤。
**症狀 C-2**:用 owner 連線測試,設定了 `app.tenant_id = '1'` 卻看到全部 3 列。

**排查順序與線索 (C-1)**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | `SET ROLE ts_app` 查詢 | `rows_seen_by_app = 0`,無錯誤 |
| 2 | 看 `pg_policies.qual` 與參數現值 | qual 是 `tenant_id = current_setting('app.tenant_id', true)::integer`;`tenant_setting` 為空、`setting_is_null = t`、`condition_result` 為 NULL |

**根因**:這個 session 從未設定 `app.tenant_id`,`current_setting(..., true)` 回 NULL,`tenant_id = NULL` 是 NULL,USING 不為 true → 每列都被濾掉,**靜默**。連線池重用連線、應用程式忘了在交易開頭 SET,都會走到這裡。

**修正**:把「沒設定」變成明確錯誤。用一個函數包住參數讀取,NULL **或空字串** (設定過又 `RESET` 後的值不是 NULL 而是 `''`,腳本有示範) 就 `RAISE EXCEPTION`,policy 改呼叫它。

**驗證**:沒設定 → `app.tenant_id 未設定 — 應用程式必須在每個交易開頭 SET LOCAL app.tenant_id`;`set_config('app.tenant_id','1', true)` 後 → 剛好 2 列。

**排查順序與線索 (C-2)**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | `SET ROLE ts_owner` + 設定租戶 1 查詢 | `rows_seen_by_owner = 3` |
| 2 | 查 `pg_class` 的 `relrowsecurity / relforcerowsecurity / relowner` 與 `pg_roles` 的 `rolsuper / rolbypassrls` | `rls_enabled = t`、`rls_forced = **f**`、owner 是 `ts_owner`;`postgres` 是 superuser + bypassrls |

**根因**:RLS 預設不約束 owner;superuser 與 `BYPASSRLS` 角色也一律略過。用 owner 測 RLS 永遠測不出來。

**修正**:`ALTER TABLE ... FORCE ROW LEVEL SECURITY;`,並且應用程式不要用 owner 連線。

**驗證**:owner 也只剩 2 列。

### 情境 D:離職同事的帳號刪不掉

**症狀**:`DROP ROLE ts_leaver` → `role "ts_leaver" cannot be dropped because some objects depend on it`。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | 重現並讀 `DETAIL` | 列出依賴:owner of table `leaver_notes`、owner of view `v_products`、privileges for schema `ts_perm` |
| 2 | 查他擁有的物件 (`pg_class.relowner`) 與被授予的權限 (`relacl LIKE '%ts_leaver%'`) | 2 個物件是他的;`products` 的 ACL 裡有 `ts_leaver=r` |

**根因**:角色是 cluster 層級,但它擁有的物件與被授予的權限散在各資料庫;任何一個還在就不能刪。物件不能沒有 owner,所以要先轉手。

**修正** (在**每一個**該角色有物件的資料庫各跑一次):

```sql
REASSIGN OWNED BY ts_leaver TO ts_owner;   -- 擁有權轉給接手的角色
DROP OWNED BY ts_leaver;                    -- 剩下的授權全部清掉
DROP ROLE ts_leaver;
```

**驗證**:`leaver_notes` / `v_products` 還在、owner 變成 `ts_owner`;`pg_roles` 裡已無 `ts_leaver`。

### 情境 E:SECURITY DEFINER 函數被 search_path 劫持

**症狀**:`masked_products()` 是以 owner 權限執行、負責遮罩資料的函數;某個低權限使用者呼叫後拿到了**未遮罩**的資料 `widget (leaked!)`。

**排查順序與線索**:

| 步驟 | 做什麼 | 看到什麼 |
|------|-------|---------|
| 1 | 以 `ts_app` 正常呼叫 | `wi***` |
| 2 | `ts_app` 在 `public` 建一個同名 `mask(text)`,`search_path = public, ts_perm`,再呼叫 | `widget (leaked!)` — 函數執行了呼叫者的程式碼 |
| 3 | 找出所有「沒固定 search_path 的 SECURITY DEFINER 函數」:`pg_proc` 中 `prosecdef` 且 `proconfig` 不含 `search_path` | `masked_products()` 的 `proconfig` 為空 |

**根因**:`SECURITY DEFINER` 以 owner 權限執行,但 `search_path` 沿用**呼叫者**的;函數內沒寫 schema 的 `mask(name)` 會先在 `public` 找到呼叫者放的假函數。這正是 PG 15 起 `public` 不再讓所有人 `CREATE` 的原因 (腳本為了重現,刻意 `GRANT CREATE ON SCHEMA public`)。

**修正**:`ALTER FUNCTION ts_perm.masked_products() SET search_path = ts_perm, pg_temp;` (第 3 章 3.7 節的建議,建立函數時就該加)。

**驗證**:同樣的假函數還在,結果恢復 `wi***`。

## 章節腳本

- [`scripts/01-roles-and-grants.sql`](./scripts/01-roles-and-grants.sql) — 群組角色、應用角色、授權與預設權限
- [`scripts/02-row-level-security.sql`](./scripts/02-row-level-security.sql) — RLS 依 customer_id 隔離
- [`scripts/03-troubleshooting-scenarios.sql`](./scripts/03-troubleshooting-scenarios.sql) — 16.8 五個排查情境 (可重現)

---

下一章 ➡ [第 17 章:備份與還原](../17-backup-restore/)
