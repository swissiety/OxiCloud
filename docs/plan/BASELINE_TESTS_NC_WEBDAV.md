# NextCloud + WebDAV E2E baseline test plan

> Purpose: establish a regression baseline before the **Drive** (multi-chroot)
> implementation lands. Every scenario in this document must pass on the
> current branch (no chroot / no Drive). On the Drive branch, every
> scenario must still pass when the URL form uses the bare-username
> default-drive shape; multi-drive scenarios are *additive*, never replace
> these baselines.

---

## 1. Scope & non-goals

### In scope

- NextCloud surface
  - Status + capabilities (`/status.php`, `/index.php/204`, `/ocs/v{1,2}.php/cloud/capabilities`)
  - Login Flow v2 (`/index.php/login/v2`, `…/poll`)
  - OCS user-info + provisioning + sharees-autocomplete shape
  - WebDAV files (`/remote.php/dav/files/{user}/…`): OPTIONS, PROPFIND, GET, HEAD, PUT, MKCOL, DELETE, MOVE, COPY, PROPPATCH, REPORT
  - Chunked uploads (`/remote.php/dav/uploads/{user}/{upload_id}/…`)
  - Trashbin DAV (`/remote.php/dav/trashbin/{user}/…`)
  - Avatar + preview
- Native WebDAV (`/webdav/…`): the same verbs plus LOCK / UNLOCK
- Cross-user isolation (security baseline)
- Auth failures + per-(account, IP) lockout + external-user rejection
- **Content-integrity round-trip**: when a file is uploaded via WebDAV/NC, its
  server-stored `content_hash` (exposed by the REST API) must equal the BLAKE3
  of the bytes the client uploaded.
- **Collection-href trailing slash** — documented past regression (NC desktop
  aborts PROPFIND parse if a collection href doesn't end `/`).

### Out of scope for v1

- File sharing / sharees (deferred — separate refactor in flight).
- CalDAV / CardDAV protocols.
- OIDC login flow.
- WOPI editor integration.
- Performance / load testing.

---

## 2. Test infrastructure

- **Hurl** (existing) for REST + JSON shapes — `tests/api/*.hurl`.
- **bash + curl** for WebDAV (custom verbs + XML) — `tests/webdav/*.sh`.
- New shared helper proposed: `tests/webdav/lib/dav_helpers.sh` —
  DRY curl wrappers (depth header, multi-status XML grep, `<oc:fileid>` /
  `<d:getetag>` extraction, BLAKE3 of a local fixture).
- BLAKE3 dependency: `b3sum` (already used by `dedup_create.hurl`); install
  via `apt install b3sum` or `brew install b3sum`.
- Fixtures (most already exist under `tests/fixtures/`):
  - `hello.txt` — 32 B
  - `hello-copy.txt` — 32 B, same content as hello.txt
  - `image.png` — small PNG (need to confirm / add)
  - `medium-1mb.bin` — 1 MB random bytes (generate on the fly if missing)
  - `large-10mb.bin` — 10 MB random bytes (generated on the fly, gitignored)

### Test user fixtures

Two users seeded by `tests/api/setup.hurl`:
- `admin` (admin role) — used in groups A–N
- `bob` (regular user) — used only in group O (cross-user isolation)

Both register with strong passwords, log in once via the JWT flow, and
mint an app password (`POST /api/auth/app-passwords`) so subsequent
Basic Auth against the NC surface uses an app password — matches how
NC desktop authenticates after Login Flow v2.

---

## 3. How to run + wipe state

```bash
# Wipe DB + storage from scratch (recommended for first baseline run)
docker compose down -v
rm -rf tests/api/storage
bash tests/api/run.sh             # runs the Hurl suite end-to-end

# Run only the WebDAV/NC scripts after the Hurl seed has run
bash tests/webdav/run_all.sh      # new aggregator script — TODO
```

> Ed: yes, please wipe DB + storage for the first baseline capture.
> Subsequent runs after each batch are cumulative and idempotent.

Environment overrides used by tests (set in `tests/common/server.env`):

| Variable | Test value | Why |
|---|---|---|
| `OXICLOUD_MAX_UPLOAD_SIZE` | 10 GiB | Need enough headroom for F7 (10 MB) without hitting the cap |
| `OXICLOUD_CHUNK_MAX_BYTES` | 4 MiB | Small enough that J7 (over-cap chunk) can trigger 413 without huge fixtures |
| `OXICLOUD_DIRECT_PUT_MAX_BYTES` | 1 GiB | Standard |
| `OXICLOUD_NEXTCLOUD_ENABLED` | true | Mounts the NC router |
| `OXICLOUD_TRUST_PROXY_HEADERS` | false | Tests assert direct-client IP, not X-Forwarded-For-spoofed |

---

## 4. Scenarios

### Group A — Status & capabilities (4 scenarios)

**Purpose**: NC client refuses to even attempt sync if these endpoints
return the wrong shape. Catches namespace / serialiser regressions.

| ID | Step | Assertions |
|---|---|---|
| A1 | `GET /status.php` (no auth) | 200; JSON `installed: true`, contains `version`, `versionstring`, `productname` |
| A2 | `GET /index.php/204` (no auth) | 204; empty body. (NC mobile connectivity probe.) |
| A3 | `GET /ocs/v1.php/cloud/capabilities?format=json` (no auth) | 200; OCS envelope `meta.statuscode == 100`; `data.capabilities.core.webdav-root` is set; `data.capabilities.files.bigfilechunking == true` |
| A4 | `GET /ocs/v2.php/cloud/capabilities?format=json` | 200; OCS envelope `meta.statuscode == 200`; same payload shape as A3 |

---

### Group B — Login Flow v2 (5 scenarios)

**Purpose**: this is how NC desktop bootstraps an app password without
ever seeing the user's real password. Breaking it means no new desktop
client can pair.

| ID | Step | Assertions |
|---|---|---|
| B1 | `POST /index.php/login/v2` (no auth) | 200; JSON `{ login: "https://<host>/login/v2/grant?token=…", poll: { token: "…", endpoint: "…/login/v2/poll" } }` |
| B2 | `POST /index.php/login/v2/poll` with token from B1, *before* a grant happens | 404 (NC convention: 404 = "not yet" until the user actually grants) |
| B3 | Simulate the browser grant (`POST` the device-auth-grant endpoint with the token, authenticated as `admin`) | 200 / 204 / whatever the existing flow returns |
| B4 | `POST /index.php/login/v2/poll` after grant | 200; JSON `{ server: "<host>", loginName: "admin", appPassword: "<token>" }`. The returned app password works for Basic Auth in C1. |
| B5 | `POST /index.php/login/v2/poll` with an expired / unknown token | 404 |

---

### Group C — OCS user-info + provisioning (5 scenarios)

**Purpose**: NC desktop reads `data.id` from `/ocs/v{1,2}.php/cloud/user`
and splices it into every subsequent DAV URL. A regression here → NC
client builds the wrong DAV paths and 100% of subsequent syncs fail.

| ID | Step | Assertions |
|---|---|---|
| C1 | `GET /ocs/v1.php/cloud/user?format=json` Basic Auth `admin:<app_pw>` | 200; OCS `statuscode: 100`; `data.id == "admin"`; `data.display-name`, `data.displayname`, `data.email` present; `data.quota.{used,total,free,relative}` present |
| C2 | `GET /ocs/v2.php/cloud/user?format=json` Basic Auth | 200; OCS `statuscode: 200`; rest identical to C1 |
| C3 | `GET /ocs/v1.php/cloud/users/admin?format=json` Basic Auth `admin:<app_pw>` | 200; full profile including `groups`, `lastLogin`, `backend`, `quota` |
| C4 | `GET /ocs/v1.php/cloud/users/bob?format=json` Basic Auth `admin:<app_pw>` (where `admin` IS admin) | 200 (admin can read anyone) — OR 403 if policy says "admin-but-not-superadmin", document whichever behavior is current |
| C5 | `GET /ocs/v2.php/apps/files_sharing/api/v1/sharees?format=json&search=ad&itemType=file` | 200; envelope has `data.exact.{users,groups}` arrays + `data.users` array (may all be empty — shape matters more than content) |

---

### Group D — NC WebDAV: OPTIONS + PROPFIND read (10 scenarios)

**Purpose**: sync client's first action on every cycle. Includes a
dedicated trailing-slash regression test (D8/D9/D10) — past bug where
collection hrefs didn't end `/` aborted NC desktop with
`Invalid href "<…>" expected starting with "<requested-url>"`.

| ID | Step | Assertions |
|---|---|---|
| D1 | `OPTIONS /remote.php/dav/files/admin/` Basic Auth | 200; header `DAV: 1, 3`; header `Allow` lists OPTIONS, GET, HEAD, PUT, DELETE, MKCOL, MOVE, PROPFIND, PROPPATCH, REPORT, SEARCH |
| D2 | `PROPFIND /remote.php/dav/files/admin/` `Depth: 0` | 207; multistatus has exactly 1 `<d:response>`; href is `/remote.php/dav/files/admin/` (trailing `/`); has `<d:resourcetype><d:collection/></d:resourcetype>` and `<oc:fileid>` |
| D3 | `PROPFIND /remote.php/dav/files/admin/` `Depth: 1` on **empty home** | 207; exactly 1 `<d:response>` (collection only) |
| D4 | Upload 2 files (`a.txt`, `b.txt`) + create subfolder `sub/` via MKCOL → `PROPFIND Depth: 1` on home | 207; 4 `<d:response>` entries; files have `<d:getcontentlength>` matching their byte count; folder href ends `/`; all 4 have `<oc:fileid>` |
| D5 | `PROPFIND /remote.php/dav/files/admin/nonexistent` `Depth: 0` | 404 |
| D6 | `PROPFIND` on a **file** `Depth: 0` | 207; 1 `<d:response>`; href does NOT end `/`; has `<d:getcontentlength>`; `<d:resourcetype>` is empty (not `<d:collection/>`) |
| D7 | `PROPFIND Depth: infinity` on a 3-level tree (`/sub1/sub2/file.txt`) | 207; all descendants present (root + sub1 + sub2 + file) |
| **D8** | **PROPFIND on a SUBDIRECTORY** (not the home root) `Depth: 0` | **207; the subdirectory's own `<d:response>` href ends with `/`** (regression guard — NC desktop aborts otherwise) |
| **D9** | **PROPFIND on a SUBDIRECTORY** `Depth: 1` containing 2 files + 2 subfolders | **207; 5 responses total. The subdir's OWN href ends `/`. The 2 subfolder responses' hrefs both end `/`. The 2 file responses' hrefs do NOT end `/`. This catches the mixed-collection regression.** |
| **D10** | **PROPFIND on home `Depth: 1` containing mixed content** (3 files + 2 folders) | **207; 6 responses. Hrefs validated per type: collections always `/`, files never `/`. Check the OWN entry (admin/) also ends `/`. This catches both regressions in one shot.** |

**Implementation hint for D8/D9/D10**: parse the multistatus XML and
for each `<d:response>`, pair its `<d:href>` against its
`<d:resourcetype>`. Assertion: if `<d:collection/>` is present →
href MUST end `/`; if not → href MUST NOT end `/`. Loop and assert.

| D11 | `PROPFIND` with malformed XML body (e.g. truncated tag) | 400 |

---

### Group E — NC WebDAV: GET / HEAD / Range (6 scenarios)

**Purpose**: downloads + conditional GETs. Catches stale-content
regressions (the `file_id → blob_hash` cache invalidation bug fixed in
`f4ce4092`).

| ID | Step | Assertions |
|---|---|---|
| E1 | Upload 32 B text → `GET` it | 200; body equals upload; `Content-Type: text/plain`; `ETag` header present and quoted (`"…"`); `Last-Modified` present; `Content-Length: 32` |
| E2 | `HEAD` on E1's file | Same headers as E1; empty body; no Content-Length disagreement |
| E3 | `GET` on non-existent path | 404 |
| E4 | `GET` on a collection | Whatever OxiCloud returns today (likely 200 with empty body or 404) — pin the current behavior and document |
| E5 | Upload 1 MB random → `GET` with `Range: bytes=0-1023` | 206; body is exactly 1024 bytes; `Content-Range: bytes 0-1023/1048576`; `Accept-Ranges: bytes` |
| E6 | `GET` with `If-None-Match: "<etag>"` matching the stored ETag | 304; empty body; no Content-Length |

---

### Group F — NC WebDAV: PUT / MKCOL + BLAKE3 round-trip (10 scenarios)

**Purpose**: file + folder creation. Includes the
**content-hash integrity check** Ed requested: server's stored
`content_hash` (REST API) must equal the local BLAKE3 of the bytes
the client uploaded.

| ID | Step | Assertions |
|---|---|---|
| F1 | `PUT /remote.php/dav/files/admin/new.txt` body `hello` | 201; `ETag` + `oc-etag` headers; body empty; `oc-fileid` header present |
| F2 | `GET` F1's file | body `hello`; ETag matches F1's |
| F3 | `PUT` overwrite F1 with new content `goodbye` | 204; NEW ETag (different from F1) |
| F4 | After F3, `GET` → body `goodbye` (catches the file_id→blob_hash stale-cache regression) |
| F5 | `PUT` with `If-None-Match: *` on existing path | 412 |
| F6 | `PUT` with `If-Match: "<wrong-etag>"` | 412 |
| F7 | `PUT` 10 MB random binary → assert `GET` returns same bytes (integrity over streaming) |
| **F8** | **BLAKE3 round-trip (small file)**: locally compute `b3sum hello.txt` → `PUT` via NC → after PUT, extract the file's id (from `oc-fileid` header or PROPFIND), then `GET /api/files/{id}` (REST API, JWT-auth as admin) → assert the returned `FileDto.content_hash` field equals the local `b3sum` value | content_hash matches BLAKE3 of uploaded bytes |
| **F9** | **BLAKE3 round-trip (10 MB streamed file)**: same as F8 but with the 10 MB fixture — exercises the streaming hash-on-write path | content_hash matches |
| F10 | `MKCOL /remote.php/dav/files/admin/newfolder/` | 201; subsequent PROPFIND sees it with `<d:collection/>` and trailing-slash href |
| F11 | `MKCOL` where parent missing | 409 |
| F12 | `MKCOL` on existing folder | 405 |

---

### Group G — NC WebDAV: MOVE / COPY / DELETE (9 scenarios)

| ID | Step | Assertions |
|---|---|---|
| G1 | Setup `a.txt` → `MOVE` with `Destination: http://<host>/remote.php/dav/files/admin/b.txt` | 201 (new) or 204; PROPFIND home: `b.txt` present, `a.txt` absent |
| G2 | `MOVE` file to a different folder | 201/204; file at destination; gone from source folder |
| G3 | `MOVE` with `Destination` whose URL-encoded segments contain ` `, `#`, `%` | succeeds; resulting name correctly decoded (verify via PROPFIND) |
| G4 | `MOVE` to existing path with `Overwrite: F` | 412 |
| G5 | `MOVE` to existing path with `Overwrite: T` | 204; replaces |
| G6 | `MOVE` folder (recursive subtree) | 201/204; full subtree visible at new location; gone from old |
| G7 | `COPY` file with `Destination` | 201; source still present; destination has identical content + new ETag |
| G8 | `DELETE` file | 204; `GET` → 404; trashbin PROPFIND (group K) sees it |
| G9 | `DELETE` folder | 204; recursive, all descendants also gone (`GET` on any descendant → 404) |

---

### Group H — NC WebDAV: PROPPATCH (favorites) (3 scenarios)

| ID | Step | Assertions |
|---|---|---|
| H1 | `PROPPATCH` on a file, body sets `<oc:favorite>1</oc:favorite>` | 207 multistatus; status row says `HTTP/1.1 200 OK` for `oc:favorite` |
| H2 | After H1, `REPORT /remote.php/dav/files/admin/` with `<oc:filter-files>` body filtering on `<oc:favorite>1</oc:favorite>` | 207; multistatus contains the file from H1 |
| H3 | `PROPPATCH` `<oc:favorite>0</oc:favorite>` to unset → `REPORT` favorites | 207; file no longer in favorites list |

---

### Group I — NC WebDAV: REPORT (favorites filter + search) (4 scenarios)

| ID | Step | Assertions |
|---|---|---|
| I1 | `REPORT` favorites filter on empty home | 207; empty multistatus (no `<d:response>`) |
| I2 | `REPORT` favorites filter with 3 favorited files | 207; exactly 3 responses; each has favorited file href + correct trailing-slash semantics |
| I3 | `REPORT` `<d:searchrequest>` for `where name contains "foo"` on a home with `foo.txt`, `bar.txt`, `foobar.txt` | 207; responses for `foo.txt` and `foobar.txt`, NOT for `bar.txt` |
| I4 | `REPORT` search with `<d:nresults>2</d:nresults>` and 5 candidates | 207; exactly 2 responses |

---

### Group J — NC chunked uploads + BLAKE3 round-trip (10 scenarios)

**Purpose**: the most fragile NC subsurface — gets hammered by sync
clients on every large upload. Includes BLAKE3 integrity on assembly.

| ID | Step | Assertions |
|---|---|---|
| J1 | `MKCOL /remote.php/dav/uploads/admin/sess-001/` | 201 |
| J2 | `PUT /remote.php/dav/uploads/admin/sess-001/00000001` body 5 KB | 201 |
| J3 | `PUT .../00000002` body 5 KB different content | 201 |
| J4 | `PROPFIND /remote.php/dav/uploads/admin/sess-001/` `Depth: 1` | 207; 3 responses (collection + 2 chunks); collection href ends `/`; chunk hrefs don't; chunks have `<d:getcontentlength>` matching upload sizes |
| J5 | `MOVE /remote.php/dav/uploads/admin/sess-001/.file` `Destination: /remote.php/dav/files/admin/assembled.bin` | 201; response has `ETag` + `oc-etag` headers |
| J6 | `GET /remote.php/dav/files/admin/assembled.bin` | 200; body length == sum of chunks; bytes match concatenation of J2 + J3 |
| **J7** | **BLAKE3 round-trip on assembled file**: local BLAKE3 of `concat(chunk1, chunk2)` → after J5, lookup `assembled.bin`'s id and `GET /api/files/{id}` (REST) → assert `FileDto.content_hash` == local BLAKE3 | matches (proves the hash-on-write during assembly produces the canonical BLAKE3) |
| J8 | New session, `PUT` chunk larger than `OXICLOUD_CHUNK_MAX_BYTES` (4 MiB in test env) | 413 |
| J9 | New session, MKCOL → `DELETE /remote.php/dav/uploads/admin/sess-002/` | 204; subsequent PROPFIND on `/uploads/admin/sess-002/` returns 404 |
| J10 | After J5, `PROPFIND /remote.php/dav/uploads/admin/sess-001/` | 404 (the session is purged after `.file` assembly) |

---

### Group K — Trashbin DAV (5 scenarios)

| ID | Step | Assertions |
|---|---|---|
| K1 | After G8, `PROPFIND /remote.php/dav/trashbin/admin/trash/` `Depth: 1` | 207; ≥2 responses (collection + at least the deleted item); each item has `<nc:trashbin-original-location>` with original path |
| K2 | `MOVE /remote.php/dav/trashbin/admin/trash/<trashed_id>` `Destination: /remote.php/dav/files/admin/restored.txt` | 201; restored at destination |
| K3 | Delete a file → `DELETE /remote.php/dav/trashbin/admin/trash/<trashed_id>` (permanent) | 204; trashbin PROPFIND no longer lists it |
| K4 | Delete 3 files → `DELETE /remote.php/dav/trashbin/admin/trash` (empty all) | 204; trashbin PROPFIND has only the collection |
| K5 | `MOVE` from trash to a destination where a same-named file already exists | pin current behavior (412? rename suffix? whichever it does today) |

---

### Group L — Avatar + preview (3 scenarios)

| ID | Step | Assertions |
|---|---|---|
| L1 | `GET /index.php/avatar/admin/64` | 200 (image bytes, Content-Type `image/*`) OR 404 — pin current behavior |
| L2 | `GET /index.php/core/preview?fileId=<id>&x=128&y=128` for an image file | 200 with image OR 404 if preview-on-demand is off — pin behavior |
| L3 | `GET /index.php/avatar/nonexistent/64` | 404 |

---

### Group M — Native WebDAV `/webdav/…` (8 scenarios)

**Purpose**: rclone, WebDAV-mounted clients, third-party tools. The
native surface has different chroot semantics (implicit home folder)
and **advertises LOCK** (Class 2).

| ID | Step | Assertions |
|---|---|---|
| M1 | `OPTIONS /webdav/` | 200; header `DAV: 1, 2`; `Allow` lists `LOCK`, `UNLOCK` |
| **M2** | **`PROPFIND /webdav/` `Depth: 1` containing 2 files + 2 subfolders** | **207; 5 responses; collections end `/`, files don't (same trailing-slash regression guard as D9/D10 on the native surface)** |
| M3 | `PUT /webdav/sample.txt` 5 KB body | 201; ETag header |
| M4 | `GET /webdav/sample.txt` with `Range: bytes=0-9` | 206; first 10 bytes; correct Content-Range |
| M5 | `MOVE /webdav/sample.txt` `Destination: /webdav/moved.txt` | 201/204; verify via PROPFIND |
| M6 | `MKCOL /webdav/sub/` | 201; PROPFIND lists it with trailing-slash href |
| M7 | `DELETE /webdav/sub/` | 204; PROPFIND no longer lists it |
| M8 | `COPY /webdav/a.txt` `Destination: /webdav/b.txt` | 201; both exist with same content |

---

### Group N — LOCK / UNLOCK on `/webdav/` (3 scenarios)

| ID | Step | Assertions |
|---|---|---|
| N1 | `LOCK /webdav/locked.txt` body `<d:lockinfo>` with `<d:owner>test</d:owner>`, header `Timeout: Second-60` | 200; response body has `<d:locktoken><d:href>opaquelocktoken:…</d:href>`; `Lock-Token` header set |
| N2 | `PUT /webdav/locked.txt` from a different lock context (no `If: (<token>)`) | 423 Locked |
| N3 | `UNLOCK /webdav/locked.txt` with header `Lock-Token: <opaquelocktoken:…>` | 204; subsequent `PUT` (no `If` header) succeeds |

---

### Group O — Cross-user isolation (security baseline) (4 scenarios)

Setup: `alice` and `bob`, each with home folder + a file `secret.txt`.

| ID | Step | Assertions |
|---|---|---|
| O1 | Auth as `alice`, `PROPFIND /remote.php/dav/files/bob/` `Depth: 0` | 403 |
| O2 | Auth as `alice`, `GET /remote.php/dav/files/alice/../bob/secret.txt` | 400 (path traversal rejected at the DAV path validator) |
| O3 | Auth as `alice`, `MOVE /remote.php/dav/files/alice/x.txt` `Destination: /remote.php/dav/files/bob/x.txt` | 403 |
| O4 | Auth as `alice`, `PROPFIND /remote.php/dav/files/alice/` `Depth: 1` after bob has uploaded `bob-only.txt` | none of bob's files appear in the response |

---

### Group P — Auth failure / lockout / external user (5 scenarios)

| ID | Step | Assertions |
|---|---|---|
| P1 | `PROPFIND /remote.php/dav/files/admin/` no `Authorization` header | 401; `WWW-Authenticate: Basic realm="OxiCloud"` |
| P2 | Same with wrong password | 401; audit log emits `target=audit event=auth.login_rejected reason=bad_password` (or NC-specific equivalent) |
| P3 | 6 wrong attempts within the lockout window from `IP1` (test env: window 60 s, threshold 5) → 7th attempt **with correct password** | 401 / 429 (locked); audit log emits `target=audit event=auth.nc_basic_rejected reason=account_ip_locked` |
| P4 | Continuing P3: same correct credentials from a different `IP2` | 200 (per-IP scope; the #323 regression guard) |
| P5 | Auth a user flagged `is_external=true` (admin SQL fixture) | 401; audit log emits `target=audit event=auth.nc_basic_rejected reason=external_user` |

---

## 5. What this catches when Drive lands

For each scenario above, the **bare-username default-drive path** must
behave identically on the Drive branch. The Drive PR will then add (as
*additive* groups, not replacements):

- **D' / J' / K' multi-drive PROPFIND/upload/trash**: same as D / J / K
  but with URL `/remote.php/dav/files/admin~<drive_uuid>/…`. Responses'
  hrefs must echo the composite form `admin~<drive_uuid>`.
- **Drive-mismatch suite**: auth as `admin~A`, URL says `admin~B` → 403;
  same for missing or unauthorized drive UUIDs.
- **Mixed-mode suite**: bare URL while auth was composite → 403; composite
  URL while auth was bare → 403 (pending exact policy).

If A–P all stay green on the Drive branch with default-drive (bare)
URLs, the multi-drive refactor didn't regress the legacy path.

---

## 6. Suggested implementation order

1. **Batch 1**: A + B + C + P (auth bootstrap + identity + failure modes).
   Small, foundational, unblocks every later batch.
2. **Batch 2**: D + E (PROPFIND + GET — the read surface NC client touches
   first on every sync cycle). **Includes D8/D9/D10 trailing-slash guards.**
3. **Batch 3**: F + G + K (write + mutate + trash — the actual file
   mutation surface). **Includes F8/F9 BLAKE3 round-trip checks.**
4. **Batch 4**: J (chunked uploads — most fragile + most-touched-by-Drive
   work). **Includes J7 BLAKE3 round-trip.**
5. **Batch 5**: H + I + M + N (favorites, search, native DAV, LOCK).
   **Includes M2 native-DAV trailing-slash guard.**
6. **Batch 6**: O + L (cross-user isolation, avatars).

Each batch is independently runnable; batch 1+2+3 alone gives meaningful
regression signal even if the rest hasn't shipped.

---

## 7. Open questions / TODOs before implementation

- **C4**: confirm whether OxiCloud's policy says "admin can read any user
  profile" (200) or "admin can only read self" (403). Pin behavior before
  writing the assertion.
- **E4**: pin behavior of `GET` on a collection (currently appears to be
  200 with empty body — confirm and document).
- **K5**: pin behavior of restoring a trashed item to a path with a same-named existing file (rename? 412? overwrite?).
- **L1 / L2**: pin avatar + preview behavior (200 vs 404 by default).
- **Sharees autocomplete (C5)**: confirm `itemType=file` is the
  parameter NC desktop sends, vs `itemType=0`.
- **Lockout threshold in test env**: standardise to a small value (5
  attempts / 60 s window) via `OXICLOUD_AUTH_*` env vars in
  `tests/common/server.env` so P3/P4 are deterministic.

---

## 8. Test data shape summary

| Fixture | Size | Source | Used in |
|---|---|---|---|
| `tests/fixtures/hello.txt` | 32 B | existing | D, E, F, G, K |
| `tests/fixtures/hello-copy.txt` | 32 B (same content) | existing | (dedup tests, not needed here) |
| `tests/fixtures/medium-1mb.bin` | 1 MiB | random, generated by run.sh | E5, F7, M4 |
| `tests/fixtures/large-10mb.bin` | 10 MiB | random, gitignored, generated by run.sh | F7, F9 |
| `tests/fixtures/chunk-pair-a.bin` | 5 KiB | random | J2 |
| `tests/fixtures/chunk-pair-b.bin` | 5 KiB | random | J3 |
| `tests/fixtures/chunk-over-cap-5mb.bin` | 5 MiB | existing (gitignored, generated) | J8 |
| `tests/fixtures/small-image.png` | small | TBD (need to add or skip L2) | L2 |

---

## 9. Regression-signal matrix

Quick reference for "if this test fails, which past bug am I rediscovering":

| Failing test | Likely root cause |
|---|---|
| D8 / D9 / D10 / M2 (collection hrefs without trailing `/`) | href-builder regressed past `nc_collection_href` invariant |
| F4 (GET after overwrite shows old content) | file_id→blob_hash cache invalidation regressed (the bug fixed in `f4ce4092`) |
| F8 / F9 / J7 (content_hash mismatch) | hash-on-write streaming pipeline produced wrong BLAKE3 (or the wrong field is on FileDto — the `etag` vs `content_hash` split regression from `0135930d`) |
| C1 / C2 (`data.id` doesn't echo expected username) | OCS handler regressed (e.g. NC desktop won't build correct DAV paths on the next sync) |
| D2 / D6 (resourcetype/href mismatch on collection-vs-file) | adapter regressed the file-vs-collection distinction |
| O1 / O3 (cross-user write succeeds) | **AuthZ regression** — security boundary broken |
| P3 / P4 (lockout scope wrong) | #323 per-(account, IP) lockout regressed back to per-account-only |
| P5 (external user logged in via NC) | external-user gate regressed |

---

*Maintainer note: when a scenario passes that was previously failing,
update the test (don't delete the assertion) — the regression-signal
matrix is more useful when each row stays alive as a checkbox.*
