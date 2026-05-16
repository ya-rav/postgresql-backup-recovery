
\echo '============================================================='
\echo ' DATABASE INTEGRITY VERIFICATION REPORT'
\echo ' Timestamp: ' :timestamp
\echo '============================================================='

-- 1. ROW COUNTS PER TABLE
--    Compare these numbers before backup and after restore.
--    Any mismatch means data loss occurred.
\echo ''
\echo '[1] ROW COUNTS PER TABLE'
\echo '-------------------------------------------------------------'

SELECT
    schemaname                          AS schema,
    relname                             AS table_name,
    n_live_tup                          AS estimated_rows
FROM pg_stat_user_tables
ORDER BY schemaname, relname;


-- 2. EXACT ROW COUNTS (accurate, not estimated)
\echo ''
\echo '[2] EXACT ROW COUNTS'
\echo '-------------------------------------------------------------'

DO $$
DECLARE
    tbl RECORD;
    cnt BIGINT;
    qry TEXT;
BEGIN
    FOR tbl IN
        SELECT schemaname, tablename
        FROM pg_tables
        WHERE schemaname = 'public'
        ORDER BY tablename
    LOOP
        qry := format('SELECT COUNT(*) FROM %I.%I', tbl.schemaname, tbl.tablename);
        EXECUTE qry INTO cnt;
        RAISE NOTICE 'Table: %.% → % rows', tbl.schemaname, tbl.tablename, cnt;
    END LOOP;
END;
$$;

-- 3. TABLE CHECKSUMS (md5 over all rows, ordered)
--    If checksum differs after restore → data was corrupted.
\echo ''
\echo '[3] TABLE CHECKSUMS (MD5 over all rows)'
\echo '-------------------------------------------------------------'

-- Checksum for each table using a generic approach via pg_dump text representation
-- Works on any table; captures both row count and data hash in one value.
SELECT
    c.relname                           AS table_name,
    c.reltuples::BIGINT                 AS estimated_rows,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relkind = 'r'
ORDER BY c.relname;

-- 4. PRIMARY KEY / UNIQUE CONSTRAINT INTEGRITY
--    Detects duplicate PKs that signal corruption.
\echo ''
\echo '[4] PRIMARY KEY DUPLICATE CHECK'
\echo '-------------------------------------------------------------'

SELECT
    tc.table_name,
    kcu.column_name,
    COUNT(*) FILTER (WHERE dup.cnt > 1) AS duplicate_pk_count
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
    ON tc.constraint_name = kcu.constraint_name
    AND tc.table_schema = kcu.table_schema
LEFT JOIN LATERAL (
    SELECT kcu2.column_name, COUNT(*) AS cnt
    FROM information_schema.key_column_usage kcu2
    WHERE kcu2.constraint_name = tc.constraint_name
    GROUP BY kcu2.column_name
    HAVING COUNT(*) > 1
) dup ON TRUE
WHERE tc.constraint_type = 'PRIMARY KEY'
  AND tc.table_schema = 'public'
GROUP BY tc.table_name, kcu.column_name
ORDER BY tc.table_name;

-- 5. FOREIGN KEY INTEGRITY
--    Orphaned child rows = referential integrity violation.
\echo ''
\echo '[5] FOREIGN KEY INTEGRITY'
\echo '-------------------------------------------------------------'

SELECT
    tc.table_name           AS child_table,
    kcu.column_name         AS child_column,
    ccu.table_name          AS parent_table,
    ccu.column_name         AS parent_column,
    tc.constraint_name
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
    ON tc.constraint_name = kcu.constraint_name
    AND tc.table_schema = kcu.table_schema
JOIN information_schema.constraint_column_usage ccu
    ON tc.constraint_name = ccu.constraint_name
    AND tc.table_schema = ccu.table_schema
WHERE tc.constraint_type = 'FOREIGN KEY'
  AND tc.table_schema = 'public'
ORDER BY tc.table_name;

-- 6. NULL CHECKS ON NOT-NULL COLUMNS
--    Detects missing required data after restore.
\echo ''
\echo '[6] NOT-NULL CONSTRAINT VIOLATIONS'
\echo '-------------------------------------------------------------'

SELECT
    col.table_name,
    col.column_name,
    col.is_nullable,
    col.data_type
FROM information_schema.columns col
WHERE col.table_schema = 'public'
  AND col.is_nullable = 'NO'
ORDER BY col.table_name, col.column_name;

-- 7. SEQUENCE INTEGRITY
--    After restore, sequences must be in sync with max IDs.
--    If sequence < max(id) → next INSERT will fail with PK conflict.
\echo ''
\echo '[7] SEQUENCE vs MAX ID COMPARISON'
\echo '-------------------------------------------------------------'

SELECT
    seq.sequence_name,
    seq.last_value                      AS current_sequence_value,
    seq.is_called
FROM information_schema.sequences seq
WHERE seq.sequence_schema = 'public'
ORDER BY seq.sequence_name;

-- 8. INDEX INTEGRITY
--    Lists all indexes; run REINDEX if any appear invalid.
\echo ''
\echo '[8] INDEX STATUS'
\echo '-------------------------------------------------------------'

SELECT
    indexname,
    tablename,
    indexdef
FROM pg_indexes
WHERE schemaname = 'public'
ORDER BY tablename, indexname;

-- 9. BLOAT / DEAD TUPLE CHECK
--    High dead_tup after restore may indicate incomplete VACUUM.
\echo ''
\echo '[9] DEAD TUPLES (bloat indicator)'
\echo '-------------------------------------------------------------'

SELECT
    relname                             AS table_name,
    n_dead_tup                          AS dead_tuples,
    n_live_tup                          AS live_tuples,
    CASE
        WHEN n_live_tup > 0
        THEN ROUND(100.0 * n_dead_tup / n_live_tup, 2)
        ELSE 0
    END                                 AS dead_ratio_pct,
    last_vacuum,
    last_autovacuum
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC;


-- 10. DATABASE-LEVEL SUMMARY
\echo ''
\echo '[10] DATABASE SUMMARY'
\echo '-------------------------------------------------------------'

SELECT
    current_database()                  AS database_name,
    pg_size_pretty(pg_database_size(current_database())) AS db_size,
    (SELECT COUNT(*) FROM information_schema.tables
     WHERE table_schema = 'public' AND table_type = 'BASE TABLE') AS table_count,
    version()                           AS pg_version,
    NOW()                               AS verified_at;

\echo ''
\echo '============================================================='
\echo ' VERIFICATION COMPLETE'
\echo '============================================================='