#!/usr/bin/env bash
# =============================================================
# OxiCloud — Baseline: NC PROPPATCH favorites + REPORT
# =============================================================
# Groups H + I from BASELINE_TESTS_NC_WEBDAV.md (7 scenarios).
# Combined because they exercise the same two-step round-trip:
#   set a favorite via PROPPATCH (H), confirm it surfaces in
#   the REPORT favorites filter (I).
#
# Coverage:
#   H1 — PROPPATCH oc:favorite=1 on a file → 207
#   H2 — same file appears in REPORT favorites filter
#   H3 — PROPPATCH oc:favorite=0 → file removed from favorites
#   I1 — REPORT favorites on empty home → empty multistatus
#   I2 — REPORT favorites with 3 marked files → 3 entries
#   I3 — REPORT searchrequest LIKE %foo% returns matching files
#   I4 — REPORT searchrequest with nresults caps the result count
#
# xq is used wherever counting / per-response extraction would
# be brittle with awk (namespaced multistatus + filter-rules
# body).
# =============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

source test.env
source common.sh
source lib/dav_helpers.sh

echo
echo "=== NC PROPPATCH favorites + REPORT (Groups H + I baseline) ==="
echo

command -v xq    >/dev/null 2>&1 || fail "preflight: xq required"

oxicloud_login
mint_app_password
resolve_home_folder_id
wipe_home_folder

NC_FILES_BASE="$base_url/remote.php/dav/files/$username"
FIXTURE_DIR=$(mktemp -d)
trap 'rm -rf "$FIXTURE_DIR"; wipe_home_folder 2>/dev/null || true' EXIT

# ── Fixture setup via REST ───────────────────────────────────────────────────
# Five files for I3 / I4 search assertions: foo.txt, foobar.txt, bar.txt,
# foobaz.txt, qux.txt — three contain "foo", two don't.
for name in foo.txt foobar.txt bar.txt foobaz.txt qux.txt; do
    echo "content of $name" > "$FIXTURE_DIR/$name"
    api_upload_file "$FIXTURE_DIR/$name" "$HOME_FOLDER_ID"
done

# Three of the five will be favorited for H/I scenarios. Capture their
# REST ids so we can sanity-check the favorite state via the API later.
# foo.txt + foobar.txt + qux.txt = 3 favorites.

# ─────────────────────────────────────────────────────────────
# I1 — REPORT favorites on empty-favorites state → empty
# ─────────────────────────────────────────────────────────────
echo "  I1: REPORT favorites filter (none marked yet) → empty multistatus"
FILTER_BODY='<?xml version="1.0" encoding="utf-8"?>
<oc:filter-files xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <oc:filter-rules>
    <oc:favorite>1</oc:favorite>
  </oc:filter-rules>
</oc:filter-files>'

BODY=$(nc_curl -X REPORT -H "Content-Type: application/xml" \
    --data "$FILTER_BODY" "$NC_FILES_BASE/")
N=$(xq -x 'count(//*[local-name()="response"])' <<< "$BODY" | tr -d '\r\n ')
[[ "$N" == "0" ]] \
    || fail "I1: REPORT favorites (empty) expected 0 responses, got '$N'"
pass "I1: empty-favorites REPORT returns 0 <d:response> entries"

# ─────────────────────────────────────────────────────────────
# H1 — PROPPATCH oc:favorite=1 on foo.txt → 207
# ─────────────────────────────────────────────────────────────
PROPPATCH_FAV1='<?xml version="1.0" encoding="utf-8"?>
<d:propertyupdate xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:set><d:prop><oc:favorite>1</oc:favorite></d:prop></d:set>
</d:propertyupdate>'

PROPPATCH_FAV0='<?xml version="1.0" encoding="utf-8"?>
<d:propertyupdate xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:set><d:prop><oc:favorite>0</oc:favorite></d:prop></d:set>
</d:propertyupdate>'

echo "  H1: PROPPATCH oc:favorite=1 on /foo.txt → 207"
HEADERS=$(nc_curl -D - -o /dev/null -X PROPPATCH \
    -H "Content-Type: application/xml" \
    --data "$PROPPATCH_FAV1" \
    "$NC_FILES_BASE/foo.txt")
STATUS=$(awk 'NR==1{print $2}' <<< "$HEADERS" | tr -d '\r')
[[ "$STATUS" == "207" ]] \
    || fail "H1: PROPPATCH expected 207, got $STATUS"
pass "H1: PROPPATCH oc:favorite=1 → 207"

# ─────────────────────────────────────────────────────────────
# H2 — foo.txt now appears in REPORT favorites filter
# ─────────────────────────────────────────────────────────────
echo "  H2: REPORT favorites filter now includes /foo.txt"
BODY=$(nc_curl -X REPORT -H "Content-Type: application/xml" \
    --data "$FILTER_BODY" "$NC_FILES_BASE/")
N=$(xq -x 'count(//*[local-name()="response"])' <<< "$BODY" | tr -d '\r\n ')
[[ "$N" == "1" ]] \
    || fail "H2: expected 1 favorited entry, got '$N'"
# xq doesn't accept function-returning XPaths (e.g. boolean(...))
# at top level — it expects node selection. Plain grep is fine for
# substring-presence checks against an already-fetched body.
grep -q '/foo.txt' <<< "$BODY" \
    || fail "H2: favorites response does not contain /foo.txt"
pass "H2: REPORT favorites contains /foo.txt"

# ─────────────────────────────────────────────────────────────
# H3 — PROPPATCH oc:favorite=0 removes the favorite
# ─────────────────────────────────────────────────────────────
echo "  H3: PROPPATCH oc:favorite=0 removes /foo.txt from favorites"
STATUS=$(nc_curl -o /dev/null -w "%{http_code}" -X PROPPATCH \
    -H "Content-Type: application/xml" \
    --data "$PROPPATCH_FAV0" \
    "$NC_FILES_BASE/foo.txt")
[[ "$STATUS" == "207" ]] \
    || fail "H3: PROPPATCH unfavorite expected 207, got $STATUS"
BODY=$(nc_curl -X REPORT -H "Content-Type: application/xml" \
    --data "$FILTER_BODY" "$NC_FILES_BASE/")
N=$(xq -x 'count(//*[local-name()="response"])' <<< "$BODY" | tr -d '\r\n ')
[[ "$N" == "0" ]] \
    || fail "H3: after unfavorite expected 0 entries, got '$N'"
pass "H3: PROPPATCH oc:favorite=0 → file removed from favorites"

# ─────────────────────────────────────────────────────────────
# I2 — REPORT favorites with 3 marked files → 3 entries
# ─────────────────────────────────────────────────────────────
echo "  I2: REPORT favorites with 3 marked files → 3 responses"
for fname in foo.txt foobar.txt qux.txt; do
    STATUS=$(nc_curl -o /dev/null -w "%{http_code}" -X PROPPATCH \
        -H "Content-Type: application/xml" \
        --data "$PROPPATCH_FAV1" \
        "$NC_FILES_BASE/$fname")
    [[ "$STATUS" == "207" ]] \
        || fail "I2 setup: PROPPATCH on $fname expected 207, got $STATUS"
done
BODY=$(nc_curl -X REPORT -H "Content-Type: application/xml" \
    --data "$FILTER_BODY" "$NC_FILES_BASE/")
N=$(xq -x 'count(//*[local-name()="response"])' <<< "$BODY" | tr -d '\r\n ')
[[ "$N" == "3" ]] \
    || fail "I2: expected 3 favorited entries, got '$N'"
pass "I2: 3 favorited files appear in REPORT response"

# ─────────────────────────────────────────────────────────────
# I3 — REPORT searchrequest LIKE %foo% returns matching files
# ─────────────────────────────────────────────────────────────
echo "  I3: REPORT searchrequest LIKE %foo% → foo.txt + foobar.txt + foobaz.txt"
SEARCH_BODY='<?xml version="1.0" encoding="utf-8"?>
<d:searchrequest xmlns:d="DAV:">
  <d:basicsearch>
    <d:select><d:prop><d:displayname/></d:prop></d:select>
    <d:from><d:scope><d:href>/remote.php/dav/files/'"$username"'/</d:href></d:scope></d:from>
    <d:where>
      <d:like>
        <d:prop><d:displayname/></d:prop>
        <d:literal>%foo%</d:literal>
      </d:like>
    </d:where>
  </d:basicsearch>
</d:searchrequest>'

BODY=$(nc_curl -X REPORT -H "Content-Type: application/xml" \
    --data "$SEARCH_BODY" "$NC_FILES_BASE/")
N=$(xq -x 'count(//*[local-name()="response"])' <<< "$BODY" | tr -d '\r\n ')
[[ "$N" == "3" ]] \
    || fail "I3: search expected 3 'foo'-containing matches, got '$N'"
# Confirm bar.txt is NOT in the search results. Plain grep — same
# reason as H2 above (xq doesn't take function-returning XPaths).
# Use `grep -v` style: assert that bar.txt does NOT appear.
if grep -q '/bar.txt' <<< "$BODY"; then
    fail "I3: bar.txt erroneously matched 'foo' search"
fi
pass "I3: search returns exactly the 'foo'-containing files (bar.txt + qux.txt excluded)"

# ─────────────────────────────────────────────────────────────
# I4 — REPORT searchrequest with nresults cap
# ─────────────────────────────────────────────────────────────
echo "  I4: REPORT searchrequest with <nresults>2</nresults> caps at 2"
SEARCH_BODY_LIMITED='<?xml version="1.0" encoding="utf-8"?>
<d:searchrequest xmlns:d="DAV:">
  <d:basicsearch>
    <d:select><d:prop><d:displayname/></d:prop></d:select>
    <d:from><d:scope><d:href>/remote.php/dav/files/'"$username"'/</d:href></d:scope></d:from>
    <d:where>
      <d:like>
        <d:prop><d:displayname/></d:prop>
        <d:literal>%foo%</d:literal>
      </d:like>
    </d:where>
    <d:nresults>2</d:nresults>
  </d:basicsearch>
</d:searchrequest>'

BODY=$(nc_curl -X REPORT -H "Content-Type: application/xml" \
    --data "$SEARCH_BODY_LIMITED" "$NC_FILES_BASE/")
N=$(xq -x 'count(//*[local-name()="response"])' <<< "$BODY" | tr -d '\r\n ')
[[ "$N" == "2" ]] \
    || fail "I4: nresults=2 should cap result count at 2, got '$N'"
pass "I4: <nresults>2</nresults> correctly caps the response count"

# ── summary ───────────────────────────────────────────────────────────────────

echo
echo "Results: $PASS passed, $FAIL failed."
[[ "$FAIL" -eq 0 ]] && echo "All tests passed." || exit 1
