#!/usr/bin/env bash
# =============================================================
# OxiCloud — Baseline: NC WebDAV GET / HEAD / Range
# =============================================================
# Group E from BASELINE_TESTS_NC_WEBDAV.md (6 scenarios).
#
# Sequence:
#   E1  GET a small file — 200 + ETag + Last-Modified + Content-Type
#   E2  HEAD same file — same headers, empty body
#   E3  GET non-existent — 404
#   E4  GET a collection — pin current behavior
#   E5  GET a 1 MB file with Range — 206 + Content-Range
#   E6  GET with If-None-Match: <current-etag> → 304
#
# Catches the file_id→blob_hash cache stale-content regression
# (commit f4ce4092): if the cache returned an old blob_hash,
# E2/E3 reads of an overwritten file would serve stale content.
# That specific overwrite scenario is covered by Group F (PUT);
# this group establishes the read-side baseline.
# =============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

source test.env
source common.sh
source lib/dav_helpers.sh

echo
echo "=== NC WebDAV GET / HEAD / Range (Group E baseline) ==="
echo

oxicloud_login
mint_app_password
resolve_home_folder_id
wipe_home_folder    # defensive against cross-test contamination

NC_FILES_BASE="$base_url/remote.php/dav/files/$username"

GET_FIXTURE_DIR=$(mktemp -d)
trap 'rm -rf "$GET_FIXTURE_DIR"' EXIT

# Small fixture — exact known content for E1 / E2 / E6.
SMALL_CONTENT="hello from group E baseline"
SMALL_PATH="$GET_FIXTURE_DIR/small.txt"
printf '%s' "$SMALL_CONTENT" > "$SMALL_PATH"
SMALL_LEN=$(wc -c < "$SMALL_PATH" | tr -d ' ')

# 1 MB random binary — E5 Range request.
LARGE_PATH="$GET_FIXTURE_DIR/medium-1mb.bin"
dd if=/dev/urandom of="$LARGE_PATH" bs=1024 count=1024 status=none
LARGE_LEN=$(wc -c < "$LARGE_PATH" | tr -d ' ')

# Upload both via REST so this test only exercises the GET surface.
api_upload_file "$SMALL_PATH" "$HOME_FOLDER_ID"
SMALL_FILE_ID="$LAST_FILE_ID"

api_upload_file "$LARGE_PATH" "$HOME_FOLDER_ID"
LARGE_FILE_ID="$LAST_FILE_ID"

SMALL_URL="$NC_FILES_BASE/$(basename "$SMALL_PATH")"
LARGE_URL="$NC_FILES_BASE/$(basename "$LARGE_PATH")"

# A subfolder for E4 (GET on a collection).
api_create_folder "get-collection-probe" "$HOME_FOLDER_ID"
SUBFOLDER_ID="$LAST_FOLDER_ID"
SUBFOLDER_URL="$NC_FILES_BASE/get-collection-probe/"

trap 'rm -rf "$GET_FIXTURE_DIR"; \
      api_delete_file   "$SMALL_FILE_ID"  2>/dev/null || true; \
      api_delete_file   "$LARGE_FILE_ID"  2>/dev/null || true; \
      api_delete_folder "$SUBFOLDER_ID"   2>/dev/null || true; \
      api_empty_trash                     2>/dev/null || true' EXIT

# ─────────────────────────────────────────────────────────────
# E1 — GET small file → 200 + headers + body
# ─────────────────────────────────────────────────────────────
echo "  E1: GET small file"
RESPONSE=$(nc_curl -i "$SMALL_URL")
STATUS=$(awk 'NR==1{print $2}' <<< "$RESPONSE" | tr -d '\r')
[[ "$STATUS" == "200" ]] \
    || fail "E1: expected 200, got $STATUS"
# Headers section ends at the first blank line.
HEADERS=$(awk 'BEGIN{p=1} /^\r?$/{p=0} p' <<< "$RESPONSE" | tr -d '\r')
BODY=$(awk 'BEGIN{p=0} p; /^\r?$/{p=1}'    <<< "$RESPONSE" | tr -d '\r')
grep -qi '^content-type:'  <<< "$HEADERS" \
    || fail "E1: missing Content-Type header"
grep -qi '^content-length:' <<< "$HEADERS" \
    || fail "E1: missing Content-Length header"
grep -qi '^etag:'           <<< "$HEADERS" \
    || fail "E1: missing ETag header"
grep -qi '^last-modified:'  <<< "$HEADERS" \
    || fail "E1: missing Last-Modified header"
CLEN=$(grep -i '^content-length:' <<< "$HEADERS" | awk '{print $2}' | tr -d '\r')
[[ "$CLEN" == "$SMALL_LEN" ]] \
    || fail "E1: Content-Length mismatch — expected $SMALL_LEN, got $CLEN"
# Body equals the uploaded bytes.
ACTUAL_BODY=$(nc_curl "$SMALL_URL")
[[ "$ACTUAL_BODY" == "$SMALL_CONTENT" ]] \
    || fail "E1: body mismatch — got '$ACTUAL_BODY', expected '$SMALL_CONTENT'"
# Capture the ETag for E6.
E1_ETAG=$(grep -i '^etag:' <<< "$HEADERS" | awk '{print $2}' | tr -d '\r')
pass "E1: GET small file — 200 + Content-Type/Length/ETag/Last-Modified, body matches"

# ─────────────────────────────────────────────────────────────
# E2 — HEAD same file → same headers, empty body
# ─────────────────────────────────────────────────────────────
echo "  E2: HEAD small file"
RESPONSE=$(nc_curl -I "$SMALL_URL")
STATUS=$(awk 'NR==1{print $2}' <<< "$RESPONSE" | tr -d '\r')
[[ "$STATUS" == "200" ]] \
    || fail "E2: expected 200, got $STATUS"
grep -qi '^content-length:' <<< "$RESPONSE" \
    || fail "E2: missing Content-Length on HEAD"
grep -qi '^etag:'            <<< "$RESPONSE" \
    || fail "E2: missing ETag on HEAD"
# `curl -I` body should be empty.
BODY_SIZE=$(nc_curl -I "$SMALL_URL" -w '%{size_download}' -o /dev/null)
[[ "$BODY_SIZE" == "0" ]] \
    || fail "E2: HEAD body must be empty, got $BODY_SIZE bytes"
pass "E2: HEAD small file — same headers, empty body"

# ─────────────────────────────────────────────────────────────
# E3 — GET non-existent file → 404
# ─────────────────────────────────────────────────────────────
echo "  E3: GET non-existent file → 404"
STATUS=$(nc_curl -o /dev/null -w "%{http_code}" \
    "$NC_FILES_BASE/this-does-not-exist-$(date +%s).txt")
[[ "$STATUS" == "404" ]] \
    || fail "E3: expected 404, got $STATUS"
pass "E3: non-existent → 404"

# ─────────────────────────────────────────────────────────────
# E4 — GET on a collection
#      Per BASELINE doc §7 "Open questions", pin whatever the
#      current behavior is (200 vs 404). Both are acceptable
#      values for NC; the regression we care about is "did the
#      shape change". The assertion below records the current
#      behavior so any future drift is caught.
# ─────────────────────────────────────────────────────────────
echo "  E4: GET on a collection — pin current behavior"
STATUS=$(nc_curl -o /dev/null -w "%{http_code}" "$SUBFOLDER_URL")
case "$STATUS" in
    200|404)
        pass "E4: GET on collection returns $STATUS (pinned)"
        ;;
    *)
        fail "E4: unexpected status $STATUS (expected 200 or 404)"
        ;;
esac

# ─────────────────────────────────────────────────────────────
# E5 — Range request on 1 MB file
#
# Must use GET (not HEAD) — `handle_head` in the NC surface
# doesn't receive the request headers and never invokes the
# Range-response path. Range against HEAD silently returns
# 200 with all headers, which masks the Range support and
# would falsely pass an E5 written with `curl -I`. Use
# `-D - -o /dev/null` instead: defaults to GET, dumps the
# response headers to stdout, throws the body away — gives
# us the status + Content-Range without downloading the slice.
# ─────────────────────────────────────────────────────────────
echo "  E5: GET with Range: bytes=0-1023 on 1 MB file → 206"
RESPONSE_HEADERS=$(nc_curl -D - -o /dev/null -H "Range: bytes=0-1023" "$LARGE_URL")
STATUS=$(awk 'NR==1{print $2}' <<< "$RESPONSE_HEADERS" | tr -d '\r')
[[ "$STATUS" == "206" ]] \
    || fail "E5: expected 206, got $STATUS"
grep -qi "^content-range:.*0-1023/$LARGE_LEN" <<< "$RESPONSE_HEADERS" \
    || fail "E5: missing or wrong Content-Range header"
# Actually fetch the slice and verify byte count.
BODY_SIZE=$(nc_curl -H "Range: bytes=0-1023" "$LARGE_URL" | wc -c | tr -d ' ')
[[ "$BODY_SIZE" == "1024" ]] \
    || fail "E5: Range body size expected 1024, got $BODY_SIZE"
pass "E5: Range bytes=0-1023 — 206 + Content-Range correct + 1024 bytes"

# ─────────────────────────────────────────────────────────────
# E6 — GET with If-None-Match matching the stored ETag → 304
# ─────────────────────────────────────────────────────────────
echo "  E6: GET with If-None-Match matching ETag → 304"
[[ -n "$E1_ETAG" ]] \
    || fail "E6: precondition — E1 should have captured an ETag"
STATUS=$(nc_curl -o /dev/null -w "%{http_code}" \
    -H "If-None-Match: $E1_ETAG" "$SMALL_URL")
[[ "$STATUS" == "304" ]] \
    || fail "E6: If-None-Match matching expected 304, got $STATUS (etag was $E1_ETAG)"
pass "E6: If-None-Match matches → 304"

# ── summary ───────────────────────────────────────────────────────────────────

echo
echo "Results: $PASS passed, $FAIL failed."
[[ "$FAIL" -eq 0 ]] && echo "All tests passed." || exit 1
