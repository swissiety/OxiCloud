# =============================================================
# OxiCloud — Baseline: NC Login Flow v2
# =============================================================
# Group B from BASELINE_TESTS_NC_WEBDAV.md.
#
# Login Flow v2 is how NC desktop / iOS / Android bootstrap an
# app password without ever seeing the user's real password.
# Breaking the JSON shape returned by `/index.php/login/v2` or
# `…/poll` means no new desktop client can pair.
#
# Coverage:
#   B1 — POST /index.php/login/v2 returns { login, poll: {…} }
#   B2 — POST …/login/v2/poll before grant → 404
#   B5 — POST …/login/v2/poll with unknown / expired token → 404
#
# Deliberately deferred:
#   B3 — Simulate the browser-side grant. This requires a
#        multi-step interaction with the grant page (HTML form
#        POST) that is awkward in Hurl and tied to the device-
#        auth-grant internals. Covered separately by
#        tests/webdav/ once the bash tooling for browser
#        simulation lands.
#   B4 — Poll AFTER grant. Same dependency as B3.
# =============================================================


# ─────────────────────────────────────────────────────────────
# B1 — POST /index.php/login/v2 (no auth)
#      → 200 with JSON `{ login: <url>, poll: { token, endpoint } }`.
# ─────────────────────────────────────────────────────────────
POST {{base_url}}/index.php/login/v2

HTTP 200
[Captures]
poll_token:    jsonpath "$.poll.token"
poll_endpoint: jsonpath "$.poll.endpoint"
login_url:     jsonpath "$.login"
[Asserts]
jsonpath "$.poll.token"    exists
jsonpath "$.poll.endpoint" exists
jsonpath "$.login"         exists
# The login URL embeds the flow token as a PATH segment
# (`/login/v2/flow/<token>`), not a query param — that's what
# the NC desktop client follows after init.
jsonpath "$.login"         contains "/login/v2/flow/"


# ─────────────────────────────────────────────────────────────
# B2 — POST /login/v2/poll BEFORE the user grants
#      → 404 (NC convention: "not yet ready").
#
#      The token here is the one captured in B1, so the server
#      recognises the flow exists; it just hasn't been granted
#      yet.
# ─────────────────────────────────────────────────────────────
POST {{base_url}}/login/v2/poll
[FormParams]
token: {{poll_token}}

HTTP 404


# ─────────────────────────────────────────────────────────────
# B5 — POST /login/v2/poll with an unknown / never-issued token
#      → 404. Same shape as B2 — server doesn't distinguish
#      "wrong token" from "right token, not granted yet" on the
#      wire (anti-enumeration: a probe can't tell which flows
#      exist).
# ─────────────────────────────────────────────────────────────
POST {{base_url}}/login/v2/poll
[FormParams]
token: nonexistent-token-deadbeef-cafef00d

HTTP 404
