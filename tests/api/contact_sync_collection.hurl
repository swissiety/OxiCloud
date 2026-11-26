# =============================================================
# OxiCloud — CardDAV sync-collection (RFC 6578)
# =============================================================
# Real incremental sync for contacts, backed by
# `carddav.contact_sync_changes` (see
# migrations/20261126000002_contact_sync_changes.sql,
# CarddavSyncCollectionService::list_changes_with_perms,
# carddav_handler.rs::handle_report). Mirrors
# calendar_sync_collection.hurl's coverage.
#
# NOTE: CardDAV PUT-based "update" of an existing contact is a
# delete+recreate at the application layer (see
# carddav_handler.rs::handle_put), not a SQL UPDATE — so it never
# exercises the change-log's `updated` branch. This test only
# covers create/delete, which is what the public CardDAV surface
# actually produces.
#
# Coverage:
#   1. Initial sync-collection (empty sync-token) → 207, the seeded
#      contact present, a sync-token is returned.
#   2. sync-collection with that token and NO intervening changes →
#      empty delta.
#   3. Create a second contact, then sync-collection with the prior
#      token → only the new contact appears.
#   4. Delete that second contact, then sync-collection with the
#      just-issued token → an RFC 6578 §3.7 404 sub-response for it.
#   5. sync-collection with a malformed sync-token → 403
#      DAV:valid-sync-token.
# =============================================================


# ─────────────────────────────────────────────────────────────
# Step 1 — Login, create a fresh address book.
# ─────────────────────────────────────────────────────────────
POST {{base_url}}/api/auth/login
Content-Type: application/json
{ "username": "{{username}}", "password": "{{password}}" }

HTTP 200
[Captures]
token: jsonpath "$.access_token"


MKCOL {{base_url}}/carddav/sync-test-book/
Authorization: Bearer {{token}}

HTTP 201


PROPFIND {{base_url}}/carddav/
Authorization: Bearer {{token}}
Depth: 1
Content-Type: application/xml
```
<?xml version="1.0" encoding="UTF-8"?>
<D:propfind xmlns:D="DAV:">
  <D:prop>
    <D:displayname/>
    <D:resourcetype/>
  </D:prop>
</D:propfind>
```

HTTP 207
[Captures]
book_id: body regex "/carddav/([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})/"


# ─────────────────────────────────────────────────────────────
# Step 2 — Seed one contact.
# ─────────────────────────────────────────────────────────────
PUT {{base_url}}/carddav/{{book_id}}/sync-contact-1.vcf
Authorization: Bearer {{token}}
Content-Type: text/vcard
```
BEGIN:VCARD
VERSION:3.0
UID:sync-contact-1
FN:Sync Contact One
END:VCARD
```

HTTP 201


# ─────────────────────────────────────────────────────────────
# Step 3 — Initial sync-collection (empty sync-token).
# ─────────────────────────────────────────────────────────────
REPORT {{base_url}}/carddav/{{book_id}}/
Authorization: Bearer {{token}}
Content-Type: application/xml; charset=utf-8
```
<?xml version="1.0" encoding="utf-8"?>
<D:sync-collection xmlns:D="DAV:">
  <D:sync-token/><D:sync-level>1</D:sync-level>
  <D:prop>
    <D:getetag/>
  </D:prop>
</D:sync-collection>
```

HTTP 207
[Asserts]
body contains "sync-contact-1"
xpath "string(//*[local-name()='sync-token'])" != ""
[Captures]
first_sync_token: xpath "string(//*[local-name()='sync-token'])"


# ─────────────────────────────────────────────────────────────
# Step 4 — sync-collection with that token and NO intervening
#          changes → empty delta.
# ─────────────────────────────────────────────────────────────
REPORT {{base_url}}/carddav/{{book_id}}/
Authorization: Bearer {{token}}
Content-Type: application/xml; charset=utf-8
```
<?xml version="1.0" encoding="utf-8"?>
<D:sync-collection xmlns:D="DAV:">
  <D:sync-token>{{first_sync_token}}</D:sync-token><D:sync-level>1</D:sync-level>
  <D:prop>
    <D:getetag/>
  </D:prop>
</D:sync-collection>
```

HTTP 207
[Asserts]
body not contains "sync-contact-1"
xpath "string(//*[local-name()='sync-token'])" != ""


# ─────────────────────────────────────────────────────────────
# Step 5 — Create a second contact, then sync-collection with the
#          prior token → only the new contact appears.
# ─────────────────────────────────────────────────────────────
PUT {{base_url}}/carddav/{{book_id}}/sync-contact-2.vcf
Authorization: Bearer {{token}}
Content-Type: text/vcard
```
BEGIN:VCARD
VERSION:3.0
UID:sync-contact-2
FN:Sync Contact Two
END:VCARD
```

HTTP 201


REPORT {{base_url}}/carddav/{{book_id}}/
Authorization: Bearer {{token}}
Content-Type: application/xml; charset=utf-8
```
<?xml version="1.0" encoding="utf-8"?>
<D:sync-collection xmlns:D="DAV:">
  <D:sync-token>{{first_sync_token}}</D:sync-token><D:sync-level>1</D:sync-level>
  <D:prop>
    <D:getetag/>
  </D:prop>
</D:sync-collection>
```

HTTP 207
[Asserts]
body contains "sync-contact-2"
body not contains "sync-contact-1"
[Captures]
second_sync_token: xpath "string(//*[local-name()='sync-token'])"


# ─────────────────────────────────────────────────────────────
# Step 6 — Delete that second contact, then sync-collection with
#          the just-issued token → RFC 6578 §3.7 404 sub-response.
# ─────────────────────────────────────────────────────────────
DELETE {{base_url}}/carddav/{{book_id}}/sync-contact-2.vcf
Authorization: Bearer {{token}}

HTTP 204


REPORT {{base_url}}/carddav/{{book_id}}/
Authorization: Bearer {{token}}
Content-Type: application/xml; charset=utf-8
```
<?xml version="1.0" encoding="utf-8"?>
<D:sync-collection xmlns:D="DAV:">
  <D:sync-token>{{second_sync_token}}</D:sync-token><D:sync-level>1</D:sync-level>
  <D:prop>
    <D:getetag/>
  </D:prop>
</D:sync-collection>
```

HTTP 207
[Asserts]
body contains "sync-contact-2"
xpath "string(//*[local-name()='response'][contains(., 'sync-contact-2')]/*[local-name()='status'])" contains "404"


# ─────────────────────────────────────────────────────────────
# Step 7 — Malformed sync-token → 403 DAV:valid-sync-token.
#
# Was a 400 whose message named the failed check, so a client could tell
# "malformed" from "another collection's token" from "expired" (a 507).
# Every rejected token now gets this one response — the reason goes to
# the audit log only — and it is the response Thunderbird, Evolution and
# python-caldav all treat as "discard state and resync".
# ─────────────────────────────────────────────────────────────
REPORT {{base_url}}/carddav/{{book_id}}/
Authorization: Bearer {{token}}
Content-Type: application/xml; charset=utf-8
```
<?xml version="1.0" encoding="utf-8"?>
<D:sync-collection xmlns:D="DAV:">
  <D:sync-token>not-a-real-token</D:sync-token><D:sync-level>1</D:sync-level>
  <D:prop><D:getetag/></D:prop>
</D:sync-collection>
```

HTTP 403
[Asserts]
header "Content-Type" contains "application/xml"
xpath "count(//*[local-name()='error']/*[local-name()='valid-sync-token'])" == 1


# ─────────────────────────────────────────────────────────────
# Step 8 — Depth is ignored and a missing sync-level means 1. This
# surface parses REPORT bodies with its own XML parser, so it needs its
# own pins. Thunderbird sends `Depth: 1` with `<sync-level>1</sync-level>`
# here; a strict RFC 6578 400 made its CalDAV client reset its token and
# its CardDAV client re-download everything on every sync.
# ─────────────────────────────────────────────────────────────
# Thunderbird's exact request.
REPORT {{base_url}}/carddav/{{book_id}}/
Authorization: Bearer {{token}}
Depth: 1
Content-Type: application/xml; charset=utf-8
```
<?xml version="1.0" encoding="utf-8"?>
<D:sync-collection xmlns:D="DAV:">
  <D:sync-token/><D:sync-level>1</D:sync-level>
  <D:prop><D:getetag/></D:prop>
</D:sync-collection>
```

HTTP 207
[Asserts]
xpath "string(//*[local-name()='sync-token'])" != ""

# No sync-level → treated as 1.
REPORT {{base_url}}/carddav/{{book_id}}/
Authorization: Bearer {{token}}
Content-Type: application/xml; charset=utf-8
```
<?xml version="1.0" encoding="utf-8"?>
<D:sync-collection xmlns:D="DAV:">
  <D:sync-token/>
  <D:prop><D:getetag/></D:prop>
</D:sync-collection>
```

HTTP 207
[Asserts]
xpath "string(//*[local-name()='sync-token'])" != ""

# sync-level infinite is not implemented → 403.
REPORT {{base_url}}/carddav/{{book_id}}/
Authorization: Bearer {{token}}
Content-Type: application/xml; charset=utf-8
```
<?xml version="1.0" encoding="utf-8"?>
<D:sync-collection xmlns:D="DAV:">
  <D:sync-token/><D:sync-level>infinite</D:sync-level>
  <D:prop><D:getetag/></D:prop>
</D:sync-collection>
```

HTTP 403


# ─────────────────────────────────────────────────────────────
# Cleanup
# ─────────────────────────────────────────────────────────────
DELETE {{base_url}}/carddav/{{book_id}}/
Authorization: Bearer {{token}}

HTTP 204
