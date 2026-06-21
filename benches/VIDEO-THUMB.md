# Video thumbnails — server-side ffmpeg (Option B)

Video thumbnails are now generated **server-side on upload**: a lifecycle hook
streams the (decrypted) blob to a temp file, `ffmpeg` extracts one representative
frame, and that frame goes through the **same WebP pipeline as photos** — so
video thumbnails are WebP, blob-hash keyed (dedup'd), and content-negotiated,
exactly like images.

This replaces the old browser path, which only generated a thumbnail when the
Photos grid first rendered a video tile, the `<img>` 404'd, and the browser
**re-downloaded the video** to seek a frame and PUT 3 JPEGs back.

## What it buys

1. **Coverage incl. HEVC/iPhone.** The browser `<video>` element cannot decode
   HEVC/H.265 (`.mov` from iPhones), ProRes, many mkv/avi — so the old path
   produced **no** thumbnail for them. ffmpeg decodes all of them.
2. **No client re-download.** The frame is taken server-side from the blob the
   server already has — the browser never pulls the video back.
3. **Eager.** Thumbnails are ready before the gallery asks; tiles paint
   immediately instead of waiting on a failed `<img>` + re-download cascade.

## Reproduce

```bash
cargo run --release --features bench --example bench_video_thumbnails
```

Requires `ffmpeg` on PATH (with libx264/libx265/libvpx-vp9 to synthesize the
test corpus — written to `benches/corpus/`, git-ignored). The corpus is a
`testsrc` pattern at several codecs/resolutions, incl. an HEVC `.mov`.

## Results (14 cores, ffmpeg 8.1)

| case            | video KB | extract ms | frame KB | icon | preview | large (WebP B) | ok |
|-----------------|---------:|-----------:|---------:|-----:|--------:|---------------:|----|
| h264 720p       |     46.9 |       49.2 |     44.1 | 1818 |    3836 |           6844 | ✅ |
| h264 1080p      |     76.1 |       64.9 |     37.9 | 1844 |    3888 |           6870 | ✅ |
| HEVC 1080p .mov |     38.6 |       69.5 |     51.9 | 1858 |    3928 |           6976 | ✅ |
| VP9 720p .webm  |    187.8 |       67.8 |     14.6 | 1824 |    3814 |           6650 | ✅ |

- **Coverage: 4/4 codecs, including HEVC/.mov** — the browser path produced 0 for
  HEVC. Going from "no thumbnail" to "a thumbnail" is the real headline for
  iPhone footage.
- **Extraction: ~50–70 ms/frame** for 720p–1080p. Paid once, in a background task,
  per unique blob — never on the request path. Bounded by a per-process timeout
  and a dedicated concurrency semaphore.
- **Served bytes per tile: ~3.8 KB (preview WebP)** — same compact WebP as photos.

### Transfer per first view (the bandwidth win)

```
OLD (browser re-downloads the video, worst case): 349 KB for 4 tiles  +  3 JPEG PUTs/video
NEW (fetch the server WebP preview):               15.1 KB             +  0 client decode
→ ~23× less data on this corpus.
```

> ⚠️ The test clips are tiny (3 s `testsrc`, 38–188 KB), which **understates** the
> win enormously. Real phone videos are 10–100+ MB; the old path re-downloaded a
> large fraction of that per first view, vs ~4 KB now — i.e. thousands-fold less
> for a 50 MB clip, plus it works for HEVC at all.

## How it's wired

- `application/ports/video_frame_ports.rs` — `VideoFramePort` (extract one PNG
  frame from a video file).
- `infrastructure/services/ffmpeg_video_frame_service.rs` — shells out to the
  system `ffmpeg` (no compile-time libav dep); `NoopVideoFrameService` when
  ffmpeg is absent/disabled, so videos degrade to "no thumbnail" gracefully.
- `ThumbnailRefreshHook::on_file_created` routes `video/*` to
  `generate_video_thumbnails_background`, which streams the blob to a temp file
  (capped, decrypting), extracts a frame, and reuses `render_and_persist_all_webp`.
- GET `/api/files/{id}/thumbnail/{size}` serves the blob-hash WebP for videos
  too; a miss returns 204 (generation in flight / unavailable).

## Config

| Env | Default | Meaning |
|---|---|---|
| `OXICLOUD_ENABLE_VIDEO_THUMBNAILS` | `true` | Master switch (also needs ffmpeg present). |
| `OXICLOUD_FFMPEG_PATH` | `ffmpeg` | Path to the ffmpeg binary. |
| `OXICLOUD_VIDEO_THUMBNAIL_CONCURRENCY` | `cpus/2` | Max concurrent ffmpeg processes. |
| `OXICLOUD_VIDEO_THUMBNAIL_TIMEOUT_SECS` | `30` | Per-extraction wall-clock cap. |
| `OXICLOUD_VIDEO_THUMBNAIL_MAX_MB` | `2048` | Skip videos larger than this (no temp materialise). |

The Docker runtime image installs `ffmpeg`. Existing videos uploaded before this
change get a thumbnail the next time their blob is (re)created; a backfill task
is a possible follow-up.
