#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
# d-prep-real-db-smoke.sh — Validate D-Prep migration against sandbox data
# ════════════════════════════════════════════════════════════════════════════
# Reads from your sandbox DB (real data — but it's a sandbox, not prod), dumps
# it, restores into an isolated parallel DB, applies the D-Prep migration
# (`20260730000000_role_grants.sql`), and verifies the backfill against the
# pre-recorded audit numbers from `tools/audit-grants-bundle-shape.sql`.
#
# The sandbox DB itself is NEVER MODIFIED — everything happens in the parallel
# `oxicloud_dprep_smoke` DB which is dropped at the start of each run.
#
# Usage:
#   tools/d-prep-real-db-smoke.sh                # uses $DATABASE_URL
#   tools/d-prep-real-db-smoke.sh --keep         # leave smoke DB for poking after
#   tools/d-prep-real-db-smoke.sh --help
#
# Requirements:
#   - pg_dump / pg_restore / psql (PostgreSQL 14+ should be fine; sandbox version-matched)
#   - DATABASE_URL pointing at the sandbox DB
#
# PATH gotcha (Mac brew): `brew install postgresql@18` is keg-only; if pg_dump
# isn't on PATH, run:
#   export PATH="$(brew --prefix postgresql@18)/bin:$PATH"
#
# Expected audit numbers (from your audit run on 2026-06-17):
#   - 73 access_grants rows clustering into 38 (subject, resource) pairs
#   - 29 viewer / 5 editor / 4 owner
# These are encoded as assertions below. If your sandbox data has shifted
# since the audit, update EXPECTED_* variables OR re-run the audit script
# first.
#
# Memory cross-refs:
#   - bug_pg_dump_folders_circular_fk.md — circular FK on `folders` forces
#     `pg_restore --disable-triggers`
#   - project_drive_sequence_a.md — D-Prep scope + audit data
# ════════════════════════════════════════════════════════════════════════════

set -euo pipefail


# ── Config ──────────────────────────────────────────────────────────────────

SMOKE_DB_NAME="oxicloud_dprep_smoke"
DUMP_FILE="${TMPDIR:-/tmp}/oxicloud-sandbox-${SMOKE_DB_NAME}.dump"
MIGRATION_FILE="migrations/20260730000000_role_grants.sql"

# Expected values from the audit (tools/audit-grants-bundle-shape.sql run
# on 2026-06-17).  Bump these if you re-run the audit and see different
# numbers — they are intentionally HARDCODED so a silent drift gets caught.
EXPECTED_DISTINCT_CLUSTERS=38
EXPECTED_VIEWER=29
EXPECTED_EDITOR=5
EXPECTED_OWNER=4

KEEP_DB=0


# ── Arg parsing ─────────────────────────────────────────────────────────────

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

for arg in "$@"; do
    case "$arg" in
        --keep|--keep-db) KEEP_DB=1 ;;
        -h|--help)        usage 0 ;;
        *)                echo "Unknown arg: $arg" >&2 ; usage 2 ;;
    esac
done


# ── Pre-flight ──────────────────────────────────────────────────────────────

if [[ -z "${DATABASE_URL:-}" ]]; then
    echo "ERROR: \$DATABASE_URL must be set and point at the sandbox DB." >&2
    exit 2
fi

for bin in pg_dump pg_restore psql; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "ERROR: '$bin' not found on PATH." >&2
        echo "Hint: brew-installed postgresql is keg-only. Run:" >&2
        echo "  export PATH=\"\$(brew --prefix postgresql@18)/bin:\$PATH\"" >&2
        exit 2
    fi
done

if [[ ! -f "$MIGRATION_FILE" ]]; then
    echo "ERROR: migration file not found: $MIGRATION_FILE" >&2
    echo "Run this script from the repo root." >&2
    exit 2
fi

# Derive connection URLs for the maintenance DB (where we'll issue
# DROP/CREATE DATABASE) and the smoke DB itself, by splicing
# $SMOKE_DB_NAME into $DATABASE_URL.  Avoids relying on libpq's
# default local Unix socket — `dropdb`/`createdb`/`psql` without an
# explicit -d won't read $DATABASE_URL and try /tmp/.s.PGSQL.5432
# (which fails on Mac brew where the server runs on a non-default
# socket / port).
URL_NO_QUERY="${DATABASE_URL%%\?*}"
URL_QUERY="${DATABASE_URL:${#URL_NO_QUERY}}"   # "" or "?…"
SOURCE_DB_NAME="${URL_NO_QUERY##*/}"
URL_BASE="${URL_NO_QUERY%/"$SOURCE_DB_NAME"}"
MAINTENANCE_URL="${URL_BASE}/postgres${URL_QUERY}"
SMOKE_URL="${URL_BASE}/${SMOKE_DB_NAME}${URL_QUERY}"

if [[ "$SOURCE_DB_NAME" == "$SMOKE_DB_NAME" ]]; then
    echo "ERROR: DATABASE_URL appears to point at '$SMOKE_DB_NAME' — refusing" >&2
    echo "to dump-and-restore on top of itself. Set DATABASE_URL to the sandbox." >&2
    exit 2
fi


# ── Helpers ─────────────────────────────────────────────────────────────────

log()  { echo "[smoke] $*"; }
fail() { echo "[smoke] FAIL: $*" >&2 ; exit 1; }
pass() { echo "[smoke] PASS: $*"; }

# Run a query against the smoke DB and capture a single scalar.
scalar() {
    psql -tAX -d "$SMOKE_URL" -c "$1"
}

# Run a query and check the result equals an expected scalar.
expect_scalar() {
    local query="$1" expected="$2" label="$3"
    local actual
    actual=$(scalar "$query")
    if [[ "$actual" == "$expected" ]]; then
        pass "$label: $actual"
    else
        fail "$label: expected $expected, got '$actual'"
    fi
}


# ── 1. Snapshot the sandbox ─────────────────────────────────────────────────

log "Dumping sandbox DB → $DUMP_FILE"
log "(custom format, so pg_restore --disable-triggers can side-step the"
log " circular FK on storage.folders.parent_id — see bug memory.)"
pg_dump "$DATABASE_URL" --format=custom --no-owner --no-privileges \
    --file="$DUMP_FILE"
log "Dumped $(du -h "$DUMP_FILE" | awk '{print $1}')"


# ── 2. Recreate the smoke DB ────────────────────────────────────────────────

log "Dropping smoke DB '$SMOKE_DB_NAME' if it exists"
psql -d "$MAINTENANCE_URL" -c "DROP DATABASE IF EXISTS \"$SMOKE_DB_NAME\""

log "Creating fresh smoke DB '$SMOKE_DB_NAME'"
psql -d "$MAINTENANCE_URL" -c "CREATE DATABASE \"$SMOKE_DB_NAME\""


# ── 3. Restore sandbox into smoke DB ────────────────────────────────────────

log "Restoring sandbox dump into smoke DB"
# --disable-triggers handles the storage.folders parent_id circular FK without
# wrapping every COPY in SET CONSTRAINTS ALL DEFERRED.
# --no-owner --no-privileges already on dump side; --single-transaction makes
# the restore atomic so a mid-flight failure leaves no half-state.
pg_restore --dbname="$SMOKE_URL" --disable-triggers \
    --single-transaction --no-owner --no-privileges \
    "$DUMP_FILE"


# ── 4. Wipe any prior role_grants state from the smoke DB ──────────────────
# The sandbox may already have role_grants if the server has been booted
# with the D-Prep migration applied (auto-migrate on startup). For the
# smoke we want to exercise the migration FRESHLY — same as a brand-new
# install — so drop both the migration's tables and let it recreate them
# from scratch against the access_grants snapshot.

log "Wiping any prior role_grants state from smoke DB (so we test the migration freshly)"
psql -d "$SMOKE_URL" --set ON_ERROR_STOP=1 -c "
DROP TABLE IF EXISTS storage.role_grants_migration_log CASCADE;
DROP TABLE IF EXISTS storage.role_grants              CASCADE;
"

# ── 5. Pre-migration sanity ────────────────────────────────────────────────

log "Pre-migration sanity checks"
expect_scalar "SELECT count(*) FROM storage.access_grants" \
    "73" "access_grants row count matches audit"

if [[ $(scalar "SELECT to_regclass('storage.role_grants') IS NULL") != "t" ]]; then
    fail "storage.role_grants survived the drop — something is wrong."
fi
pass "storage.role_grants does not exist (clean slate)"


# ── 5. Apply the D-Prep migration ───────────────────────────────────────────

log "Applying D-Prep migration: $MIGRATION_FILE"
# Wrap in a transaction so a constraint failure rolls back cleanly; the
# migration itself has BEGIN/COMMIT semantics via -1 to psql.
psql -d "$SMOKE_URL" --set ON_ERROR_STOP=1 -1 -f "$MIGRATION_FILE"
log "Migration applied"


# ── 6. Post-migration assertions ────────────────────────────────────────────

log "Post-migration verification"

# Row count: should match `distinct_clusters` from the audit
expect_scalar "SELECT count(*) FROM storage.role_grants" \
    "$EXPECTED_DISTINCT_CLUSTERS" "role_grants row count"

# Role distribution
expect_scalar "SELECT count(*) FROM storage.role_grants WHERE role = 'viewer'" \
    "$EXPECTED_VIEWER" "viewer count"
expect_scalar "SELECT count(*) FROM storage.role_grants WHERE role = 'editor'" \
    "$EXPECTED_EDITOR" "editor count"
expect_scalar "SELECT count(*) FROM storage.role_grants WHERE role = 'owner'" \
    "$EXPECTED_OWNER" "owner count"

# Zero NULL roles, zero non-bundle roles (the CHECK constraint should
# already enforce this, but proving it here too)
expect_scalar "SELECT count(*) FROM storage.role_grants WHERE role IS NULL" \
    "0" "no NULL roles"
expect_scalar "SELECT count(*) FROM storage.role_grants WHERE role NOT IN ('viewer','commenter','contributor','editor','owner')" \
    "0" "no unknown roles"

# access_grants is untouched
expect_scalar "SELECT count(*) FROM storage.access_grants" \
    "73" "access_grants row count unchanged (dual-write safety net intact)"


# ── 7. Equivalence check (strongest assertion) ──────────────────────────────
# For every role_grants row, the corresponding (subject, resource) cluster
# in access_grants must have exactly the role's bundle as its permission
# set. If any row's bundle doesn't match what `Role::expand()` says, the
# backfill mis-mapped and the equivalence count goes non-zero.

log "Bundle equivalence check: role_grants ↔ access_grants"

EQUIVALENCE_MISMATCHES=$(scalar "
WITH expected AS (
    SELECT 'viewer'::text       AS role, ARRAY['read']::text[] AS perms
    UNION ALL SELECT 'commenter',   ARRAY['comment','read']::text[]
    UNION ALL SELECT 'contributor', ARRAY['create','read']::text[]
    UNION ALL SELECT 'editor',      ARRAY['comment','create','read','update']::text[]
    UNION ALL SELECT 'owner',       ARRAY['comment','create','delete','read','share','update']::text[]
),
actual AS (
    SELECT subject_type, subject_id, resource_type, resource_id,
           array_agg(permission ORDER BY permission) AS perms
    FROM storage.access_grants
    GROUP BY 1, 2, 3, 4
)
SELECT count(*)
FROM storage.role_grants rg
JOIN actual   a USING (subject_type, subject_id, resource_type, resource_id)
JOIN expected e ON e.role = rg.role
WHERE a.perms <> e.perms
")

if [[ "$EQUIVALENCE_MISMATCHES" == "0" ]]; then
    pass "every role_grants row's bundle matches access_grants exactly"
else
    log ""
    log "MISMATCH DETAIL (first 10):"
    psql -d "$SMOKE_URL" -c "
WITH expected AS (
    SELECT 'viewer'::text       AS role, ARRAY['read']::text[] AS perms
    UNION ALL SELECT 'commenter',   ARRAY['comment','read']::text[]
    UNION ALL SELECT 'contributor', ARRAY['create','read']::text[]
    UNION ALL SELECT 'editor',      ARRAY['comment','create','read','update']::text[]
    UNION ALL SELECT 'owner',       ARRAY['comment','create','delete','read','share','update']::text[]
),
actual AS (
    SELECT subject_type, subject_id, resource_type, resource_id,
           array_agg(permission ORDER BY permission) AS perms
    FROM storage.access_grants
    GROUP BY 1, 2, 3, 4
)
SELECT rg.subject_type, rg.subject_id, rg.resource_type, rg.resource_id,
       rg.role,
       a.perms AS access_grants_perms,
       e.perms AS expected_perms
FROM storage.role_grants rg
JOIN actual   a USING (subject_type, subject_id, resource_type, resource_id)
JOIN expected e ON e.role = rg.role
WHERE a.perms <> e.perms
LIMIT 10
"
    fail "$EQUIVALENCE_MISMATCHES role_grants rows have a bundle that diverges from their access_grants cluster"
fi


# ── 8. Migration audit log shape ────────────────────────────────────────────
# `role_grants_migration_log` is the one-shot table created by the migration
# to record any demotions. With 100%-bundle-shaped data (the audit says so),
# it should be EMPTY — nothing was demoted.

if [[ $(scalar "SELECT to_regclass('storage.role_grants_migration_log') IS NOT NULL") == "t" ]]; then
    expect_scalar "SELECT count(*) FROM storage.role_grants_migration_log" \
        "0" "migration audit log empty (no demotions, as expected for 100% bundle-shaped data)"
fi


# ── 9. Cleanup ──────────────────────────────────────────────────────────────

log ""
log "─────────────────────────────────────────────────────────"
log " ALL ASSERTIONS PASSED"
log "─────────────────────────────────────────────────────────"
log ""

if [[ "$KEEP_DB" == "1" ]]; then
    log "Leaving smoke DB '$SMOKE_DB_NAME' for inspection."
    log "Poke at it with:"
    log "  psql \"$SMOKE_URL\""
    log ""
    log "Drop when done:"
    log "  psql -d \"$MAINTENANCE_URL\" -c 'DROP DATABASE \"$SMOKE_DB_NAME\"'"
else
    log "Dropping smoke DB '$SMOKE_DB_NAME'"
    psql -d "$MAINTENANCE_URL" -c "DROP DATABASE \"$SMOKE_DB_NAME\""
fi

log "Dump file kept at $DUMP_FILE (delete with: rm '$DUMP_FILE')"
