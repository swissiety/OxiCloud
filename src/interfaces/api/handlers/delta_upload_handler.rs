//! Delta-upload protocol endpoints — "upload only what changed".
//!
//! Wire surface of [`DeltaUploadService`]; see that module (and
//! `docs/delta-upload-protocol.md`) for the protocol and its security
//! model. These handlers only authenticate, rate-limit and translate
//! the wire formats — every decision lives in the application service.
//!
//! Chunk-frame wire format (`PUT /api/files/delta/chunks`): the body is a
//! sequence of `[u32 big-endian length][length bytes]` frames, one per
//! chunk, with `Content-Type: application/octet-stream`. Frames are capped
//! at the CDC maximum chunk size (1 MiB) and the whole request at the same
//! per-request ceiling as resumable chunk PUTs (`chunk_max_bytes`).

use axum::{
    Json,
    body::Body,
    extract::State,
    http::StatusCode,
    response::{IntoResponse, Response},
};
use bytes::{Buf, Bytes, BytesMut};
use futures::Stream;
use std::sync::Arc;
use tokio_stream::StreamExt;

use crate::application::services::delta_upload_service::{
    DeltaChunksResponse, DeltaCommitOutcome, DeltaCommitRequest, DeltaNegotiateRequest,
    DeltaNegotiateResponse,
};
use crate::common::di::AppState;
use crate::common::errors::DomainError;
use crate::infrastructure::services::dedup_service::CDC_MAX_CHUNK;
use crate::interfaces::errors::AppError;
use crate::interfaces::middleware::auth::AuthUser;
use http_body_util::BodyStream;
use serde::Serialize;
use utoipa::ToSchema;

/// 409 body of `POST /api/files/delta/commit` when chunks vanished between
/// negotiate and commit (GC race) or were never claimable: the client
/// uploads exactly these hashes and retries the same commit.
#[derive(Debug, Serialize, ToSchema)]
pub struct DeltaStillMissingResponse {
    pub still_missing: Vec<String>,
}

/// Per-caller flood guard shared by the three delta endpoints.
fn check_rate_limit(state: &Arc<AppState>, auth_user: &AuthUser) -> Result<(), AppError> {
    if state
        .delta_upload_rate_limiter
        .check_and_increment(&auth_user.id.to_string())
        .is_err()
    {
        tracing::info!(
            target: "audit",
            event = "delta_upload.rejected",
            reason = "rate_limited",
            caller_id = %auth_user.id,
            "👮🏻‍♂️ Delta upload rejected: per-caller rate limit exceeded",
        );
        return Err(AppError::new(
            StatusCode::TOO_MANY_REQUESTS,
            "Too many delta-upload requests; please retry shortly",
            "RateLimited",
        ));
    }
    Ok(())
}

/// Parse a `[u32 BE length][bytes]` frame sequence from the request body.
///
/// Streaming: peak RAM is one frame (≤ 1 MiB) plus one HTTP frame,
/// regardless of how many chunks the request carries. `max_total` bounds
/// the whole request body.
fn parse_chunk_frames(
    body: Body,
    max_total: usize,
) -> impl Stream<Item = Result<Bytes, DomainError>> + Send {
    async_stream::try_stream! {
        let mut body_stream = BodyStream::new(body);
        let mut buf = BytesMut::new();
        let mut expecting: Option<usize> = None;
        let mut total: usize = 0;

        loop {
            // Drain every complete frame already buffered.
            loop {
                match expecting {
                    None => {
                        if buf.len() < 4 {
                            break;
                        }
                        let len =
                            u32::from_be_bytes([buf[0], buf[1], buf[2], buf[3]]) as usize;
                        buf.advance(4);
                        if len == 0 || len > CDC_MAX_CHUNK {
                            Err(DomainError::validation_error(format!(
                                "Chunk frame of {len} bytes out of bounds (1 ..= {CDC_MAX_CHUNK})"
                            )))?;
                        }
                        expecting = Some(len);
                    }
                    Some(len) => {
                        if buf.len() < len {
                            break;
                        }
                        let frame = buf.split_to(len).freeze();
                        expecting = None;
                        yield frame;
                    }
                }
            }

            match body_stream.next().await {
                Some(Ok(http_frame)) => {
                    if let Some(data) = http_frame.data_ref() {
                        total += data.len();
                        if total > max_total {
                            Err(DomainError::validation_error(format!(
                                "Request body exceeds the {max_total}-byte per-request cap; \
                                 split the chunk upload into several requests"
                            )))?;
                        }
                        buf.extend_from_slice(data);
                    }
                }
                Some(Err(e)) => {
                    Err(DomainError::validation_error(format!(
                        "Failed to read request body: {e}"
                    )))?;
                }
                None => {
                    if expecting.is_some() || !buf.is_empty() {
                        Err(DomainError::validation_error(
                            "Truncated chunk frame at end of body",
                        ))?;
                    }
                    break;
                }
            }
        }
    }
}

#[utoipa::path(
    post,
    path = "/api/files/delta/negotiate",
    request_body = DeltaNegotiateRequest,
    responses(
        (status = 200, description = "Chunks the caller must upload (the rest are claimable without bytes)", body = DeltaNegotiateResponse),
        (status = 400, description = "Malformed chunk list (hash format, size bounds, count ceiling)"),
        (status = 429, description = "Rate limited"),
    ),
    security(("bearerAuth" = [])),
    tag = "delta-upload"
)]
pub async fn delta_negotiate(
    State(state): State<Arc<AppState>>,
    auth_user: AuthUser,
    Json(request): Json<DeltaNegotiateRequest>,
) -> Result<impl IntoResponse, AppError> {
    check_rate_limit(&state, &auth_user)?;
    let response = state
        .applications
        .delta_upload_service
        .negotiate_with_perms(auth_user.id, &request)
        .await
        .map_err(AppError::from)?;
    Ok(Json(response))
}

#[utoipa::path(
    put,
    path = "/api/files/delta/chunks",
    request_body(content_type = "application/octet-stream",
        description = "Sequence of [u32 BE length][bytes] frames, one per chunk (each ≤ 1 MiB)"),
    responses(
        (status = 200, description = "Server-computed identity of every received frame, in order", body = DeltaChunksResponse),
        (status = 400, description = "Malformed framing, oversized frame, or oversized request"),
        (status = 429, description = "Rate limited"),
    ),
    security(("bearerAuth" = [])),
    tag = "delta-upload"
)]
pub async fn delta_upload_chunks(
    State(state): State<Arc<AppState>>,
    auth_user: AuthUser,
    body: Body,
) -> Result<impl IntoResponse, AppError> {
    check_rate_limit(&state, &auth_user)?;
    let frames = parse_chunk_frames(body, state.core.config.storage.chunk_max_bytes);
    let response = state
        .applications
        .delta_upload_service
        .receive_chunks(frames)
        .await
        .map_err(AppError::from)?;
    Ok(Json(response))
}

#[utoipa::path(
    post,
    path = "/api/files/delta/commit",
    request_body = DeltaCommitRequest,
    responses(
        (status = 201, description = "File created from the committed chunk sequence", body = crate::application::dtos::file_dto::FileDto),
        (status = 200, description = "Existing file's content replaced", body = crate::application::dtos::file_dto::FileDto),
        (status = 400, description = "Malformed request, or the declared file_hash does not match the chunk sequence"),
        (status = 404, description = "Target folder/file not found or not accessible"),
        (status = 409, description = "Chunks not claimable — upload them and retry", body = DeltaStillMissingResponse),
        (status = 429, description = "Rate limited"),
        (status = 507, description = "Storage quota exceeded"),
    ),
    security(("bearerAuth" = [])),
    tag = "delta-upload"
)]
pub async fn delta_commit(
    State(state): State<Arc<AppState>>,
    auth_user: AuthUser,
    Json(request): Json<DeltaCommitRequest>,
) -> Result<Response, AppError> {
    check_rate_limit(&state, &auth_user)?;
    let outcome = state
        .applications
        .delta_upload_service
        .commit_with_perms(auth_user.id, request)
        .await
        .map_err(AppError::from)?;
    Ok(match outcome {
        DeltaCommitOutcome::Done { file, created } => {
            let status = if created {
                StatusCode::CREATED
            } else {
                StatusCode::OK
            };
            (status, Json(file)).into_response()
        }
        DeltaCommitOutcome::StillMissing(still_missing) => (
            StatusCode::CONFLICT,
            Json(DeltaStillMissingResponse { still_missing }),
        )
            .into_response(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Encode frames the way a client would.
    fn encode(frames: &[&[u8]]) -> Vec<u8> {
        let mut out = Vec::new();
        for f in frames {
            out.extend_from_slice(&(f.len() as u32).to_be_bytes());
            out.extend_from_slice(f);
        }
        out
    }

    async fn collect(body: Body, max_total: usize) -> Result<Vec<Bytes>, DomainError> {
        let stream = parse_chunk_frames(body, max_total);
        futures::pin_mut!(stream);
        let mut out = Vec::new();
        while let Some(item) = stream.next().await {
            out.push(item?);
        }
        Ok(out)
    }

    #[tokio::test]
    async fn roundtrips_frames_in_order() {
        let wire = encode(&[b"first", b"second chunk", &[0xAB; 1000]]);
        let frames = collect(Body::from(wire), usize::MAX).await.unwrap();
        assert_eq!(frames.len(), 3);
        assert_eq!(&frames[0][..], b"first");
        assert_eq!(&frames[1][..], b"second chunk");
        assert_eq!(frames[2].len(), 1000);
    }

    #[tokio::test]
    async fn empty_body_yields_no_frames() {
        let frames = collect(Body::empty(), usize::MAX).await.unwrap();
        assert!(frames.is_empty());
    }

    #[tokio::test]
    async fn rejects_zero_length_frame() {
        let wire = encode(&[b""]);
        assert!(collect(Body::from(wire), usize::MAX).await.is_err());
    }

    #[tokio::test]
    async fn rejects_frame_above_cdc_max() {
        let mut wire = Vec::new();
        wire.extend_from_slice(&((CDC_MAX_CHUNK as u32) + 1).to_be_bytes());
        // Header alone is enough — the length is rejected before any data.
        assert!(collect(Body::from(wire), usize::MAX).await.is_err());
    }

    #[tokio::test]
    async fn rejects_truncated_frame() {
        let mut wire = encode(&[b"complete"]);
        wire.extend_from_slice(&10u32.to_be_bytes());
        wire.extend_from_slice(b"only5"); // promises 10, delivers 5
        assert!(collect(Body::from(wire), usize::MAX).await.is_err());
    }

    #[tokio::test]
    async fn rejects_request_above_total_cap() {
        let wire = encode(&[&[0u8; 600], &[1u8; 600]]);
        assert!(collect(Body::from(wire), 1000).await.is_err());
    }

    #[tokio::test]
    async fn accepts_frame_exactly_at_cdc_max() {
        let big = vec![7u8; CDC_MAX_CHUNK];
        let wire = encode(&[&big]);
        let frames = collect(Body::from(wire), usize::MAX).await.unwrap();
        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0].len(), CDC_MAX_CHUNK);
    }
}
