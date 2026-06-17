-- ════════════════════════════════════════════════════════════════════════════
-- audit-grants-bundle-shape.sql — Pre-D-Prep diagnostic
-- ════════════════════════════════════════════════════════════════════════════
-- Purpose: confirm the assumption that >99% of existing `storage.access_grants`
-- rows already cluster into the standard role bundles
-- (viewer / commenter / contributor / editor / owner). The answer determines
-- whether the access_grants → role_grants migration is fully mechanical (just
-- run the backfill) or whether per-row decisions are needed for some edge
-- cases.
--
-- READ-ONLY. Safe to run against any environment including production.
--
-- Usage:
--   psql "$DATABASE_URL" -f tools/audit-grants-bundle-shape.sql
--
-- Reference role bundles (mirror `Role::expand()` in
-- `src/application/dtos/grant_dto.rs`):
--   viewer      = {read}
--   commenter   = {read, comment}                        ← reserved variant
--   contributor = {read, create}                         ← new in D-Prep
--   editor      = {read, comment, create, update}
--   owner       = {read, comment, create, update, share, delete}
--                 (post-D-Prep: + manage, when Group-as-Resource lands)
-- ════════════════════════════════════════════════════════════════════════════


\echo ''
\echo '─────────────────────────────────────────────────────────────────────────'
\echo ' 0. Total population'
\echo '─────────────────────────────────────────────────────────────────────────'

SELECT count(*)                          AS total_grant_rows,
       count(DISTINCT (subject_type, subject_id, resource_type, resource_id))
                                         AS distinct_clusters,
       ROUND(
         count(*)::numeric
         / NULLIF(count(DISTINCT (subject_type, subject_id, resource_type, resource_id)), 0),
         2
       )                                 AS avg_rows_per_cluster
FROM storage.access_grants;


\echo ''
\echo '─────────────────────────────────────────────────────────────────────────'
\echo ' 1. Bundle distribution — which permission sets exist, how popular?'
\echo '─────────────────────────────────────────────────────────────────────────'
\echo ' Each row = a unique permission set; cluster_count = how many (subject,'
\echo ' resource) pairs have exactly that set.'

WITH cluster AS (
    SELECT subject_type,
           subject_id,
           resource_type,
           resource_id,
           array_agg(permission ORDER BY permission) AS perms
    FROM storage.access_grants
    GROUP BY 1, 2, 3, 4
),
known_bundles AS (
    SELECT ARRAY['read']::text[]                                            AS perms, 'viewer'      AS role
    UNION ALL SELECT ARRAY['comment','read']::text[],                          'commenter'
    UNION ALL SELECT ARRAY['create','read']::text[],                           'contributor'
    UNION ALL SELECT ARRAY['comment','create','read','update']::text[],        'editor'
    UNION ALL SELECT ARRAY['comment','create','delete','read','share','update']::text[], 'owner'
)
SELECT cluster.perms,
       count(*)                                                AS cluster_count,
       ROUND(100.0 * count(*) / SUM(count(*)) OVER (), 2)      AS pct,
       COALESCE(known_bundles.role, '(non-bundle)')            AS maps_to_role
FROM cluster
LEFT JOIN known_bundles ON known_bundles.perms = cluster.perms
GROUP BY cluster.perms, known_bundles.role
ORDER BY cluster_count DESC;


\echo ''
\echo '─────────────────────────────────────────────────────────────────────────'
\echo ' 2. Bundle-shaped vs not — the headline number'
\echo '─────────────────────────────────────────────────────────────────────────'

WITH cluster AS (
    SELECT subject_type,
           subject_id,
           resource_type,
           resource_id,
           array_agg(permission ORDER BY permission) AS perms
    FROM storage.access_grants
    GROUP BY 1, 2, 3, 4
),
known_bundles AS (
    SELECT ARRAY['read']::text[]                                            AS perms
    UNION ALL SELECT ARRAY['comment','read']::text[]
    UNION ALL SELECT ARRAY['create','read']::text[]
    UNION ALL SELECT ARRAY['comment','create','read','update']::text[]
    UNION ALL SELECT ARRAY['comment','create','delete','read','share','update']::text[]
),
shape AS (
    SELECT CASE WHEN cluster.perms = ANY(SELECT kb.perms FROM known_bundles kb)
                THEN 'bundle-shaped'
                ELSE 'NON-bundle (needs per-row decision)'
           END AS shape
    FROM cluster
)
SELECT shape,
       count(*)                                            AS clusters,
       ROUND(100.0 * count(*) / SUM(count(*)) OVER (), 2)  AS pct
FROM shape
GROUP BY shape
ORDER BY clusters DESC;


\echo ''
\echo '─────────────────────────────────────────────────────────────────────────'
\echo ' 3. Non-bundle clusters in detail (the <1% — investigate each)'
\echo '─────────────────────────────────────────────────────────────────────────'
\echo ' If this returns 0 rows, the migration is FULLY mechanical. Otherwise'
\echo ' eyeball each row and decide: closest role + audit log entry, or'
\echo ' refuse-to-migrate (rare).'

WITH cluster AS (
    SELECT subject_type,
           subject_id,
           resource_type,
           resource_id,
           array_agg(permission ORDER BY permission) AS perms
    FROM storage.access_grants
    GROUP BY 1, 2, 3, 4
),
known_bundles AS (
    SELECT ARRAY['read']::text[]                                            AS perms
    UNION ALL SELECT ARRAY['comment','read']::text[]
    UNION ALL SELECT ARRAY['create','read']::text[]
    UNION ALL SELECT ARRAY['comment','create','read','update']::text[]
    UNION ALL SELECT ARRAY['comment','create','delete','read','share','update']::text[]
)
SELECT cluster.subject_type,
       cluster.subject_id,
       cluster.resource_type,
       cluster.resource_id,
       cluster.perms
FROM cluster
WHERE NOT (cluster.perms = ANY(SELECT kb.perms FROM known_bundles kb))
ORDER BY cluster.resource_type, cluster.resource_id
LIMIT 200;


\echo ''
\echo '─────────────────────────────────────────────────────────────────────────'
\echo ' 4. Sanity checks — invariants that should be true today'
\echo '─────────────────────────────────────────────────────────────────────────'

\echo ''
\echo '  4a. Clusters with no Read permission (broken? if >0, investigate)'
WITH cluster AS (
    SELECT subject_type, subject_id, resource_type, resource_id,
           array_agg(permission ORDER BY permission) AS perms
    FROM storage.access_grants
    GROUP BY 1, 2, 3, 4
)
SELECT count(*) AS clusters_without_read
FROM cluster
WHERE NOT ('read' = ANY(perms));

\echo ''
\echo '  4b. Subject-type distribution (sanity check on token / external counts)'
SELECT subject_type,
       count(*)                                            AS rows,
       count(DISTINCT subject_id)                          AS distinct_subjects,
       count(DISTINCT (resource_type, resource_id))        AS distinct_resources
FROM storage.access_grants
GROUP BY subject_type
ORDER BY subject_type;

\echo ''
\echo '  4c. Resource-type distribution'
SELECT resource_type, count(*) AS rows
FROM storage.access_grants
GROUP BY resource_type
ORDER BY rows DESC;

\echo ''
\echo '  4d. Permission distribution (total rows per permission value)'
SELECT permission, count(*) AS rows
FROM storage.access_grants
GROUP BY permission
ORDER BY rows DESC;


\echo ''
\echo '─────────────────────────────────────────────────────────────────────────'
\echo ' 5. Migration cost estimate'
\echo '─────────────────────────────────────────────────────────────────────────'
\echo ' role_grants will have ~ (distinct clusters) rows, replacing ~ (total)'
\echo ' rows in access_grants. The ratio is the per-row reduction factor.'

WITH cluster AS (
    SELECT subject_type, subject_id, resource_type, resource_id
    FROM storage.access_grants
    GROUP BY 1, 2, 3, 4
)
SELECT (SELECT count(*) FROM storage.access_grants)             AS access_grants_rows_today,
       (SELECT count(*) FROM cluster)                            AS role_grants_rows_after,
       ROUND(
         (SELECT count(*) FROM storage.access_grants)::numeric
         / NULLIF((SELECT count(*) FROM cluster), 0),
         2
       )                                                          AS reduction_factor;


\echo ''
\echo '─────────────────────────────────────────────────────────────────────────'
\echo ' DONE — share section 2 (headline) and section 3 (non-bundle detail)'
\echo ' to make the D-Prep PR scope decision.'
\echo '─────────────────────────────────────────────────────────────────────────'
\echo ''
