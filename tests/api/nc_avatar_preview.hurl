# =============================================================
# OxiCloud — Baseline: NC avatar + preview
# =============================================================
# Group L from BASELINE_TESTS_NC_WEBDAV.md (3 scenarios).
#
# All NC routes (including avatars and previews) sit behind the
# `basic_auth_middleware` wired in `interfaces/nextcloud/
# routes.rs:174`. Even though the avatar payload is described as
# "decorative, not security-critical" in `avatar_handler.rs`,
# the request itself still requires a valid Basic Auth identity.
# Both L1 and L3 therefore mint an app password and pass it.
#
# L1 / L3 pin the avatar handler's actual contract: once
# authenticated, it ALWAYS returns 200 — stored profile image
# when present, SVG-with-initials otherwise (including for
# users that don't exist at all).
#
# L2 hits the authenticated preview endpoint with a fake file
# id and pins the not-found path. A positive-path preview test
# would require seeding an image file and resolving its NC
# numeric id, which is more setup than this baseline needs.
# =============================================================


# ─────────────────────────────────────────────────────────────
# Setup 1 — JWT login (gives us a Bearer token to mint the
#           app password used by the avatar Basic Auth + the
#           preview JWT auth).
# ─────────────────────────────────────────────────────────────
POST {{base_url}}/api/auth/login
Content-Type: application/json
{ "username": "{{username}}", "password": "{{password}}" }

HTTP 200
[Captures]
jwt: jsonpath "$.access_token"


# ─────────────────────────────────────────────────────────────
# Setup 2 — Mint an app password for the L1/L3 Basic Auth.
# ─────────────────────────────────────────────────────────────
POST {{base_url}}/api/auth/app-passwords
Authorization: Bearer {{jwt}}
Content-Type: application/json
{ "label": "nc_avatar_preview hurl test" }

HTTP 200
[Captures]
nc_username: jsonpath "$.username"
nc_password: jsonpath "$.password"
ap_id:       jsonpath "$.id"


# ─────────────────────────────────────────────────────────────
# L1 — Avatar for an existing user (admin) always 200
# ─────────────────────────────────────────────────────────────
GET {{base_url}}/index.php/avatar/{{username}}/64
[BasicAuth]
{{nc_username}}: {{nc_password}}

HTTP 200
[Asserts]
header "Content-Type" startsWith "image/"


# ─────────────────────────────────────────────────────────────
# L3 — Avatar for a nonexistent user
#
# Pinned current behaviour: 200 with the SVG-initials fallback.
# The handler explicitly comments "decorative, not security-
# critical" — it never returns 404 for an unknown name; it
# renders initials from whatever string the caller passed.
# RFC strictness would suggest 404 here, but NC desktop / Web
# UI happily render the SVG.
# ─────────────────────────────────────────────────────────────
GET {{base_url}}/index.php/avatar/nonexistent-user-deadbeef/64
[BasicAuth]
{{nc_username}}: {{nc_password}}

HTTP 200
[Asserts]
header "Content-Type" startsWith "image/"


# ─────────────────────────────────────────────────────────────
# L2 — Preview of a non-existent file id → 404
#
# fileId=99999999 is well below any real NC id we'd ever
# assign, so this exercises the "file not found" branch
# without depending on a seeded image fixture.
#
# Auth: same Basic Auth as L1/L3 — the NC `/index.php/*`
# surface is uniformly behind `basic_auth_middleware`, so Bearer
# JWT is rejected at the middleware boundary before the handler
# even sees the request.
# ─────────────────────────────────────────────────────────────
GET {{base_url}}/index.php/core/preview?fileId=99999999&x=128&y=128
[BasicAuth]
{{nc_username}}: {{nc_password}}

HTTP 404


# ─────────────────────────────────────────────────────────────
# Teardown — revoke the app password.
# ─────────────────────────────────────────────────────────────
DELETE {{base_url}}/api/auth/app-passwords/{{ap_id}}
Authorization: Bearer {{jwt}}
HTTP 200
