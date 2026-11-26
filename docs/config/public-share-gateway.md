# Public Share Links Only

A common self-hosted setup: OxiCloud lives on your LAN or behind a VPN, and
only **public share links** should be reachable from the internet. Visitors
open `https://cloud.example.com/s/<token>`, browse the shared folder and
download files. The file browser, admin panel, login, WebDAV, CalDAV and the
NextCloud API stay unreachable from outside.

No extra service is needed for this. It is a reverse-proxy allowlist,
configured in the nginx or Traefik you already run for TLS.

::: tip Requires OxiCloud 0.10.0 or newer
Since 0.10.0 a public share is **a login method, not a separate API**. Older
share proxies that call the `/api/s/<token>/download`, `/contents`, `/file`
and `/zip` endpoints no longer work, because those endpoints were removed.
:::

## How a share visit works

1. The visitor opens `/s/<token>`. OxiCloud serves the normal web app (SPA).
2. The page calls `GET /api/s/<token>`, or `POST /api/s/<token>/verify` for a
   password-protected link. This checks the token, applies the password and
   expiry rules, and sets the `oxi_shares` cookie. The visitor now holds an
   **anonymous session**.
3. Browsing, thumbnails, downloads and ZIPs go through the ordinary
   `/api/folders/*` and `/api/files/*` routes. Access is decided by the grant
   the share carries.

The server already limits anonymous sessions to seven read-only `GET` routes
and refuses everything else with `403`. This list lives in
[`src/interfaces/middleware/anonymous_allowlist.rs`](https://github.com/DioCrafts/OxiCloud/blob/main/src/interfaces/middleware/anonymous_allowlist.rs):

| Route | Used for |
|---|---|
| `GET /api/folders/{id}` | folder metadata |
| `GET /api/folders/{id}/resources` | folder listing |
| `GET /api/folders/{id}/ancestors` | breadcrumb |
| `GET /api/folders/{id}/download` | folder as ZIP |
| `GET /api/files/{id}` | download / inline view (supports `Range`) |
| `GET /api/files/{id}/thumbnail/{size}` | grid thumbnails |
| `GET /api/files/{id}/metadata` | lightbox details |

The proxy config on this page mirrors that list at the edge. **The edge
filter is defence in depth; the server-side allowlist is the authoritative
gate.** Any path the proxy lets through is still subject to the share's grant
and to the anonymous allowlist.

## Recommended layout: one hostname, split by network

Use **one** hostname for everybody, for example `cloud.example.com`, and let
the proxy decide by client address:

- **From the LAN or VPN:** everything is passed through. This is your normal
  OxiCloud.
- **From the internet:** only share pages, static assets and the routes above.
  Everything else gets `404`.

This keeps `OXICLOUD_BASE_URL` coherent. OxiCloud uses that single URL for
share links, but also for OIDC callbacks, magic-link (email invitation) links,
NextCloud login flow v2 and the post-logout redirect. A separate "share-only"
hostname would need `OXICLOUD_BASE_URL` set to that hostname, which breaks all
of the others for your internal users.

```sh
# .env
OXICLOUD_BASE_URL=https://cloud.example.com
# Address(es) your reverse proxy connects from. Required so OxiCloud reads
# the real client IP (the share-password rate limiter keys on it) and the
# real scheme (DPoP).
OXICLOUD_TRUST_PROXY_CIDR=127.0.0.1/32
```

Internal clients must reach the proxy with their **internal** source
address. Use split-horizon DNS (`cloud.example.com` resolves to the proxy's
LAN IP on your network) or a VPN. With hairpin NAT through your router, the
proxy may see the router's address instead. Check this before relying on it
(see [Verify](#verify)).

::: warning Email invitations need the full app
Sharing **by email** signs the recipient in as an external user with a full
session in the web app. Under this layout, such recipients have to be on your
network or VPN. Public links, with or without a password, work from anywhere.
:::

## nginx

Put the shared proxy settings in a snippet. In nginx, a `location` that sets
any `proxy_set_header` **drops all inherited ones**, so including a snippet in
each location is the reliable way to keep the `X-Forwarded-*` headers that
DPoP needs.

```nginx
# /etc/nginx/snippets/oxicloud-proxy.conf
proxy_pass         http://oxicloud;
proxy_http_version 1.1;
proxy_set_header   Host              $host;
proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
proxy_set_header   X-Forwarded-Proto $scheme;
proxy_set_header   X-Forwarded-Host  $host;
proxy_set_header   Upgrade           $http_upgrade;
proxy_set_header   Connection        $oxi_connection;
proxy_buffering           off;   # stream downloads and ZIPs
proxy_request_buffering   off;   # stream uploads (internal users)
proxy_read_timeout        1h;
```

```nginx
# /etc/nginx/conf.d/oxicloud.conf
upstream oxicloud {
    server 127.0.0.1:8086;
    keepalive 16;
}

# Who counts as "internal". Keep this list tight.
geo $oxi_internal {
    default         0;
    10.0.0.0/8      1;
    172.16.0.0/12   1;
    192.168.0.0/16  1;
    fd00::/8        1;
}

# Internal clients may use any method. Internet clients get only what each
# public location allows.
map "$oxi_internal:$request_method" $oxi_get_ok {
    "~^1:"   1;
    "0:GET"  1;
    default  0;
}
map "$oxi_internal:$request_method" $oxi_post_ok {
    "~^1:"   1;
    "0:POST" 1;
    default  0;
}

map $http_upgrade $oxi_connection {
    default upgrade;
    ""      "";
}

server {
    listen 443 ssl;
    http2 on;
    server_name cloud.example.com;
    # ssl_certificate / ssl_certificate_key ...

    client_max_body_size 0;

    # ---- Public: share page and the static assets it loads -------------
    location ~ ^/s/[^/]+$ {
        if ($oxi_get_ok = 0) { return 404; }
        include snippets/oxicloud-proxy.conf;
    }
    location ~ ^/(_app|locales|logo)/ {
        if ($oxi_get_ok = 0) { return 404; }
        include snippets/oxicloud-proxy.conf;
    }
    location ~ ^/(favicon\.ico|manifest\.webmanifest|robots\.txt|service-worker\.js|sw\.js)$ {
        if ($oxi_get_ok = 0) { return 404; }
        include snippets/oxicloud-proxy.conf;
    }

    # ---- Public: share "login" -----------------------------------------
    location = /api/config {
        if ($oxi_get_ok = 0) { return 404; }
        include snippets/oxicloud-proxy.conf;
    }
    location ~ ^/api/s/[^/]+$ {
        if ($oxi_get_ok = 0) { return 404; }
        include snippets/oxicloud-proxy.conf;
    }
    location ~ ^/api/s/[^/]+/verify$ {
        if ($oxi_post_ok = 0) { return 404; }
        include snippets/oxicloud-proxy.conf;
    }

    # ---- Public: the anonymous allowlist (GET only from outside) -------
    location ~ ^/api/folders/[^/]+(/(resources|ancestors|download))?$ {
        if ($oxi_get_ok = 0) { return 404; }
        include snippets/oxicloud-proxy.conf;
    }
    location ~ ^/api/files/[^/]+(/(metadata|thumbnail/[^/]+))?$ {
        if ($oxi_get_ok = 0) { return 404; }
        include snippets/oxicloud-proxy.conf;
    }

    # ---- Everything else: internal only --------------------------------
    location / {
        if ($oxi_internal = 0) { return 404; }
        include snippets/oxicloud-proxy.conf;
    }
}
```

`if` blocks that contain only `return` are safe in nginx. The limits on
`if` apply to other directives inside it.

## Traefik (v3)

Traefik picks the matching router with the highest priority. One router
passes everything for internal clients. Two routers handle the public share
surface. Requests that match no router get Traefik's own `404`.

```yaml
# docker-compose.override.yml (labels on the oxicloud service)
services:
  oxicloud:
    labels:
      - "traefik.enable=true"
      - "traefik.http.services.oxicloud.loadbalancer.server.port=8086"

      # 1. Internal clients: everything.
      - "traefik.http.routers.oxi-internal.rule=Host(`cloud.example.com`) && (ClientIP(`10.0.0.0/8`) || ClientIP(`172.16.0.0/12`) || ClientIP(`192.168.0.0/16`))"
      - "traefik.http.routers.oxi-internal.priority=100"
      - "traefik.http.routers.oxi-internal.entrypoints=websecure"
      - "traefik.http.routers.oxi-internal.tls.certresolver=letsencrypt"
      - "traefik.http.routers.oxi-internal.service=oxicloud"

      # 2. Internet: share page, assets, share login, anonymous reads (GET).
      - "traefik.http.routers.oxi-share-read.rule=Host(`cloud.example.com`) && Method(`GET`) && (PathRegexp(`^/s/[^/]+$`) || PathRegexp(`^/(_app|locales|logo)/`) || PathRegexp(`^/(favicon\\.ico|manifest\\.webmanifest|robots\\.txt|service-worker\\.js|sw\\.js)$`) || Path(`/api/config`) || PathRegexp(`^/api/s/[^/]+$`) || PathRegexp(`^/api/folders/[^/]+(/(resources|ancestors|download))?$`) || PathRegexp(`^/api/files/[^/]+(/(metadata|thumbnail/[^/]+))?$`))"
      - "traefik.http.routers.oxi-share-read.priority=50"
      - "traefik.http.routers.oxi-share-read.entrypoints=websecure"
      - "traefik.http.routers.oxi-share-read.tls.certresolver=letsencrypt"
      - "traefik.http.routers.oxi-share-read.service=oxicloud"

      # 3. Internet: password submit for protected links.
      - "traefik.http.routers.oxi-share-verify.rule=Host(`cloud.example.com`) && Method(`POST`) && PathRegexp(`^/api/s/[^/]+/verify$`)"
      - "traefik.http.routers.oxi-share-verify.priority=50"
      - "traefik.http.routers.oxi-share-verify.entrypoints=websecure"
      - "traefik.http.routers.oxi-share-verify.tls.certresolver=letsencrypt"
      - "traefik.http.routers.oxi-share-verify.service=oxicloud"
```

`ClientIP` matches the TCP peer address, not `X-Forwarded-For`. When Traefik
runs in Docker, make sure it sees real client addresses: publish its ports in
`host` mode, or run it with `network_mode: host`. Otherwise every request
appears to come from a Docker bridge address, which falls inside
`172.16.0.0/12`, and **the whole internet would count as internal**. If you
cannot guarantee real addresses, drop `172.16.0.0/12` from the internal list.

Use `OXICLOUD_TRUST_PROXY_CIDR` for Traefik's Docker network, as described in
[Deployment & Docker → Traefik](/config/deployment#traefik-docker-compose-same-host).

## Verify

Run these **from outside your network**, for example from a phone on mobile
data or a cheap VPS. Replace `TOKEN` with a real public-link token.

```sh
H=https://cloud.example.com

# Share surface reachable
curl -s -o /dev/null -w '%{http_code}\n' "$H/s/TOKEN"          # 200
curl -s -o /dev/null -w '%{http_code}\n' "$H/api/s/TOKEN"      # 200 (or 401 if password-protected)

# Everything else hidden
curl -s -o /dev/null -w '%{http_code}\n' "$H/"                 # 404
curl -s -o /dev/null -w '%{http_code}\n' "$H/login"            # 404
curl -s -o /dev/null -w '%{http_code}\n' -X POST "$H/api/auth/login"   # 404
curl -s -o /dev/null -w '%{http_code}\n' -X PROPFIND "$H/webdav/"      # 404
curl -s -o /dev/null -w '%{http_code}\n' "$H/remote.php/dav/"  # 404
curl -s -o /dev/null -w '%{http_code}\n' "$H/status.php"       # 404

# Writes refused even on allowlisted paths
curl -s -o /dev/null -w '%{http_code}\n' -X DELETE "$H/api/files/x"    # 404
```

Then open a share link in a private browser window and check the browser
devtools **Network** tab. Every request should be `2xx`, except an expected
`404` for `/api/auth/me`: the app checks for a signed-in user on load and
treats "not reachable" as "not signed in".

From **inside** the network, log in normally and check that uploads,
WebDAV and the admin panel still work. If internal requests get `404`, the
proxy is not seeing your internal address (see hairpin NAT above).

## Keeping it in sync

The edge list mirrors `ANONYMOUS_ALLOWLIST` in
`src/interfaces/middleware/anonymous_allowlist.rs`. Check the release notes
when upgrading. If a release adds a route there (a new share-visible feature),
add it to the proxy too. If you forget, nothing leaks: the new feature just
returns `404` for internet visitors until the proxy catches up.

## What this does not change

- **Authorization** stays in OxiCloud. The proxy only narrows which paths
  are reachable at all. Expiry, download caps, password checks and read-only
  enforcement are all done by the server.
- **Rate limiting** of share passwords is built in. It uses the login limits
  and is keyed on the client IP, which is why `OXICLOUD_TRUST_PROXY_CIDR`
  matters. You can add `limit_req` in nginx on the `/verify` location as an
  extra layer.
- **The web app bundle** (`/_app/`) is public. It contains code, not data.
  Every API call it could make beyond the routes above gets `404` from the
  proxy.
