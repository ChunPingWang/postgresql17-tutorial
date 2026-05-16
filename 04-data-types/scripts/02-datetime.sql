-- =====================================================================
-- 第 4 章 / 日期時間
-- =====================================================================

-- 〔1〕基本當下時間 (留意三者差異)
SELECT
    NOW()              AS now_func,         -- 包含時區 (timestamptz)
    CURRENT_TIMESTAMP  AS now_keyword,      -- 同上
    LOCALTIMESTAMP     AS local_ts,         -- 不含時區
    CURRENT_DATE       AS today,
    CURRENT_TIME       AS time_now;

-- 〔2〕TIMESTAMP vs TIMESTAMPTZ 行為
DROP TABLE IF EXISTS ts_demo;
CREATE TABLE ts_demo (
    label TEXT,
    plain TIMESTAMP,
    withz TIMESTAMPTZ
);

SET timezone = 'Asia/Taipei';
INSERT INTO ts_demo VALUES ('輸入 Taipei', '2026-01-01 12:00', '2026-01-01 12:00');
SELECT * FROM ts_demo;
\echo '↑ Taipei 時區下顯示'

SET timezone = 'UTC';
SELECT * FROM ts_demo;
\echo '↑ UTC 顯示:withz 自動轉成 04:00 UTC,plain 仍是 12:00 (沒時區資訊)'

-- 〔3〕日期運算
SET timezone = 'Asia/Taipei';
SELECT
    NOW() + INTERVAL '7 days'           AS one_week_later,
    NOW() - INTERVAL '1 month'          AS one_month_ago,
    AGE('2000-01-01'::date)             AS age_since_2000,
    EXTRACT(YEAR  FROM NOW())           AS yr,
    EXTRACT(MONTH FROM NOW())           AS mo,
    EXTRACT(DOW   FROM NOW())           AS day_of_week, -- 0=Sun
    DATE_TRUNC('month', NOW())          AS month_start,
    DATE_TRUNC('quarter', NOW())        AS quarter_start;

-- 〔4〕格式化
SELECT
    TO_CHAR(NOW(), 'YYYY-MM-DD HH24:MI:SS TZ') AS formatted,
    TO_CHAR(NOW(), 'Day, Month DD')           AS readable,
    TO_DATE('2026/05/16', 'YYYY/MM/DD')       AS parsed_date;

-- 〔5〕產生序列 (常用於補滿日期)
SELECT generate_series(
    '2026-01-01'::date,
    '2026-01-07'::date,
    INTERVAL '1 day'
)::date AS d;

-- 〔6〕Interval 算術
SELECT
    INTERVAL '1 year 2 mons 3 days' AS i1,
    INTERVAL '90 days'              AS i2,
    JUSTIFY_DAYS(INTERVAL '90 days') AS i2_justified;  -- 3 mons

DROP TABLE ts_demo;
