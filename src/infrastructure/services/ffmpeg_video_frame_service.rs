//! ffmpeg-backed video frame extractor (and a no-op fallback).
//!
//! Shells out to the system `ffmpeg` binary rather than linking libav*: no
//! compile-time dependency, no binary bloat, and it decodes every container the
//! browser `<video>` element cannot (HEVC/MOV, ProRes, mkv/avi/wmv…). The
//! extracted still frame is handed to the existing image thumbnail pipeline, so
//! video thumbnails become first-class: WebP, blob-hash keyed (dedup'd), and
//! served through the same content negotiation as photos.

use async_trait::async_trait;
use bytes::Bytes;
use std::path::Path;
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;
use tokio::process::Command;
use tokio::sync::Semaphore;
use tokio::time::timeout;

use crate::application::ports::video_frame_ports::VideoFramePort;
use crate::common::errors::DomainError;

/// PNG file signature — guards against feeding a non-image (or empty) ffmpeg
/// output into the renderer.
const PNG_MAGIC: &[u8; 8] = b"\x89PNG\r\n\x1a\n";

/// Extracts a representative frame by invoking `ffmpeg`.
pub struct FfmpegVideoFrameService {
    ffmpeg_path: String,
    /// Bounds concurrent ffmpeg processes — video decode is CPU-heavy and runs
    /// outside the async runtime, so it gets its own (smaller) limit rather than
    /// sharing the image decode semaphore.
    semaphore: Arc<Semaphore>,
    /// Per-extraction wall-clock cap; the child is killed on overrun.
    timeout: Duration,
}

impl FfmpegVideoFrameService {
    pub fn new(ffmpeg_path: String, concurrency: usize, timeout: Duration) -> Self {
        Self {
            ffmpeg_path,
            semaphore: Arc::new(Semaphore::new(concurrency.max(1))),
            timeout,
        }
    }

    /// Best-effort startup probe: true if `<ffmpeg_path> -version` runs and exits
    /// 0. Synchronous so the composition root can decide — register the real
    /// extractor or fall back to [`NoopVideoFrameService`] — without an async
    /// context, and so a misconfigured path is logged once at boot instead of
    /// failing per upload.
    pub fn is_available(ffmpeg_path: &str) -> bool {
        std::process::Command::new(ffmpeg_path)
            .arg("-version")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
    }
}

#[async_trait]
impl VideoFramePort for FfmpegVideoFrameService {
    fn is_supported_video(&self, mime_type: &str) -> bool {
        // ffmpeg is the arbiter of what actually decodes; gate broadly on video/*
        // and let extraction fail gracefully for the rare unsupported container.
        mime_type.starts_with("video/")
    }

    async fn extract_frame(&self, path: &Path) -> Result<Bytes, DomainError> {
        let _permit =
            self.semaphore.acquire().await.map_err(|_| {
                DomainError::internal_error("VideoFrame", "extractor semaphore closed")
            })?;

        // One representative still → PNG on stdout. The `thumbnail` filter scans a
        // window of frames and picks the most representative one (skipping black
        // intros) without needing a separate duration probe. Fit within a
        // 1024×1024 box (preserving aspect) — enough for the 800px `large`
        // thumbnail, and bounding BOTH dimensions caps the emitted PNG size so a
        // hostile/extreme geometry can't balloon the buffered output. Arguments
        // are passed individually (never through a shell), so a hostile file name
        // cannot inject anything.
        let run = Command::new(&self.ffmpeg_path)
            .arg("-nostdin")
            .arg("-loglevel")
            .arg("error")
            .arg("-i")
            .arg(path)
            .arg("-vf")
            .arg("thumbnail,scale=w='min(1024,iw)':h='min(1024,ih)':force_original_aspect_ratio=decrease")
            .arg("-frames:v")
            .arg("1")
            .arg("-f")
            .arg("image2pipe")
            .arg("-vcodec")
            .arg("png")
            .arg("pipe:1")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .output();

        let output = timeout(self.timeout, run)
            .await
            .map_err(|_| DomainError::internal_error("VideoFrame", "ffmpeg timed out"))?
            .map_err(|e| {
                DomainError::internal_error("VideoFrame", format!("ffmpeg spawn failed: {e}"))
            })?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(DomainError::internal_error(
                "VideoFrame",
                format!("ffmpeg exited {}: {}", output.status, stderr.trim()),
            ));
        }

        let png = output.stdout;
        if png.len() < PNG_MAGIC.len() || &png[..PNG_MAGIC.len()] != PNG_MAGIC {
            return Err(DomainError::internal_error(
                "VideoFrame",
                "ffmpeg produced no decodable frame",
            ));
        }
        Ok(Bytes::from(png))
    }
}

/// No-op extractor used when `ffmpeg` is unavailable or video thumbnails are
/// disabled. `is_supported_video` returns false so the lifecycle hook never
/// attempts generation; videos simply have no thumbnail (the prior behaviour).
pub struct NoopVideoFrameService;

#[async_trait]
impl VideoFramePort for NoopVideoFrameService {
    fn is_supported_video(&self, _mime_type: &str) -> bool {
        false
    }

    async fn extract_frame(&self, _path: &Path) -> Result<Bytes, DomainError> {
        Err(DomainError::internal_error(
            "VideoFrame",
            "video thumbnail extraction is disabled (no ffmpeg)",
        ))
    }
}
