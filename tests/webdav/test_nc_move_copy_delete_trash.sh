#!/usr/bin/env bash
# =============================================================
# OxiCloud — Baseline: NC WebDAV MOVE / COPY / DELETE + Trashbin
# =============================================================
# Groups G + K from BASELINE_TESTS_NC_WEBDAV.md (14 scenarios).
# Combined into one file because G8 (DELETE) feeds K1-K4
# (trashbin lifecycle) — same fixtures, shared lifecycle.
#
# Pinned behaviour notes:
#   G4 / G5 — `Overwrite` request header is NOT honoured by the
#             NC MOVE handler today. Both `Overwrite: F` and
#             `Overwrite: T` succeed identically. Asserted as
#             current-behaviour pins so any future "we now
#             honour Overwrite" change is caught.
#   G7     — COPY method is not dispatched by handle_nc_webdav,
#             so it falls through to METHOD_NOT_ALLOWED (405).
#             Pinned; a future COPY implementation will flip
#             this to 201/204 and the test will trip.
# =============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

source test.env
source common.sh
source lib/dav_helpers.sh

echo
echo "=== NC WebDAV MOVE / COPY / DELETE + Trashbin (Groups G + K baseline) ==="
echo

oxicloud_login
mint_app_password
resolve_home_folder_id
wipe_home_folder    # defensive against cross-test contamination

NC_FILES_BASE="$base_url/remote.php/dav/files/$username"
NC_TRASH_BASE="$base_url/remote.php/dav/trashbin/$username/trash"

FIXTURE_DIR=$(mktemp -d)
trap 'rm -rf "$FIXTURE_DIR"; \
      nc_curl -o /dev/null -X DELETE "$NC_FILES_BASE/g-leftover/"   2>/dev/null || true; \
      nc_curl -o /dev/null -X DELETE "$NC_FILES_BASE/g7-source.txt" 2>/dev/null || true; \
      api_empty_trash                                               2>/dev/null || true' EXIT

# ── Helper: PUT a small file via NC for fixture setup ────────────────────────
put_nc_file() {
    local name="$1" content="$2"
    printf '%s' "$content" | nc_curl -X PUT \
        -H "Content-Type: text/plain" \
        --data-binary @- \
        "$NC_FILES_BASE/$name" > /dev/null
}

# ── Helper: PROPFIND status for a path (for "exists / 404" assertions) ───────
nc_status_propfind_depth0() {
    nc_curl -o /dev/null -w "%{http_code}" -X PROPFIND -H "Depth: 0" "$1"
}

# ─────────────────────────────────────────────────────────────
# G1 — MOVE file to new name (rename)
# ─────────────────────────────────────────────────────────────
echo "  G1: MOVE rename a.txt → b.txt"
put_nc_file "g1-a.txt" "G1 contents"
STATUS=$(nc_curl -o /dev/null -w "%{http_code}" -X MOVE \
    -H "Destination: $NC_FILES_BASE/g1-b.txt" \
    "$NC_FILES_BASE/g1-a.txt")
[[ "$STATUS" == "201" || "$STATUS" == "204" ]] \
    || fail "G1: MOVE rename expected 201/204, got $STATUS"
[[ "$(nc_status_propfind_depth0 "$NC_FILES_BASE/g1-b.txt")" == "207" ]] \
    || fail "G1: destination g1-b.txt missing after MOVE"
[[ "$(nc_status_propfind_depth0 "$NC_FILES_BASE/g1-a.txt")" == "404" ]] \
    || fail "G1: source g1-a.txt still present after MOVE"
pass "G1: MOVE rename — destination present, source gone"

# ─────────────────────────────────────────────────────────────
# G2 — MOVE file to different folder
# ─────────────────────────────────────────────────────────────
echo "  G2: MOVE file into a subfolder"
nc_curl -o /dev/null -X MKCOL "$NC_FILES_BASE/g2-folder/" > /dev/null
STATUS=$(nc_curl -o /dev/null -w "%{http_code}" -X MOVE \
    -H "Destination: $NC_FILES_BASE/g2-folder/g1-b.txt" \
    "$NC_FILES_BASE/g1-b.txt")
[[ "$STATUS" == "201" || "$STATUS" == "204" ]] \
    || fail "G2: MOVE into subfolder expected 201/204, got $STATUS"
[[ "$(nc_status_propfind_depth0 "$NC_FILES_BASE/g2-folder/g1-b.txt")" == "207" ]] \
    || fail "G2: g2-folder/g1-b.txt not at new path"
[[ "$(nc_status_propfind_depth0 "$NC_FILES_BASE/g1-b.txt")" == "404" ]] \
    || fail "G2: source g1-b.txt still present after MOVE to subfolder"
pass "G2: MOVE into subfolder — file at destination, gone from source"

# ─────────────────────────────────────────────────────────────
# G3 — Destination header with URL-encoded special chars
# ─────────────────────────────────────────────────────────────
echo "  G3: MOVE with URL-encoded destination (space + #)"
put_nc_file "g3-src.txt" "G3 contents"
# Filename "name with #hash.txt" → URL-encoded.
ENCODED_NAME="name%20with%20%23hash.txt"
STATUS=$(nc_curl -o /dev/null -w "%{http_code}" -X MOVE \
    -H "Destination: $NC_FILES_BASE/$ENCODED_NAME" \
    "$NC_FILES_BASE/g3-src.txt")
[[ "$STATUS" == "201" || "$STATUS" == "204" ]] \
    || fail "G3: encoded MOVE expected 201/204, got $STATUS"
[[ "$(nc_status_propfind_depth0 "$NC_FILES_BASE/$ENCODED_NAME")" == "207" ]] \
    || fail "G3: encoded destination not found"
pass "G3: URL-encoded destination decoded correctly"

# ─────────────────────────────────────────────────────────────
# G4 / G5 — Overwrite header behaviour (pinned: not honoured)
# ─────────────────────────────────────────────────────────────
echo "  G4: MOVE with Overwrite: F to an existing path (pinned: SERVER BUG — leaks 500)"
put_nc_file "g4-src.txt"  "G4 source"
put_nc_file "g4-dest.txt" "G4 destination (should remain)"
STATUS=$(nc_curl -o /dev/null -w "%{http_code}" -X MOVE \
    -H "Destination: $NC_FILES_BASE/g4-dest.txt" \
    -H "Overwrite: F" \
    "$NC_FILES_BASE/g4-src.txt")
case "$STATUS" in
    500)
        # KNOWN BUG: the NC MOVE handler doesn't intercept
        # `Overwrite: F` and doesn't map the domain-layer
        # `AlreadyExists` to 412. It tries to rename, the
        # storage layer 409s "name already taken", and the
        # handler bubbles that up as 500. NC desktop will
        # interpret 500 as "server transient error" and
        # retry, which masks the real conflict.
        #
        # The right fix is in `interfaces/nextcloud/webdav_handler.rs::handle_move`:
        # check `Overwrite: F` BEFORE attempting the rename, return
        # 412 on collision; OR when Overwrite is omitted/T, delete
        # the destination first (replace semantics, → 204).
        pass "G4: Overwrite: F → 500 (KNOWN BUG: should be 412 per RFC 4918 §9.9.4 — pinned)"
        ;;
    412)
        fail "G4: server now correctly returns 412 for Overwrite: F. Bug is fixed — update this pin to assert == 412."
        ;;
    201|204)
        fail "G4: server now silently overwrites despite Overwrite: F (status $STATUS) — this would be a *different* bug; RFC requires 412."
        ;;
    *)
        fail "G4: unexpected status $STATUS"
        ;;
esac

echo "  G5: MOVE with Overwrite: T to an existing path (pinned: SERVER BUG — leaks 500)"
put_nc_file "g5-src.txt"  "G5 source"
put_nc_file "g5-dest.txt" "G5 destination (to be replaced)"
STATUS=$(nc_curl -o /dev/null -w "%{http_code}" -X MOVE \
    -H "Destination: $NC_FILES_BASE/g5-dest.txt" \
    -H "Overwrite: T" \
    "$NC_FILES_BASE/g5-src.txt")
case "$STATUS" in
    500)
        # Same root cause as G4: the handler doesn't consider the
        # `Overwrite` header at all. With `Overwrite: T` it SHOULD
        # delete the destination first and proceed (→ 204), but
        # today it bubbles up the storage-layer "Already Exists".
        pass "G5: Overwrite: T → 500 (KNOWN BUG: should be 204 per RFC 4918 §9.9.4 — pinned)"
        ;;
    204)
        fail "G5: server now correctly returns 204 for Overwrite: T. Bug is fixed — update this pin to assert == 204."
        ;;
    *)
        fail "G5: unexpected status $STATUS"
        ;;
esac

# ─────────────────────────────────────────────────────────────
# G6 — MOVE a folder (subtree)
# ─────────────────────────────────────────────────────────────
echo "  G6: MOVE folder (recursive subtree)"
nc_curl -o /dev/null -X MKCOL "$NC_FILES_BASE/g6-tree/" > /dev/null
put_nc_file "g6-tree/inside.txt" "G6 inside contents"
STATUS=$(nc_curl -o /dev/null -w "%{http_code}" -X MOVE \
    -H "Destination: $NC_FILES_BASE/g6-tree-moved/" \
    "$NC_FILES_BASE/g6-tree/")
[[ "$STATUS" == "201" || "$STATUS" == "204" ]] \
    || fail "G6: folder MOVE expected 201/204, got $STATUS"
# Subtree intact at new location.
[[ "$(nc_status_propfind_depth0 "$NC_FILES_BASE/g6-tree-moved/inside.txt")" == "207" ]] \
    || fail "G6: nested file missing after folder MOVE"
[[ "$(nc_status_propfind_depth0 "$NC_FILES_BASE/g6-tree/")" == "404" ]] \
    || fail "G6: source folder still present after MOVE"
pass "G6: folder MOVE relocates the whole subtree"

# ─────────────────────────────────────────────────────────────
# G7 — COPY method (pinned: not implemented → 405)
# ─────────────────────────────────────────────────────────────
echo "  G7: COPY method (pinned: handler not implemented → 405)"
put_nc_file "g7-source.txt" "G7 contents"
STATUS=$(nc_curl -o /dev/null -w "%{http_code}" -X COPY \
    -H "Destination: $NC_FILES_BASE/g7-copy.txt" \
    "$NC_FILES_BASE/g7-source.txt")
case "$STATUS" in
    405)
        pass "G7: COPY → 405 METHOD_NOT_ALLOWED (handler not implemented) — pinned"
        ;;
    201|204)
        fail "G7: COPY now succeeds ($STATUS) — handler was implemented; update pin and add positive assertions."
        ;;
    *)
        fail "G7: unexpected status $STATUS"
        ;;
esac

# ─────────────────────────────────────────────────────────────
# G8 — DELETE a file → 204 + GET 404 + appears in trash
#
# This step feeds K1: the deleted item must surface in the
# trashbin PROPFIND below.
# ─────────────────────────────────────────────────────────────
echo "  G8: DELETE file → 204, GET 404, trashbin lists it"
put_nc_file "g8-doomed.txt" "G8 doomed contents"
STATUS=$(nc_curl -o /dev/null -w "%{http_code}" -X DELETE "$NC_FILES_BASE/g8-doomed.txt")
[[ "$STATUS" == "204" ]] \
    || fail "G8: DELETE expected 204, got $STATUS"
GET_STATUS=$(nc_curl -o /dev/null -w "%{http_code}" "$NC_FILES_BASE/g8-doomed.txt")
[[ "$GET_STATUS" == "404" ]] \
    || fail "G8: GET after DELETE expected 404, got $GET_STATUS"
pass "G8: DELETE → 204 + GET 404"

# ─────────────────────────────────────────────────────────────
# G9 — DELETE a folder (pinned: SERVER BUG — descendants orphan)
#
# Current behaviour: the NC DELETE handler calls
# `trash_svc.move_to_trash(&folder.id, "folder", …)`. That
# flips the folder row's `is_trashed=true`, but descendant
# files / subfolders are NOT recursively trashed at the row
# level. The folder itself becomes invisible (PROPFIND on the
# folder URL → 404, correct), but every descendant remains
# directly queryable via PROPFIND on its full path. That's
# data-integrity weird: clients can still GET/PUT/DELETE the
# descendants even though their parent collection is "gone".
#
# Why this is a bug:
#   - NC desktop's tree walk PROPFINDs the descendants via the
#     parent's response; the parent being 404 stops descent and
#     the orphans never get noticed → eventual drift between
#     server state and client cache.
#   - Trash restore expects to recreate the folder + reattach
#     descendants; with descendants still "live" the restore
#     path will collide on their names.
#
# Where the fix needs to live:
#   `application/services/trash_service.rs::move_to_trash` (or
#   the folder-write repository it delegates to) — when a
#   folder is trashed, recursively mark its descendants
#   is_trashed=true (or rely on a SQL trigger on the parent
#   FK cascade).
#
# Test posture: pin the orphan behaviour. The folder→404 part
# is the only correct half. When the fix lands, the
# descendant assertions below will trip and you can flip them
# to strict 404.
# ─────────────────────────────────────────────────────────────
echo "  G9: DELETE folder (pinned: descendants currently orphan — KNOWN BUG)"
nc_curl -o /dev/null -X MKCOL "$NC_FILES_BASE/g9-tree/"       > /dev/null
nc_curl -o /dev/null -X MKCOL "$NC_FILES_BASE/g9-tree/inner/" > /dev/null
put_nc_file "g9-tree/file.txt"        "G9 file"
put_nc_file "g9-tree/inner/deep.txt"  "G9 deep"
STATUS=$(nc_curl -o /dev/null -w "%{http_code}" -X DELETE "$NC_FILES_BASE/g9-tree/")
[[ "$STATUS" == "204" ]] \
    || fail "G9: folder DELETE expected 204, got $STATUS"

# Folder itself: correctly 404.
[[ "$(nc_status_propfind_depth0 "$NC_FILES_BASE/g9-tree/")" == "404" ]] \
    || fail "G9: folder still present after DELETE — that part should always be 404"

# Descendants: pin the current (buggy) "still alive" status.
# Either current 207 (bug) or future 404 (fix) is acceptable;
# anything else means something has drifted unexpectedly.
CHILD_STATUS=$(nc_status_propfind_depth0 "$NC_FILES_BASE/g9-tree/file.txt")
DEEP_STATUS=$(nc_status_propfind_depth0 "$NC_FILES_BASE/g9-tree/inner/deep.txt")
if [[ "$CHILD_STATUS" == "207" && "$DEEP_STATUS" == "207" ]]; then
    pass "G9: descendants still reachable (file=207, deep=207) — KNOWN BUG pinned: move_to_trash isn't recursive at the row level"
elif [[ "$CHILD_STATUS" == "404" && "$DEEP_STATUS" == "404" ]]; then
    fail "G9: descendants now correctly 404 (file=$CHILD_STATUS, deep=$DEEP_STATUS) — bug is fixed, flip this case to strict 404 assertions."
else
    fail "G9: mixed/unexpected descendant statuses (file=$CHILD_STATUS, deep=$DEEP_STATUS) — pin needs review"
fi

# ═════════════════════════════════════════════════════════════
# Group K — Trashbin DAV (depends on G8's deletion above)
# ═════════════════════════════════════════════════════════════

# ─────────────────────────────────────────────────────────────
# K1 — PROPFIND trashbin: g8-doomed.txt present with the
#      original-location property.
# ─────────────────────────────────────────────────────────────
echo "  K1: PROPFIND trashbin lists g8-doomed.txt"
BODY=$(nc_curl -X PROPFIND -H "Depth: 1" "$NC_TRASH_BASE/")
grep -q 'g8-doomed' <<< "$BODY" \
    || fail "K1: g8-doomed.txt not in trashbin PROPFIND"
grep -q '<nc:trashbin-original-location>' <<< "$BODY" \
    || fail "K1: trashbin response missing <nc:trashbin-original-location>"
pass "K1: trashbin shows g8-doomed.txt with original-location"

# Extract the trashed item id (last segment of the href).
# Trashbin hrefs are `/remote.php/dav/trashbin/{user}/trash/{uuid}`
# — they don't carry the filename, so we match the surrounding
# `<d:response>` block by `<nc:trashbin-filename>g8-doomed…` and
# pull THAT block's href.
TRASHED_HREF=$(extract_response_href_containing "$BODY" "g8-doomed")
[[ -n "$TRASHED_HREF" ]] || fail "K1: could not extract trashed href for g8-doomed.txt"
TRASHED_ID=$(basename "$TRASHED_HREF")
[[ -n "$TRASHED_ID" ]] || fail "K1: could not extract trashed item id from href '$TRASHED_HREF'"

# ─────────────────────────────────────────────────────────────
# K2 — MOVE from trash → 201 (restore to ORIGINAL location)
#
# Pinned current behaviour: the trashbin MOVE handler IGNORES
# the `Destination` request header. It extracts the trash UUID
# from the URL path and calls `trash_service.restore_item(id,
# user_id)`, which restores the file to its *original*
# location, not to the URL the client requested. So even
# though we send `Destination: /restored-g8.txt`, the file
# ends up back at `/g8-doomed.txt`.
#
# This isn't necessarily a bug — many NC servers treat
# trashbin MOVE as "restore to where it was" rather than as
# arbitrary relocation. The NC desktop client doesn't rely on
# the Destination here. But the wire shape diverges from
# RFC 4918 §9.9, so it's worth pinning so a future drift in
# either direction surfaces.
# ─────────────────────────────────────────────────────────────
echo "  K2: MOVE from trash (Destination ignored, restores to ORIGINAL path /g8-doomed.txt)"
STATUS=$(nc_curl -o /dev/null -w "%{http_code}" -X MOVE \
    -H "Destination: $NC_FILES_BASE/restored-g8.txt" \
    "$NC_TRASH_BASE/$TRASHED_ID")
case "$STATUS" in
    201|204) pass "K2: trash MOVE → $STATUS (restore initiated)" ;;
    *)       fail "K2: trash MOVE expected 201/204, got $STATUS" ;;
esac
# Pin: file is at its ORIGINAL path, NOT at the requested Destination.
[[ "$(nc_status_propfind_depth0 "$NC_FILES_BASE/g8-doomed.txt")" == "207" ]] \
    || fail "K2: file should have been restored to original /g8-doomed.txt — not found there"
DEST_STATUS=$(nc_status_propfind_depth0 "$NC_FILES_BASE/restored-g8.txt")
[[ "$DEST_STATUS" == "404" ]] \
    || fail "K2: Destination header is now honoured (status $DEST_STATUS at requested dest) — behaviour changed; flip K2/K3 to RFC 4918 MOVE semantics."

# ─────────────────────────────────────────────────────────────
# K3 — Delete then permanently delete via trashbin DELETE
#
# K2 restored the file to its original path `/g8-doomed.txt`
# (not `/restored-g8.txt`, see K2's pin), so we delete from
# there to send it back to trash, then permanently delete via
# the trashbin DELETE method.
# ─────────────────────────────────────────────────────────────
echo "  K3: trashbin DELETE permanently removes an item"
# Delete the just-restored file → goes back to trash.
nc_curl -o /dev/null -X DELETE "$NC_FILES_BASE/g8-doomed.txt"
BODY=$(nc_curl -X PROPFIND -H "Depth: 1" "$NC_TRASH_BASE/")
TRASHED_HREF=$(extract_response_href_containing "$BODY" "g8-doomed")
TRASHED_ID=$(basename "$TRASHED_HREF")
[[ -n "$TRASHED_ID" && "$TRASHED_HREF" != "" ]] \
    || fail "K3: g8-doomed.txt not in trash after re-delete (no matching <d:response> block)"
STATUS=$(nc_curl -o /dev/null -w "%{http_code}" -X DELETE "$NC_TRASH_BASE/$TRASHED_ID")
[[ "$STATUS" == "204" ]] \
    || fail "K3: trash DELETE expected 204, got $STATUS"
# Confirm it's gone from trash now.
BODY=$(nc_curl -X PROPFIND -H "Depth: 1" "$NC_TRASH_BASE/")
grep -q 'g8-doomed' <<< "$BODY" \
    && fail "K3: g8-doomed still in trash after permanent DELETE"
pass "K3: trashbin DELETE permanently removes the item"

# ─────────────────────────────────────────────────────────────
# K4 — Empty all trash
# ─────────────────────────────────────────────────────────────
echo "  K4: DELETE on trash root empties everything"
# Seed a few items
put_nc_file "k4-a.txt" "k4 a"
put_nc_file "k4-b.txt" "k4 b"
put_nc_file "k4-c.txt" "k4 c"
nc_curl -o /dev/null -X DELETE "$NC_FILES_BASE/k4-a.txt"
nc_curl -o /dev/null -X DELETE "$NC_FILES_BASE/k4-b.txt"
nc_curl -o /dev/null -X DELETE "$NC_FILES_BASE/k4-c.txt"

STATUS=$(nc_curl -o /dev/null -w "%{http_code}" -X DELETE "$NC_TRASH_BASE")
[[ "$STATUS" == "204" ]] \
    || fail "K4: empty-trash expected 204, got $STATUS"

BODY=$(nc_curl -X PROPFIND -H "Depth: 1" "$NC_TRASH_BASE/")
N=$(count_responses "$BODY")
# After empty, only the trash collection itself remains.
[[ "$N" == "1" ]] \
    || fail "K4: trash should have 1 response (collection only), got $N"
pass "K4: empty-trash removes every item"

# ─────────────────────────────────────────────────────────────
# K5 — Restore-collision behaviour (pinned)
#
# Restore a trashed item to a path where a same-named file
# already exists. Pin whichever behaviour the server has today
# (rename-suffix? 412? overwrite?) so a future change is loud.
# ─────────────────────────────────────────────────────────────
echo "  K5: MOVE from trash to a colliding path — pin current behaviour"
put_nc_file "k5-conflict.txt" "k5 original (stays)"
put_nc_file "k5-doomed.txt"   "k5 to trash and restore"
nc_curl -o /dev/null -X DELETE "$NC_FILES_BASE/k5-doomed.txt"
# Take the trashed id of k5-doomed.txt
BODY=$(nc_curl -X PROPFIND -H "Depth: 1" "$NC_TRASH_BASE/")
TRASHED_HREF=$(extract_response_href_containing "$BODY" "k5-doomed")
TRASHED_ID=$(basename "$TRASHED_HREF")
[[ -n "$TRASHED_ID" && "$TRASHED_HREF" != "" ]] \
    || fail "K5: k5-doomed not in trash (no matching <d:response> block)"
STATUS=$(nc_curl -o /dev/null -w "%{http_code}" -X MOVE \
    -H "Destination: $NC_FILES_BASE/k5-conflict.txt" \
    "$NC_TRASH_BASE/$TRASHED_ID")
case "$STATUS" in
    201|204)
        pass "K5: restore-onto-existing → $STATUS (current behaviour pinned: collision NOT prevented at this layer)"
        ;;
    412)
        pass "K5: restore-onto-existing → 412 (current behaviour pinned: precondition-style refusal)"
        ;;
    409)
        pass "K5: restore-onto-existing → 409 (current behaviour pinned: name conflict)"
        ;;
    500)
        # Same shape as the G4/G5 bug — restore is a MOVE under
        # the hood, and the handler doesn't catch the storage-
        # layer "Already Exists" before it becomes an internal
        # error. Pinned because that's the actual current
        # behaviour, not because it's correct.
        pass "K5: restore-onto-existing → 500 (KNOWN BUG: same root cause as G4/G5 — pinned)"
        ;;
    *)
        fail "K5: unexpected status $STATUS — pin needs reviewing"
        ;;
esac

# ── Cleanup ──────────────────────────────────────────────────────────────────
echo "  cleanup: empty trash + remove residual fixtures"
api_empty_trash || true
pass "cleanup done"

# ── summary ───────────────────────────────────────────────────────────────────

echo
echo "Results: $PASS passed, $FAIL failed."
[[ "$FAIL" -eq 0 ]] && echo "All tests passed." || exit 1
