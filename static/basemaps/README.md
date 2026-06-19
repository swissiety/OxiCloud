# Places basemap (optional)

The **Places** photo map renders your geotagged photos as clusters. It works
out of the box **without** a basemap (clusters on a plain background). To get a
real street/terrain backdrop, drop a self-hosted vector basemap here — no
third-party tile API, fully offline.

## How it works (Approach "A")

OxiCloud already serves `static/` through `tower-http`'s `ServeDir`, which
honours **HTTP Range** requests. A [PMTiles](https://docs.protomaps.com/pmtiles/)
basemap is a *single file* read directly by the browser via Range — so the
basemap is just a static file the app already knows how to serve. No extra
backend, no tile server, no API keys.

## Enabling it

1. Get a Protomaps `.pmtiles` basemap (vector, ODbL OpenStreetMap data):
   - Whole planet z0–15 (~120 GB) or a smaller global `z0-6` (~60 MB), or
   - A **regional extract** (recommended — only the area you need, a few MB):
     ```sh
     # one-time, downloads only your bounding box from the remote planet
     pmtiles extract https://build.protomaps.com/<DATE>.pmtiles basemap.pmtiles \
       --bbox=<west>,<south>,<east>,<north>
     ```
     See https://docs.protomaps.com/basemaps/downloads
2. Place it here as **`static/basemaps/basemap.pmtiles`** (this path is
   git-ignored on purpose — see `.gitignore`).
3. Reload the Places view. The map will pick it up automatically.

The bundled style is **label-light** (water / land / roads / buildings, no
text) so it needs no glyph/sprite assets. Attribution “© OpenStreetMap”
(ODbL) is shown automatically when a basemap is present.
