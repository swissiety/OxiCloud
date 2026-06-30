# =============================================================
# OxiCloud — WebDAV dead-properties (RFC 4918 §4.2) end-to-end
# =============================================================
# Exercises the PROPPATCH/PROPFIND round-trip backed by
# `storage.webdav_dead_properties` (the table introduced in
# migration 20260825000000) and the DeadPropertyStore service at
# src/infrastructure/services/webdav_dead_property_store.rs.
#
# Dead properties are client-authored XML that the server stores
# verbatim — Thunderbird, DAVx5, NextCloud-desktop, Cyberduck all
# use them to persist per-resource labels / sync state. A
# regression where PROPPATCH succeeds but PROPFIND returns nothing
# is silently catastrophic for those clients (they think the
# server is broken; OxiCloud sees nothing wrong in its logs).
#
# Coverage:
#   1. Setup admin, capture JWT, PUT a probe file.
#   2. PROPPATCH set → 207
#   3. PROPFIND get → value round-trips verbatim
#   4. PROPPATCH upsert (set same name → new value) → 207
#   5. PROPFIND get → new value (upsert worked)
#   6. PROPPATCH remove → 207
#   7. PROPFIND get → property absent
#   8. MOVE file → properties follow the path (rename_resource)
#   9. DELETE file → properties cleaned up (no orphan rows)
#
# XPath assertions deliberately use `local-name()` so the test
# is robust against the server's choice of namespace prefix —
# DeadPropertyStore generates `X:` but a future implementation
# is free to pick something else as long as `xmlns:X` is correct.
# =============================================================


# ─────────────────────────────────────────────────────────────
# Step 1 — Login, capture JWT
# ─────────────────────────────────────────────────────────────
POST {{base_url}}/api/auth/login
Content-Type: application/json
{ "username": "{{username}}", "password": "{{password}}" }

HTTP 200
[Captures]
token: jsonpath "$.access_token"


# Resolve the user's home folder so the WebDAV path lives somewhere
# valid. tests/api/files-folders.hurl runs before us and may have
# left state; we deliberately pick a unique filename below to
# avoid collisions.
GET {{base_url}}/api/folders
Authorization: Bearer {{token}}

HTTP 200


# ─────────────────────────────────────────────────────────────
# Step 2 — PUT a probe file via native WebDAV. The dead-property
#          handler keys on the resource path; we need a real file
#          there so MOVE/DELETE assertions later are meaningful.
# ─────────────────────────────────────────────────────────────
PUT {{base_url}}/webdav/dead-props-probe.txt
Authorization: Bearer {{token}}
Content-Type: text/plain
```
hello dead properties
```

# Post 43cf4a2b: PUT returns 201 on create, 204 on overwrite.
# This file is fresh (no prior PUT in the test), so 201 is the
# canonical answer.
HTTP 201


# ─────────────────────────────────────────────────────────────
# Step 3 — PROPPATCH set a single dead property.
#
#          The XML body sets `<X:testlabel xmlns:X="oxi:test">
#          hello</X:testlabel>`. RFC 4918 §9.2 says PROPPATCH
#          MUST return 207 Multi-Status with a per-property
#          status; we assert both the envelope status and the
#          inner 200 OK for our property.
# ─────────────────────────────────────────────────────────────
PROPPATCH {{base_url}}/webdav/dead-props-probe.txt
Authorization: Bearer {{token}}
Content-Type: application/xml; charset=utf-8
```
<?xml version="1.0" encoding="utf-8"?>
<D:propertyupdate xmlns:D="DAV:" xmlns:X="oxi:test">
  <D:set>
    <D:prop>
      <X:testlabel>hello-dead-property</X:testlabel>
    </D:prop>
  </D:set>
</D:propertyupdate>
```

HTTP 207
[Asserts]
# At least one propstat reports success for the property we set.
# Using local-name() so we don't have to bind a prefix to DAV:.
xpath "string(//*[local-name()='propstat']/*[local-name()='status'])" contains "200 OK"


# ─────────────────────────────────────────────────────────────
# Step 4 — PROPFIND. The dead-property propstat block should
#          contain `testlabel` with the value we set. The server's
#          response uses an `X:` prefix bound via `xmlns:X` to our
#          original namespace — we match by local-name() to stay
#          decoupled from that choice.
# ─────────────────────────────────────────────────────────────
PROPFIND {{base_url}}/webdav/dead-props-probe.txt
Authorization: Bearer {{token}}
Depth: 0
Content-Type: application/xml; charset=utf-8
```
<?xml version="1.0" encoding="utf-8"?>
<D:propfind xmlns:D="DAV:">
  <D:allprop/>
</D:propfind>
```

HTTP 207
[Asserts]
xpath "string(//*[local-name()='testlabel'])" == "hello-dead-property"


# ─────────────────────────────────────────────────────────────
# Step 5 — Upsert: setting the same property with a new value
#          must overwrite, not duplicate (ON CONFLICT DO UPDATE).
# ─────────────────────────────────────────────────────────────
PROPPATCH {{base_url}}/webdav/dead-props-probe.txt
Authorization: Bearer {{token}}
Content-Type: application/xml; charset=utf-8
```
<?xml version="1.0" encoding="utf-8"?>
<D:propertyupdate xmlns:D="DAV:" xmlns:X="oxi:test">
  <D:set>
    <D:prop>
      <X:testlabel>updated-value</X:testlabel>
    </D:prop>
  </D:set>
</D:propertyupdate>
```

HTTP 207


# ─────────────────────────────────────────────────────────────
# Step 6 — PROPFIND confirms the new value AND that there's still
#          only one such property (no duplicate row in the DB).
#          `count(//*[local-name()='testlabel'])` is the
#          dup-detection assertion.
# ─────────────────────────────────────────────────────────────
PROPFIND {{base_url}}/webdav/dead-props-probe.txt
Authorization: Bearer {{token}}
Depth: 0
Content-Type: application/xml; charset=utf-8
```
<?xml version="1.0" encoding="utf-8"?>
<D:propfind xmlns:D="DAV:">
  <D:allprop/>
</D:propfind>
```

HTTP 207
[Asserts]
xpath "string(//*[local-name()='testlabel'])" == "updated-value"
xpath "count(//*[local-name()='testlabel'])"  == 1


# ─────────────────────────────────────────────────────────────
# Step 7 — Remove the dead property.
# ─────────────────────────────────────────────────────────────
PROPPATCH {{base_url}}/webdav/dead-props-probe.txt
Authorization: Bearer {{token}}
Content-Type: application/xml; charset=utf-8
```
<?xml version="1.0" encoding="utf-8"?>
<D:propertyupdate xmlns:D="DAV:" xmlns:X="oxi:test">
  <D:remove>
    <D:prop>
      <X:testlabel/>
    </D:prop>
  </D:remove>
</D:propertyupdate>
```

HTTP 207


# ─────────────────────────────────────────────────────────────
# Step 8 — PROPFIND now returns no instance of `testlabel`.
# ─────────────────────────────────────────────────────────────
PROPFIND {{base_url}}/webdav/dead-props-probe.txt
Authorization: Bearer {{token}}
Depth: 0
Content-Type: application/xml; charset=utf-8
```
<?xml version="1.0" encoding="utf-8"?>
<D:propfind xmlns:D="DAV:">
  <D:allprop/>
</D:propfind>
```

HTTP 207
[Asserts]
xpath "count(//*[local-name()='testlabel'])" == 0


# ─────────────────────────────────────────────────────────────
# Step 9 — Re-set a property, then MOVE the file. The
#          rename_resource path in DeadPropertyStore must
#          re-key the row to the new path so the property
#          follows the file (a regression that leaves the row
#          at the old path would silently break every client
#          that does a MOVE then a PROPFIND).
# ─────────────────────────────────────────────────────────────
PROPPATCH {{base_url}}/webdav/dead-props-probe.txt
Authorization: Bearer {{token}}
Content-Type: application/xml; charset=utf-8
```
<?xml version="1.0" encoding="utf-8"?>
<D:propertyupdate xmlns:D="DAV:" xmlns:X="oxi:test">
  <D:set>
    <D:prop>
      <X:testlabel>survives-move</X:testlabel>
    </D:prop>
  </D:set>
</D:propertyupdate>
```

HTTP 207


MOVE {{base_url}}/webdav/dead-props-probe.txt
Authorization: Bearer {{token}}
Destination: {{base_url}}/webdav/dead-props-moved.txt

# RFC 4918 §9.9.4: MOVE returns 201 Created when the destination
# didn't exist (the resource appears there for the first time);
# 204 No Content when overwriting an existing destination. The
# destination is fresh here → 201.
HTTP 201


PROPFIND {{base_url}}/webdav/dead-props-moved.txt
Authorization: Bearer {{token}}
Depth: 0
Content-Type: application/xml; charset=utf-8
```
<?xml version="1.0" encoding="utf-8"?>
<D:propfind xmlns:D="DAV:">
  <D:allprop/>
</D:propfind>
```

HTTP 207
[Asserts]
xpath "string(//*[local-name()='testlabel'])" == "survives-move"


# ─────────────────────────────────────────────────────────────
# Step 10 — DELETE the file; remove_resource() must reap the
#           dead-property rows so they don't accumulate as
#           tombstones the next time a file is created at the
#           same path. We verify by recreating the same path
#           and PROPFIND'ing — a leak would resurface the old
#           "survives-move" value.
# ─────────────────────────────────────────────────────────────
DELETE {{base_url}}/webdav/dead-props-moved.txt
Authorization: Bearer {{token}}

HTTP 204


PUT {{base_url}}/webdav/dead-props-moved.txt
Authorization: Bearer {{token}}
Content-Type: text/plain
```
fresh file at the same path
```

# Fresh resource at the same path after DELETE → 201, same shape
# as Step 2's initial PUT.
HTTP 201


PROPFIND {{base_url}}/webdav/dead-props-moved.txt
Authorization: Bearer {{token}}
Depth: 0
Content-Type: application/xml; charset=utf-8
```
<?xml version="1.0" encoding="utf-8"?>
<D:propfind xmlns:D="DAV:">
  <D:allprop/>
</D:propfind>
```

HTTP 207
[Asserts]
# Old value MUST NOT come back — proves DELETE cleaned up.
xpath "count(//*[local-name()='testlabel'])" == 0


# ─────────────────────────────────────────────────────────────
# Cleanup
# ─────────────────────────────────────────────────────────────
DELETE {{base_url}}/webdav/dead-props-moved.txt
Authorization: Bearer {{token}}

HTTP 204
