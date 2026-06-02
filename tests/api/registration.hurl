# =============================================================
# OxiCloud — email-only registration (PR 18)
# =============================================================
# PR 18 makes `password` (and `username`) optional in
# `POST /api/auth/register`. Email-only signup:
#   - returns a uniform 200 message (no JWT, no UserDto)
#   - mints a welcome magic-link mailed to `email`
#   - redemption lands the new internal user on `/#/files`
#     (not `/#/sharedwithme`, which is for externals)
#
# Requires `OXICLOUD_SMTP_MOCK=true` (set in tests/common/server.env).
# =============================================================


# ─────────────────────────────────────────────────────────────
# Step 1 — admin login (cleanup ops at the end need her token).
# ─────────────────────────────────────────────────────────────
POST {{base_url}}/api/auth/login
Content-Type: application/json
{ "username": "{{username}}", "password": "{{password}}" }

HTTP 200
[Captures]
alice_token: jsonpath "$.access_token"


# ─────────────────────────────────────────────────────────────
# Step 2 — Classic registration (with password) still works.
#          Returns 201 + UserDto (existing behaviour, unchanged).
# ─────────────────────────────────────────────────────────────
POST {{base_url}}/api/auth/register
Content-Type: application/json
{
  "username": "charlie",
  "email": "charlie@example.com",
  "password": "TestPassword1!"
}

HTTP 201
[Asserts]
jsonpath "$.username" == "charlie"
jsonpath "$.email" == "charlie@example.com"
jsonpath "$.is_external" == false
[Captures]
charlie_user_id: jsonpath "$.id"


# ─────────────────────────────────────────────────────────────
# Step 3 — Email-only registration. No username, no password.
#          Returns 200 + uniform message; welcome magic-link
#          is captured by the MockEmailSender.
# ─────────────────────────────────────────────────────────────
POST {{base_url}}/api/auth/register
Content-Type: application/json
{
  "email": "pr18-emailonly@example.com"
}

HTTP 200
[Asserts]
jsonpath "$.message" contains "sign-in link"


# ─────────────────────────────────────────────────────────────
# Step 4 — Capture the welcome mail + extract the magic-link.
# ─────────────────────────────────────────────────────────────
GET {{base_url}}/api/admin/smtp/test/captured?to=pr18-emailonly@example.com
Authorization: Bearer {{alice_token}}

HTTP 200
[Asserts]
jsonpath "$.to" == "pr18-emailonly@example.com"
jsonpath "$.text_body" matches "/magic/v1/[A-Za-z0-9_-]+"
[Captures]
pr18_magic_url: jsonpath "$.text_body" regex "(https?://[^\\s]+/magic/v1/[A-Za-z0-9_-]+)"


# ─────────────────────────────────────────────────────────────
# Step 5 — Redeem the welcome link. Internal user with no
#          resource target → lands on `/#/files` (NOT
#          `/#/sharedwithme`, which is the external-user
#          landing).
# ─────────────────────────────────────────────────────────────
GET {{pr18_magic_url}}

HTTP 302
[Asserts]
header "Location" == "/#/files"
[Captures]
pr18_access_token: cookie "oxicloud_access"


# ─────────────────────────────────────────────────────────────
# Step 6 — The new user can read their own profile. After PR 18
#          the username field is omitted (no handle claimed yet),
#          and `is_external` is false (they're an internal user
#          who signed up directly, not via invitation).
# ─────────────────────────────────────────────────────────────
GET {{base_url}}/api/auth/me
Authorization: Bearer {{pr18_access_token}}

HTTP 200
[Asserts]
jsonpath "$.email" == "pr18-emailonly@example.com"
jsonpath "$.is_external" == false
jsonpath "$.username" not exists
[Captures]
pr18_user_id: jsonpath "$.id"


# ─────────────────────────────────────────────────────────────
# Step 7 — Dave can request another magic-link (he has no
#          password configured → eligible). Anti-enumeration
#          200 either way.
# ─────────────────────────────────────────────────────────────
POST {{base_url}}/api/auth/magic-link/send
Content-Type: application/json
{ "email": "pr18-emailonly@example.com" }

HTTP 200
[Asserts]
jsonpath "$.message" contains "sign-in link"


# ─────────────────────────────────────────────────────────────
# Cleanup — admin deletes charlie + dave so the DB-clean sweep
#           at run.sh end sees no stragglers.
# ─────────────────────────────────────────────────────────────
DELETE {{base_url}}/api/admin/users/{{charlie_user_id}}
Authorization: Bearer {{alice_token}}

HTTP *

DELETE {{base_url}}/api/admin/users/{{pr18_user_id}}
Authorization: Bearer {{alice_token}}

HTTP *
