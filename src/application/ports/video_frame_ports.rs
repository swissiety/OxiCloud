//! Video frame extraction port.
//!
//! Pulls a single representative still frame out of a video so the existing
//! image thumbnail pipeline (shrink-on-load → SIMD resize → WebP → blob-hash
//! storage → HTTP content negotiation) can treat videos exactly like photos —
//! eagerly, server-side, on upload. Keeping this behind a port lets the
//! composition root swap in a no-op when `ffmpeg` is absent or the feature is
//! off, so video uploads degrade gracefully (no thumbnail) instead of erroring.

use crate::common::errors::DomainError;
use async_trait::async_trait;
use bytes::Bytes;
use std::path::Path;

/// Extracts a representative still frame from a video file.
///
/// Implementations:
/// - `FfmpegVideoFrameService` — shells out to the system `ffmpeg`, covering
///   every container/codec (incl. HEVC/MOV, which a browser `<video>` cannot
///   decode). Bounds its own process concurrency and per-call timeout.
/// - `NoopVideoFrameService` — registered when `ffmpeg` is unavailable or the
///   feature is disabled; `is_supported_video` returns false so the lifecycle
///   hook never attempts video thumbnails.
#[async_trait]
pub trait VideoFramePort: Send + Sync + 'static {
    /// Whether `mime_type` is a video this extractor will attempt to thumbnail.
    /// The no-op implementation always returns false.
    fn is_supported_video(&self, mime_type: &str) -> bool;

    /// Extract one representative frame from the video file at `path`, returning
    /// encoded **PNG** bytes ready to feed into the image thumbnail renderer.
    /// `path` must point at the decoded (decrypted, reassembled) video on disk.
    async fn extract_frame(&self, path: &Path) -> Result<Bytes, DomainError>;
}
