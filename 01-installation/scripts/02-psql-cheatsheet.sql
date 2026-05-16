-- =====================================================================
-- psql 常用指令速查 - 在 psql 互動環境中執行
-- 用法:psql -d bookstore  然後逐條輸入下方反斜線指令
-- =====================================================================

-- 〔資料庫層級〕
-- \l                     列出所有資料庫
-- \l+                    列出所有資料庫 (含大小、描述)
-- \c bookstore           切換到 bookstore 資料庫
-- \conninfo              顯示當前連線資訊

-- 〔Schema 與物件〕
-- \dn                    列出 schema
-- \dt                    列出 (當前 schema 的) 資料表
-- \dt shop.*             列出 shop schema 下所有資料表
-- \dt *.*                列出所有 schema 的資料表
-- \dv                    列出 view
-- \di                    列出 index
-- \df                    列出 function
-- \dT                    列出自訂型別

-- 〔結構檢視〕
-- \d                     列出所有物件
-- \d shop.books          顯示資料表詳細結構 (欄位、索引、約束)
-- \d+ shop.books         詳細版 (含註解、儲存)

-- 〔角色與權限〕
-- \du                    列出角色
-- \dp shop.books         顯示表的權限

-- 〔輸出控制〕
-- \x on                  切換成「直立」顯示 (適合欄位多的表)
-- \timing on             顯示每個查詢的執行時間
-- \pset border 2         加粗邊框
-- \pset null '(null)'    將 NULL 顯示為 (null)

-- 〔檔案 I/O〕
-- \i path/to/file.sql    執行外部 SQL 檔
-- \o output.txt          將後續輸出寫入檔案
-- \o                     恢復輸出至螢幕
-- \copy ... FROM 'f.csv' 從 CSV 載入資料 (相對於 client 路徑)

-- 〔系統與幫助〕
-- \?                     列出所有反斜線指令
-- \h SELECT              查詢 SELECT 的語法說明
-- \! ls                  執行 shell 命令
-- \q                     離開

-- 實際示範:檢視 books 表結構
\d shop.books

-- 直立模式
\x on
SELECT * FROM shop.books LIMIT 1;
\x off

-- 顯示執行時間
\timing on
SELECT COUNT(*) FROM shop.order_items;
