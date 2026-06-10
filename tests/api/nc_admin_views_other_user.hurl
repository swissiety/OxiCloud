# =============================================================
# OxiCloud — Baseline: admin views another user's OCS profile
# =============================================================
# C4 from BASELINE_TESTS_NC_WEBDAV.md.
#
# Deferred from Batch 1 because it needed the bob fixture
# that `nc_second_user_setup.hurl` now provides. Pins the
# behaviour of the existing rule in
# `interfaces/nextcloud/ocs_handler.rs::user_provisioning_response`:
#
#     if user.username != userid && user.role != "admin" {
#         return Json(ocs_err(403, ...)).into_response();
#     }
#
# i.e. you can read your own profile always; you can read
# anyone's profile if you're admin. Bob is not admin, so bob
# CANNOT read admin's profile (the symmetric assertion).
#
# Uses admin's app password for Basic Auth (same pattern as
# `nc_ocs_user_info.hurl`).
# =============================================================


# ─────────────────────────────────────────────────────────────
# Setup 1 — JWT login as admin + mint NC app password.
# ─────────────────────────────────────────────────────────────
POST {{base_url}}/api/auth/login
Content-Type: application/json
{ "username": "{{username}}", "password": "{{password}}" }

HTTP 200
[Captures]
admin_jwt: jsonpath "$.access_token"

POST {{base_url}}/api/auth/app-passwords
Authorization: Bearer {{admin_jwt}}
Content-Type: application/json
{ "label": "nc_admin_views_other_user hurl test" }

HTTP 200
[Captures]
admin_nc_user:     jsonpath "$.username"
admin_nc_pw:       jsonpath "$.password"
admin_nc_pw_id:    jsonpath "$.id"


# ─────────────────────────────────────────────────────────────
# Setup 2 — JWT login as bob + mint NC app password.
# ─────────────────────────────────────────────────────────────
POST {{base_url}}/api/auth/login
Content-Type: application/json
{ "username": "bob", "password": "BobPassword1!" }

HTTP 200
[Captures]
bob_jwt: jsonpath "$.access_token"

POST {{base_url}}/api/auth/app-passwords
Authorization: Bearer {{bob_jwt}}
Content-Type: application/json
{ "label": "nc_admin_views_other_user hurl test (bob)" }

HTTP 200
[Captures]
bob_nc_user:    jsonpath "$.username"
bob_nc_pw:      jsonpath "$.password"
bob_nc_pw_id:   jsonpath "$.id"


# ─────────────────────────────────────────────────────────────
# C4-positive — admin CAN read bob's OCS provisioning profile
# ─────────────────────────────────────────────────────────────
GET {{base_url}}/ocs/v1.php/cloud/users/bob?format=json
[BasicAuth]
{{admin_nc_user}}: {{admin_nc_pw}}

HTTP 200
[Asserts]
jsonpath "$.ocs.meta.statuscode" == 100
jsonpath "$.ocs.data.id"         == "bob"
jsonpath "$.ocs.data.email"      == "bob@example.com"


# ─────────────────────────────────────────────────────────────
# C4-symmetric — bob (non-admin) CANNOT read admin's profile
#                (proves the admin-only branch isn't a no-op)
# ─────────────────────────────────────────────────────────────
GET {{base_url}}/ocs/v1.php/cloud/users/{{username}}?format=json
[BasicAuth]
{{bob_nc_user}}: {{bob_nc_pw}}

HTTP 200
[Asserts]
jsonpath "$.ocs.meta.statuscode" == 403
jsonpath "$.ocs.meta.status"     == "failure"


# ─────────────────────────────────────────────────────────────
# Teardown — revoke both app passwords.
# ─────────────────────────────────────────────────────────────
DELETE {{base_url}}/api/auth/app-passwords/{{admin_nc_pw_id}}
Authorization: Bearer {{admin_jwt}}
HTTP 200

DELETE {{base_url}}/api/auth/app-passwords/{{bob_nc_pw_id}}
Authorization: Bearer {{bob_jwt}}
HTTP 200
