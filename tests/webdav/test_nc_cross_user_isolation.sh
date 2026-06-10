#!/usr/bin/env bash
# =============================================================
# OxiCloud — Baseline: NC cross-user isolation (security)
# =============================================================
# Group O from BASELINE_TESTS_NC_WEBDAV.md (4 scenarios).
#
# Security baseline. The NC handlers must enforce the
# (username, app-password) auth identity against every URL
# path's `{user}` segment — alice authenticated via her app
# password must NEVER read, write, or even enumerate files
# belonging to bob, regardless of clever URL crafting.
#
# Depends on `tests/api/nc_second_user_setup.hurl` having
# created the bob fixture earlier in run.sh.
#
# Coverage:
#   O1 — PROPFIND bob's home folder while auth'd as alice → 403
#   O2 — Path-traversal attempt
#        (`/dav/files/alice/../bob/...`) → 400
#   O3 — MOVE alice's file → bob's home → 403 / 4xx
#   O4 — Alice's PROPFIND of her own home returns ONLY her
#        files (no bob files leak across)
#
# Notes on phrasing of pass conditions:
#   * For O1 / O3 the "rejection" status code may legitimately
#     be 403 (URL/auth user mismatch — the cross-check in the
#     middleware) or 401 (Basic Auth challenge). Both are
#     acceptable; what matters is that the request does NOT
#     succeed.
#   * For O2 the path-traversal rejection is asserted at the
#     `reject_path_traversal` helper in the dispatcher; if
#     that returns 400, good. If somehow it sneaks through to
#     a real lookup, we'd see a 404, which we treat as a fail
#     because it implies the dispatcher accepted the traversal.
# =============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

source test.env
source common.sh
source lib/dav_helpers.sh

echo
echo "=== NC cross-user isolation (Group O baseline) ==="
echo

oxicloud_login                # logs in as admin (= "alice" in the scenario phrasing)
mint_app_password             # admin's app password — referenced as alice's
ALICE_APP_PASS="$APP_PASS"
ALICE_USERNAME="$username"
resolve_home_folder_id
wipe_home_folder

# ── Register bob + mint his app password ─────────────────────────────────────
# tests/webdav/run.sh spawns its own postgres + server, so the bob fixture
# created by tests/api/nc_second_user_setup.hurl in the api suite is NOT
# visible here. Register him inline. The endpoint is anti-enumeration mode
# (uniform 200 on success or "already exists"); the real existence check is
# the login below — if it returns a JWT, the account is usable.

BOB_USERNAME="bob"
BOB_LOGIN_PW="BobPassword1!"
BOB_EMAIL="bob@example.com"

curl -s -X POST -H "Content-Type: application/json" \
    -d "{\"username\":\"$BOB_USERNAME\",\"email\":\"$BOB_EMAIL\",\"password\":\"$BOB_LOGIN_PW\"}" \
    "$base_url/api/auth/register" > /dev/null

BOB_LOGIN_RESP=$(curl -s -X POST -H "Content-Type: application/json" \
    -d "{\"username\":\"$BOB_USERNAME\",\"password\":\"$BOB_LOGIN_PW\"}" \
    "$base_url/api/auth/login")
BOB_JWT=$(jq -r '.access_token // empty' <<< "$BOB_LOGIN_RESP" 2>/dev/null || echo "")
[[ -n "$BOB_JWT" ]] \
    || fail "preflight: bob login failed after inline registration. response=$BOB_LOGIN_RESP"

BOB_APP_RESP=$(curl -s -X POST \
    -H "Authorization: Bearer $BOB_JWT" \
    -H "Content-Type: application/json" \
    -d '{"label":"nc_cross_user_isolation test (bob)"}' \
    "$base_url/api/auth/app-passwords")
BOB_APP_PASS=$(jq -r '.password // empty' <<< "$BOB_APP_RESP")
BOB_APP_PASS_ID=$(jq -r '.id // empty'    <<< "$BOB_APP_RESP")
[[ -n "$BOB_APP_PASS" ]] \
    || fail "preflight: could not mint bob app password (response: $BOB_APP_RESP)"

# Seed each user's home folder with a probe file so O3/O4 have
# something to ask about. Alice's seed goes via REST (`api_upload_file`
# already targets her home). Bob's seed goes via NC PUT under his
# Basic-Auth identity, since we want it owned by bob.
ALICE_FIXTURE_DIR=$(mktemp -d)
echo "alice's secret" > "$ALICE_FIXTURE_DIR/alice-secret.txt"
api_upload_file "$ALICE_FIXTURE_DIR/alice-secret.txt" "$HOME_FOLDER_ID"

curl -s -u "$BOB_USERNAME:$BOB_APP_PASS" -X PUT \
    -H "Content-Type: text/plain" \
    --data-binary 'bob secret' \
    "$base_url/remote.php/dav/files/$BOB_USERNAME/bob-secret.txt" > /dev/null

trap 'rm -rf "$ALICE_FIXTURE_DIR"; \
      curl -s -X DELETE -H "Authorization: Bearer $BOB_JWT" \
          "$base_url/api/auth/app-passwords/$BOB_APP_PASS_ID" >/dev/null 2>&1 || true; \
      wipe_home_folder 2>/dev/null || true' EXIT

NC_FILES_ALICE="$base_url/remote.php/dav/files/$ALICE_USERNAME"
NC_FILES_BOB="$base_url/remote.php/dav/files/$BOB_USERNAME"

# ─────────────────────────────────────────────────────────────
# O1 — PROPFIND bob's home while auth'd as alice → 403
# ─────────────────────────────────────────────────────────────
echo "  O1: alice PROPFINDs /dav/files/bob/ → 403"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -u "$ALICE_USERNAME:$ALICE_APP_PASS" \
    -X PROPFIND -H "Depth: 0" "$NC_FILES_BOB/")
case "$STATUS" in
    403|401)
        pass "O1: cross-user PROPFIND rejected ($STATUS)"
        ;;
    *)
        fail "O1: cross-user PROPFIND should be 403/401, got $STATUS — alice may be reading bob's home!"
        ;;
esac

# ─────────────────────────────────────────────────────────────
# O2 — Path traversal in URL → 400
# ─────────────────────────────────────────────────────────────
echo "  O2: path traversal /dav/files/$ALICE_USERNAME/../$BOB_USERNAME/bob-secret.txt → 400"
# Send the traversal in raw form (curl --path-as-is keeps `..` instead
# of letting curl normalise the URL client-side).
STATUS=$(curl -s --path-as-is -o /dev/null -w "%{http_code}" \
    -u "$ALICE_USERNAME:$ALICE_APP_PASS" \
    -X PROPFIND -H "Depth: 0" \
    "$NC_FILES_ALICE/../$BOB_USERNAME/bob-secret.txt")
case "$STATUS" in
    400|403)
        pass "O2: path traversal rejected ($STATUS)"
        ;;
    *)
        fail "O2: path-traversal expected 400/403, got $STATUS"
        ;;
esac

# ─────────────────────────────────────────────────────────────
# O3 — MOVE alice's file → bob's home → reject
# ─────────────────────────────────────────────────────────────
echo "  O3: alice MOVEs alice-secret.txt → bob's home → rejected"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -u "$ALICE_USERNAME:$ALICE_APP_PASS" \
    -X MOVE \
    -H "Destination: $NC_FILES_BOB/alice-secret-stolen.txt" \
    "$NC_FILES_ALICE/alice-secret.txt")
case "$STATUS" in
    403|401|400)
        pass "O3: cross-user MOVE rejected ($STATUS)"
        ;;
    201|204)
        # Confirm the destination actually landed in bob's home before
        # we call this a security failure — the request might have
        # legitimately failed silently elsewhere.
        DST_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -u "$BOB_USERNAME:$BOB_APP_PASS" \
            -X PROPFIND -H "Depth: 0" "$NC_FILES_BOB/alice-secret-stolen.txt")
        if [[ "$DST_STATUS" == "207" ]]; then
            fail "O3: SECURITY REGRESSION — alice's file was successfully moved into bob's home (status $STATUS, dest PROPFIND $DST_STATUS)"
        else
            pass "O3: MOVE returned $STATUS but destination is NOT in bob's home — effectively rejected"
        fi
        ;;
    *)
        fail "O3: unexpected status $STATUS — cross-user MOVE should be rejected"
        ;;
esac

# ─────────────────────────────────────────────────────────────
# O4 — Alice's home PROPFIND must contain alice-secret.txt,
#      must NOT contain bob-secret.txt
# ─────────────────────────────────────────────────────────────
echo "  O4: alice's home PROPFIND contains alice-secret.txt only (not bob-secret)"
BODY=$(curl -s -u "$ALICE_USERNAME:$ALICE_APP_PASS" \
    -X PROPFIND -H "Depth: 1" "$NC_FILES_ALICE/")
grep -q 'alice-secret.txt' <<< "$BODY" \
    || fail "O4: alice-secret.txt missing from alice's home PROPFIND"
if grep -q 'bob-secret.txt' <<< "$BODY"; then
    fail "O4: SECURITY REGRESSION — bob-secret.txt leaked into alice's home PROPFIND"
fi
pass "O4: alice's home contains only her own file; no bob leakage"

# ── summary ───────────────────────────────────────────────────────────────────

echo
echo "Results: $PASS passed, $FAIL failed."
[[ "$FAIL" -eq 0 ]] && echo "All tests passed." || exit 1
