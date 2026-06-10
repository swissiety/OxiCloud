#!/usr/bin/env bash
# =============================================================
# OxiCloud — Baseline: NC WebDAV PROPFIND + OPTIONS
# =============================================================
# Group D from BASELINE_TESTS_NC_WEBDAV.md (11 scenarios).
#
# This is the read surface NC client touches first on every
# sync cycle. The headline guard is D8 / D9 / D10:
# trailing-slash semantics on collection vs file hrefs in
# multistatus responses — past regression where collection
# hrefs were emitted without `/` aborted NC desktop parsing
# with `Invalid href "<…>" expected starting with
# "<requested-url>"`.
#
# Sequence:
#   D1  OPTIONS on the user's root collection
#   D2  PROPFIND Depth: 0 on home
#   D3  PROPFIND Depth: 1 on empty home (just created admin,
#       no fixtures yet — fixtures arrive at the D4 step)
#   D4  Upload 2 files + create 1 subfolder, PROPFIND Depth: 1
#   D5  PROPFIND non-existent path → 404
#   D6  PROPFIND on a file (not a collection)
#   D7  PROPFIND Depth: infinity on a 3-level tree
#   D8  PROPFIND on a subdirectory at Depth: 0 (trailing slash
#       guard on its own href)
#   D9  PROPFIND subdirectory Depth: 1 with mixed content
#       (trailing slash guard on every child)
#   D10 PROPFIND home Depth: 1 with mixed content (trailing
#       slash guard on home's own entry + every child)
#   D11 PROPFIND with malformed XML body → 400
# =============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

source test.env
source common.sh
source lib/dav_helpers.sh

echo
echo "=== NC WebDAV PROPFIND + OPTIONS (Group D baseline) ==="
echo

oxicloud_login
mint_app_password
resolve_home_folder_id

# Defensive: this test's D4/D10 assertions count entries at the home
# root, so a leftover from an earlier script (e.g. the
# move_copy_delete_trash failures that 500-leak fixture files
# pinned as KNOWN BUG) would poison the count. Wipe to clean state.
wipe_home_folder

NC_FILES_BASE="$base_url/remote.php/dav/files/$username"

# ── Fixture setup (via REST so we don't depend on WebDAV-write paths) ────────

PROPFIND_FIXTURE_DIR=$(mktemp -d)
trap 'rm -rf "$PROPFIND_FIXTURE_DIR"' EXIT

echo "alpha contents" > "$PROPFIND_FIXTURE_DIR/alpha.txt"
echo "beta contents"  > "$PROPFIND_FIXTURE_DIR/beta.txt"
echo "gamma contents" > "$PROPFIND_FIXTURE_DIR/gamma.txt"

# Subdir "sub-d" for D8 / D9, with mixed children:
#   sub-d/{file1.txt, file2.txt, deepest1/, deepest2/}
# Plus a nested file under deepest1/ for D7 (Depth: infinity).

api_create_folder "sub-d" "$HOME_FOLDER_ID"
SUB_D_FOLDER_ID="$LAST_FOLDER_ID"

api_create_folder "deepest1" "$SUB_D_FOLDER_ID"
DEEPEST1_FOLDER_ID="$LAST_FOLDER_ID"

api_create_folder "deepest2" "$SUB_D_FOLDER_ID"
# DEEPEST2_FOLDER_ID not needed downstream — only its href

api_upload_file "$PROPFIND_FIXTURE_DIR/alpha.txt" "$SUB_D_FOLDER_ID"
api_upload_file "$PROPFIND_FIXTURE_DIR/beta.txt"  "$SUB_D_FOLDER_ID"

# Deep file for D7 Depth: infinity.
api_upload_file "$PROPFIND_FIXTURE_DIR/gamma.txt" "$DEEPEST1_FOLDER_ID"
DEEP_FILE_ID="$LAST_FILE_ID"

# Mixed-content top-level entry for D10:
#   home / { alpha-home.txt, sub-d/, sub-d-extra/ }

echo "home alpha" > "$PROPFIND_FIXTURE_DIR/alpha-home.txt"

api_upload_file "$PROPFIND_FIXTURE_DIR/alpha-home.txt" "$HOME_FOLDER_ID"
HOME_ALPHA_FILE_ID="$LAST_FILE_ID"

api_create_folder "sub-d-extra" "$HOME_FOLDER_ID"
SUB_EXTRA_FOLDER_ID="$LAST_FOLDER_ID"

echo
echo "Fixtures ready: 1 home-level file, 2 home-level folders (sub-d, sub-d-extra),"
echo "sub-d holds 2 files + 2 sub-subfolders, deepest1 holds 1 file."
echo

# ─────────────────────────────────────────────────────────────
# D1 — OPTIONS
# ─────────────────────────────────────────────────────────────
echo "  D1: OPTIONS on root collection"
HEADERS=$(nc_curl -i -X OPTIONS "$NC_FILES_BASE/" | tr -d '\r')
STATUS=$(awk 'NR==1{print $2}' <<< "$HEADERS")
[[ "$STATUS" == "200" ]] \
    || fail "D1: OPTIONS expected 200, got $STATUS"
grep -qi '^dav:.*1.*3' <<< "$HEADERS" \
    || fail "D1: OPTIONS missing 'DAV: 1, 3' header"
grep -qi '^allow:.*PROPFIND' <<< "$HEADERS" \
    || fail "D1: Allow header missing PROPFIND"
grep -qi '^allow:.*PUT'      <<< "$HEADERS" \
    || fail "D1: Allow header missing PUT"
grep -qi '^allow:.*REPORT'   <<< "$HEADERS" \
    || fail "D1: Allow header missing REPORT"
pass "D1: OPTIONS advertises DAV 1, 3 + Allow includes PROPFIND/PUT/REPORT"

# ─────────────────────────────────────────────────────────────
# D2 — PROPFIND Depth: 0 home
# ─────────────────────────────────────────────────────────────
echo "  D2: PROPFIND Depth: 0 on home root"
BODY=$(nc_curl -X PROPFIND -H "Depth: 0" "$NC_FILES_BASE/")
N=$(count_responses "$BODY")
[[ "$N" == "1" ]] \
    || fail "D2: Depth:0 expected 1 response, got $N"
HOME_HREF=$(extract_href_for "$BODY" "/dav/files/$username/")
[[ -n "$HOME_HREF" ]] \
    || fail "D2: home href not found in body"
[[ "$HOME_HREF" == */ ]] \
    || fail "D2: home href does NOT end with '/' — got '$HOME_HREF'"
grep -q '<d:collection/>' <<< "$BODY" \
    || fail "D2: home response missing <d:collection/>"
grep -q '<oc:fileid>'    <<< "$BODY" \
    || fail "D2: home response missing <oc:fileid>"
pass "D2: home Depth:0 — 1 response, href ends '/', collection + fileid present"

# ─────────────────────────────────────────────────────────────
# D4 — PROPFIND Depth: 1 with mixed content
#
# We test D4 BEFORE D3 because we already set up fixtures.
# D3 (empty home) requires no fixtures, which is the natural
# state of a freshly-wiped storage but is broken by anything
# we did above. We re-create the empty-home invariant by
# moving the fixtures out of the way at D3-time.
# ─────────────────────────────────────────────────────────────
echo "  D4: PROPFIND Depth: 1 on home (1 file + 2 folders ⇒ 4 responses)"
BODY=$(nc_curl -X PROPFIND -H "Depth: 1" "$NC_FILES_BASE/")
N=$(count_responses "$BODY")
[[ "$N" == "4" ]] \
    || fail "D4: Depth:1 expected 4 responses (collection + 1 file + 2 folders), got $N"
grep -q '<d:getcontentlength>' <<< "$BODY" \
    || fail "D4: at least one response should have <d:getcontentlength>"
assert_collection_hrefs_have_trailing_slash "$BODY" "D4"
pass "D4: 4 responses, trailing-slash semantics correct, content-length present"

# ─────────────────────────────────────────────────────────────
# D10 — PROPFIND home Depth: 1 mixed content
#       OWN entry + every child checked for trailing-slash.
#       The body from D4 already meets D10's setup — re-assert
#       on it with explicit OWN-entry focus.
# ─────────────────────────────────────────────────────────────
echo "  D10: PROPFIND home Depth: 1 — explicit OWN-entry trailing slash check"
# OWN entry's href is the home root, must end '/'
HOME_OWN_HREF=$(extract_href_for "$BODY" "/dav/files/$username/")
[[ -n "$HOME_OWN_HREF" ]] && [[ "$HOME_OWN_HREF" == */ ]] \
    || fail "D10: OWN-entry href absent or missing trailing slash: '$HOME_OWN_HREF'"
# Sub-d subfolder href (collection) must end '/'
SUB_D_HREF=$(extract_href_for "$BODY" "/dav/files/$username/sub-d")
[[ -n "$SUB_D_HREF" ]] && [[ "$SUB_D_HREF" == */ ]] \
    || fail "D10: sub-d folder href missing trailing slash: '$SUB_D_HREF'"
# File href must NOT end '/'
HOME_ALPHA_HREF=$(extract_href_for "$BODY" "/dav/files/$username/alpha-home.txt")
[[ -n "$HOME_ALPHA_HREF" ]] && [[ "$HOME_ALPHA_HREF" != */ ]] \
    || fail "D10: alpha-home.txt href must NOT end '/': got '$HOME_ALPHA_HREF'"
pass "D10: OWN entry + folder + file all have correct trailing-slash semantics"

# ─────────────────────────────────────────────────────────────
# D8 — PROPFIND on a subdirectory at Depth: 0
#      Its OWN href must end '/'.
# ─────────────────────────────────────────────────────────────
echo "  D8: PROPFIND Depth: 0 on subdirectory /sub-d/"
BODY=$(nc_curl -X PROPFIND -H "Depth: 0" "$NC_FILES_BASE/sub-d/")
N=$(count_responses "$BODY")
[[ "$N" == "1" ]] \
    || fail "D8: Depth:0 expected 1 response, got $N"
SUB_D_OWN_HREF=$(extract_href_for "$BODY" "/dav/files/$username/sub-d")
[[ -n "$SUB_D_OWN_HREF" ]] && [[ "$SUB_D_OWN_HREF" == */ ]] \
    || fail "D8: subdirectory OWN href missing trailing slash: '$SUB_D_OWN_HREF'"
grep -q '<d:collection/>' <<< "$BODY" \
    || fail "D8: sub-d response missing <d:collection/>"
pass "D8: subdir Depth:0 — OWN href ends '/' and resourcetype is collection"

# ─────────────────────────────────────────────────────────────
# D9 — PROPFIND on subdirectory Depth: 1 with mixed content
#      sub-d holds 2 files + 2 sub-subfolders ⇒ 5 responses,
#      every collection href ends '/', every file href doesn't.
# ─────────────────────────────────────────────────────────────
echo "  D9: PROPFIND Depth: 1 on /sub-d/ (mixed children ⇒ 5 responses)"
BODY=$(nc_curl -X PROPFIND -H "Depth: 1" "$NC_FILES_BASE/sub-d/")
N=$(count_responses "$BODY")
[[ "$N" == "5" ]] \
    || fail "D9: Depth:1 on sub-d expected 5 responses, got $N"
assert_collection_hrefs_have_trailing_slash "$BODY" "D9"
# Spot-check the two specific children: deepest1/ is a collection;
# alpha.txt is a file.
DEEPEST1_HREF=$(extract_href_for "$BODY" "/dav/files/$username/sub-d/deepest1")
[[ -n "$DEEPEST1_HREF" ]] && [[ "$DEEPEST1_HREF" == */ ]] \
    || fail "D9: deepest1 folder href missing trailing slash: '$DEEPEST1_HREF'"
SUB_D_ALPHA_HREF=$(extract_href_for "$BODY" "/dav/files/$username/sub-d/alpha.txt")
[[ -n "$SUB_D_ALPHA_HREF" ]] && [[ "$SUB_D_ALPHA_HREF" != */ ]] \
    || fail "D9: alpha.txt href must NOT end '/': got '$SUB_D_ALPHA_HREF'"
pass "D9: 5 responses, trailing-slash semantics correct on every child"

# ─────────────────────────────────────────────────────────────
# D6 — PROPFIND on a file (not collection) at Depth: 0
#      href must NOT end '/'.
# ─────────────────────────────────────────────────────────────
echo "  D6: PROPFIND Depth: 0 on a file (not a collection)"
BODY=$(nc_curl -X PROPFIND -H "Depth: 0" "$NC_FILES_BASE/alpha-home.txt")
N=$(count_responses "$BODY")
[[ "$N" == "1" ]] \
    || fail "D6: Depth:0 on file expected 1 response, got $N"
FILE_HREF=$(extract_href_for "$BODY" "/dav/files/$username/alpha-home.txt")
[[ -n "$FILE_HREF" ]] && [[ "$FILE_HREF" != */ ]] \
    || fail "D6: file href must NOT end '/': got '$FILE_HREF'"
grep -q '<d:getcontentlength>' <<< "$BODY" \
    || fail "D6: file response missing <d:getcontentlength>"
# The resourcetype on a file is empty `<d:resourcetype/>` or
# `<d:resourcetype></d:resourcetype>` — NOT a <d:collection/>.
grep -q '<d:collection/>' <<< "$BODY" \
    && fail "D6: file response erroneously contains <d:collection/>"
pass "D6: file Depth:0 — href no trailing slash, content-length present, no collection"

# ─────────────────────────────────────────────────────────────
# D5 — PROPFIND non-existent path → 404
# ─────────────────────────────────────────────────────────────
echo "  D5: PROPFIND non-existent path → 404"
STATUS=$(nc_curl -o /dev/null -w "%{http_code}" -X PROPFIND -H "Depth: 0" \
    "$NC_FILES_BASE/this-path-does-not-exist-$(date +%s)")
[[ "$STATUS" == "404" ]] \
    || fail "D5: non-existent path expected 404, got $STATUS"
pass "D5: non-existent path returns 404"

# ─────────────────────────────────────────────────────────────
# D7 — PROPFIND Depth: infinity behaviour
#
# OxiCloud's NC PROPFIND streaming handler treats `Depth: infinity`
# the same as `Depth: 1` (the branch is literally
# `if depth != "0" { … one level … }` — see
# `interfaces/nextcloud/webdav_handler.rs::build_nc_streaming_propfind`).
# No recursive descent. This is a deliberate implementation choice:
# many DAV servers either cap or 403 `Depth: infinity` because a
# full tree walk on a large account can be O(filesystem) work
# behind a single HTTP request (RFC 4918 §9.1 explicitly allows
# servers to refuse it with `propfind-finite-depth`).
#
# The test pins this: `Depth: infinity` on /sub-d/ returns the
# same 5 responses as `Depth: 1` (sub-d itself + 2 files + 2
# sub-subfolders), with the nested gamma.txt NOT present. If
# OxiCloud later starts honouring infinity (full descent → 6
# responses including gamma.txt) or refusing it (403), this
# assertion catches the change.
#
# Trailing-slash semantics still apply to whatever IS returned.
# ─────────────────────────────────────────────────────────────
echo "  D7: PROPFIND Depth: infinity on /sub-d/ (pinned to current behaviour)"
BODY=$(nc_curl -X PROPFIND -H "Depth: infinity" "$NC_FILES_BASE/sub-d/")
N=$(count_responses "$BODY")
[[ "$N" == "5" ]] \
    || fail "D7: Depth:infinity on sub-d expected 5 responses (treated as Depth:1), got $N"
GAMMA_HREF=$(extract_href_for "$BODY" "/sub-d/deepest1/gamma.txt")
[[ -z "$GAMMA_HREF" ]] \
    || fail "D7: Depth:infinity unexpectedly returned the nested gamma.txt — server now doing recursive descent? Update this test."
assert_collection_hrefs_have_trailing_slash "$BODY" "D7"
pass "D7: Depth:infinity behaves as Depth:1 (5 responses, no nested descent)"

# ─────────────────────────────────────────────────────────────
# D11 — Malformed PROPFIND body → 400
# ─────────────────────────────────────────────────────────────
echo "  D11: malformed PROPFIND XML body → 400"
STATUS=$(nc_curl -o /dev/null -w "%{http_code}" -X PROPFIND -H "Depth: 0" \
    -H "Content-Type: application/xml" \
    --data-binary '<d:propfind xmlns:d="DAV:"><d:prop><d:displayname' \
    "$NC_FILES_BASE/")
[[ "$STATUS" == "400" ]] \
    || fail "D11: malformed PROPFIND body expected 400, got $STATUS"
pass "D11: malformed XML rejected with 400"

# ─────────────────────────────────────────────────────────────
# D3 — Empty-home Depth: 1
#      Move fixtures to trash + empty trash, then verify only
#      the OWN-collection response comes back.
# ─────────────────────────────────────────────────────────────
echo "  D3: PROPFIND Depth: 1 on EMPTY home (after fixture cleanup)"
api_delete_folder "$SUB_D_FOLDER_ID"
api_delete_folder "$SUB_EXTRA_FOLDER_ID"
api_delete_file   "$HOME_ALPHA_FILE_ID"
api_empty_trash

BODY=$(nc_curl -X PROPFIND -H "Depth: 1" "$NC_FILES_BASE/")
N=$(count_responses "$BODY")
[[ "$N" == "1" ]] \
    || fail "D3: empty home Depth:1 expected 1 response (collection only), got $N"
HOME_OWN_HREF=$(extract_href_for "$BODY" "/dav/files/$username/")
[[ -n "$HOME_OWN_HREF" ]] && [[ "$HOME_OWN_HREF" == */ ]] \
    || fail "D3: empty-home OWN href missing trailing slash: '$HOME_OWN_HREF'"
pass "D3: empty home Depth:1 — only the collection itself"

# ── summary ───────────────────────────────────────────────────────────────────

echo
echo "Results: $PASS passed, $FAIL failed."
[[ "$FAIL" -eq 0 ]] && echo "All tests passed." || exit 1
