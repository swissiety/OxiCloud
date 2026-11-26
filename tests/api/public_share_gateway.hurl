# =============================================================
# OxiCloud — the public-share gateway contract
# =============================================================
# `docs/config/public-share-gateway.md` tells operators to expose
# only public share links to the internet, with an nginx / Traefik
# allowlist instead of a bespoke share proxy. That allowlist names
# a fixed set of paths and methods:
#
#   GET  /api/config
#   GET  /api/s/{token}
#   POST /api/s/{token}/verify
#   GET  /api/folders/{id}[/resources|/ancestors|/download]
#   GET  /api/files/{id}[/metadata|/thumbnail/{size}]
#
# plus the SPA shell and static assets. This scenario pins that a
# COMPLETE share visit works using only those requests, in the exact
# URL shapes the share page builds (`frontend/src/routes/s/[token]`,
# `lib/api/endpoints/{share,files,folders}.ts`), including query
# strings and all three thumbnail sizes.
#
# What it would catch: the share page or the share login starting to
# need a route or a method the documented edge config does not admit.
# Operators who copied the config get no warning when that happens —
# share links just break for internet visitors after an upgrade, while
# everything looks fine from inside the network. `anonymous_share_
# session.hurl` covers what the server lets an anonymous session
# reach; this file covers whether the edge allowlist is enough for
# the share page.
#
# Not covered here: the SPA shell and static assets (`/s/{token}`,
# `/_app/`, `/locales/`, …). The api-test runner has no built
# frontend — see `web_static_cache_headers.hurl` for why.
#
# Every request after the logout below is anonymous. Hurl keeps one
# cookie jar per file, so the order matters: the password-protected
# FILE share is visited first, before any folder ring exists, so a
# ring covering the folder cannot make the file assertions pass for
# the wrong reason. The file also lives OUTSIDE the shared folder.
#
# Coverage:
#   1. Setup as admin: a shared folder (child folder + image inside),
#      and a separate image behind a password-protected file share.
#   2. Logout. Canary, then `/api/config` with no session and no
#      ring — the share page's boot read.
#   3. Password file share, through `/verify` only.
#   4. Folder share: every request the share page makes.
#   5. Method shape: `/api/s/{token}` is GET-only and `/verify` is
#      POST-only, which is the split the edge config enforces.
#   6. Teardown.
# =============================================================


# ─────────────────────────────────────────────────────────────
# 1 — Setup (admin)
# ─────────────────────────────────────────────────────────────
POST {{base_url}}/api/auth/login
Content-Type: application/json
{ "username": "{{username}}", "password": "{{password}}" }

HTTP 200
[Captures]
admin_token: jsonpath "$.access_token"


GET {{base_url}}/api/folders
Authorization: Bearer {{admin_token}}

HTTP 200
[Captures]
admin_home_id: jsonpath "$[0].id"


POST {{base_url}}/api/folders
Authorization: Bearer {{admin_token}}
Content-Type: application/json
{ "name": "gateway-shared-folder", "parent_id": "{{admin_home_id}}" }

HTTP 201
[Captures]
gw_folder_id: jsonpath "$.id"


POST {{base_url}}/api/folders
Authorization: Bearer {{admin_token}}
Content-Type: application/json
{ "name": "gateway-child", "parent_id": "{{gw_folder_id}}" }

HTTP 201
[Captures]
gw_child_id: jsonpath "$.id"


# An image so the thumbnail routes return real bytes; a text file
# would answer 204 and prove nothing about the image path.
POST {{base_url}}/api/files/upload
Authorization: Bearer {{admin_token}}
[MultipartFormData]
folder_id: {{gw_folder_id}}
file: file,fixtures/red-image.png; image/png

HTTP 201
[Captures]
gw_image_id: jsonpath "$.id"


# The file behind the password share. It sits in its OWN folder, not
# under the shared one, so the folder ring cannot reach it.
POST {{base_url}}/api/folders
Authorization: Bearer {{admin_token}}
Content-Type: application/json
{ "name": "gateway-file-holder", "parent_id": "{{admin_home_id}}" }

HTTP 201
[Captures]
gw_holder_id: jsonpath "$.id"


POST {{base_url}}/api/files/upload
Authorization: Bearer {{admin_token}}
[MultipartFormData]
folder_id: {{gw_holder_id}}
file: file,fixtures/blue-image.png; image/png

HTTP 201
[Captures]
gw_file_id: jsonpath "$.id"


POST {{base_url}}/api/shares
Authorization: Bearer {{admin_token}}
Content-Type: application/json
{
  "item_id":   "{{gw_folder_id}}",
  "item_type": "folder"
}

HTTP 201
[Captures]
folder_share_token: jsonpath "$.token"


POST {{base_url}}/api/shares
Authorization: Bearer {{admin_token}}
Content-Type: application/json
{
  "item_id":   "{{gw_file_id}}",
  "item_type": "file",
  "password":  "gateway-password-1!"
}

HTTP 201
[Captures]
file_share_token: jsonpath "$.token"


# ─────────────────────────────────────────────────────────────
# 2 — Become an internet visitor.
# ─────────────────────────────────────────────────────────────
POST {{base_url}}/api/auth/logout
Authorization: Bearer {{admin_token}}

HTTP 200


# CANARY. No session and no ring yet, so this is 401 (no
# principal), not the 403 a ring-holding visitor gets. If a session
# cookie survived the logout, everything below would be testing the
# admin's own permissions.
GET {{base_url}}/api/auth/me

HTTP 401


# The share page's boot read (`serverConfig.load()` in
# `hooks.client.ts`), made before any share is unlocked. The gateway
# doc admits `/api/config` for exactly this. If it ever started to
# require a session, the share page would boot on built-in defaults.
GET {{base_url}}/api/config

HTTP 200
[Asserts]
jsonpath "$.features" exists


# ─────────────────────────────────────────────────────────────
# 3 — Password-protected FILE share.
#
# The bare GET answers 401 and issues no ring, as the doc's verify
# checklist says. The password goes through `POST /verify`, the only
# POST the edge admits. After that, the share page reads the file
# through the ordinary `/api/files/{id}` route with the query shapes
# `getFile` / `fileDownloadUrl` / `fileInlineUrl` build.
# ─────────────────────────────────────────────────────────────
GET {{base_url}}/api/s/{{file_share_token}}

HTTP 401
[Asserts]
header "Set-Cookie" not exists


POST {{base_url}}/api/s/{{file_share_token}}/verify
Content-Type: application/json
{ "password": "gateway-password-1!" }

HTTP 200
[Asserts]
cookie "oxi_shares" exists


# After unlocking, the page re-reads the metadata with the ring.
GET {{base_url}}/api/s/{{file_share_token}}

HTTP 200
[Captures]
file_share_id: jsonpath "$.id"
[Asserts]
jsonpath "$.item_id" == "{{gw_file_id}}"
jsonpath "$.item_type" == "file"


# `getFile(item_id)`
GET {{base_url}}/api/files/{{gw_file_id}}?metadata=true

HTTP 200


# `fileInlineUrl(id, shareId)`: the in-page viewer
GET {{base_url}}/api/files/{{gw_file_id}}?inline=true&share={{file_share_id}}

HTTP 200
[Asserts]
header "Content-Type" contains "image"


# `fileDownloadUrl(id, shareId)`: the download button
GET {{base_url}}/api/files/{{gw_file_id}}?share={{file_share_id}}

HTTP 200
[Asserts]
header "Content-Type" contains "image"


# Ranged read, the way a video seek or resumed download sends it.
# The doc says Range passes through the edge. This pins that the
# server answers it on the allowlisted route.
GET {{base_url}}/api/files/{{gw_file_id}}?share={{file_share_id}}
Range: bytes=0-3

HTTP 206


# ─────────────────────────────────────────────────────────────
# 4 — FOLDER share: every request the share page makes while
#     browsing, in the shapes it makes them.
# ─────────────────────────────────────────────────────────────
GET {{base_url}}/api/s/{{folder_share_token}}

HTTP 200
[Captures]
folder_share_id: jsonpath "$.id"
[Asserts]
cookie "oxi_shares" exists
jsonpath "$.item_id" == "{{gw_folder_id}}"
jsonpath "$.item_type" == "folder"


# `FolderBreadcrumb`
GET {{base_url}}/api/folders/{{gw_folder_id}}/ancestors

HTTP 200
[Asserts]
jsonpath "$.access_source.kind" == "token"


# `fetchFolderPage(id)`, with its default query string
GET {{base_url}}/api/folders/{{gw_folder_id}}/resources?order_by=name&limit=200

HTTP 200
[Asserts]
jsonpath "$.items" count == 2
jsonpath "$.items[0].resource.id" == "{{gw_child_id}}"
jsonpath "$.items[1].resource.id" == "{{gw_image_id}}"


# `fileThumbnailUrl` sizes: `icon` (list view), `preview` (grid),
# `large` (`PhotoLightbox`). The edge matches `thumbnail/{size}` with
# one pattern, so all three must answer through the same route.
GET {{base_url}}/api/files/{{gw_image_id}}/thumbnail/icon

HTTP 200
[Asserts]
header "Content-Type" contains "image"


GET {{base_url}}/api/files/{{gw_image_id}}/thumbnail/preview

HTTP 200
[Asserts]
header "Content-Type" contains "image"


GET {{base_url}}/api/files/{{gw_image_id}}/thumbnail/large

HTTP 200
[Asserts]
header "Content-Type" contains "image"


# `fetchFileMetadata`: the lightbox details panel. A plain PNG has
# no EXIF, so the answer is the empty DTO with 200, not a 404 the
# page would show as an error.
GET {{base_url}}/api/files/{{gw_image_id}}/metadata

HTTP 200


# The lightbox's full view and download of a file inside the share.
GET {{base_url}}/api/files/{{gw_image_id}}?inline=true&share={{folder_share_id}}

HTTP 200


GET {{base_url}}/api/files/{{gw_image_id}}?share={{folder_share_id}}

HTTP 200


# `folderZipUrl(id, shareId)`: "Download all"
GET {{base_url}}/api/folders/{{gw_folder_id}}/download?format=zip&share={{folder_share_id}}

HTTP 200
[Asserts]
header "Content-Type" contains "zip"


# Navigating into a subfolder: folder, breadcrumb, listing, ZIP.
GET {{base_url}}/api/folders/{{gw_child_id}}

HTTP 200


GET {{base_url}}/api/folders/{{gw_child_id}}/ancestors

HTTP 200


GET {{base_url}}/api/folders/{{gw_child_id}}/resources?order_by=name&limit=200

HTTP 200
[Asserts]
jsonpath "$.items" count == 0


GET {{base_url}}/api/folders/{{gw_child_id}}/download?format=zip&share={{folder_share_id}}

HTTP 200
[Asserts]
header "Content-Type" contains "zip"


# ─────────────────────────────────────────────────────────────
# 5 — Method shape. The edge admits `/api/s/{token}` for GET and
#     `/api/s/{token}/verify` for POST only. If either route moved
#     to another method, the documented config would refuse it and
#     password-protected links would stop working for internet
#     visitors.
# ─────────────────────────────────────────────────────────────
GET {{base_url}}/api/s/{{file_share_token}}/verify

HTTP 405


POST {{base_url}}/api/s/{{folder_share_token}}
Content-Type: application/json
{}

HTTP 405


# ─────────────────────────────────────────────────────────────
# 6 — Teardown. Deleting the folders takes the files and their
#     shares with them.
# ─────────────────────────────────────────────────────────────
POST {{base_url}}/api/auth/login
Content-Type: application/json
{ "username": "{{username}}", "password": "{{password}}" }

HTTP 200
[Captures]
admin_token: jsonpath "$.access_token"


DELETE {{base_url}}/api/folders/{{gw_folder_id}}
Authorization: Bearer {{admin_token}}

HTTP 204


DELETE {{base_url}}/api/folders/{{gw_holder_id}}
Authorization: Bearer {{admin_token}}

HTTP 204
