//! Keep reading a request body nobody wanted, so that the client gets the answer.
//!
//! DAV handlers answer without reading the body when they already know the outcome: `401` from the
//! auth layer, `409` from a `PUT` into a missing collection, `412` from a failed precondition. The
//! HTTP connection then stops reading while the client is still sending, and closes. Depending on
//! timing the client's next write fails or the reset discards the response, so a client built on
//! `hyper` (`reqwest`, for one) intermittently reports `Broken pipe` or `connection closed before
//! message completed` instead of the status, and cannot react to it, for example by creating the
//! missing collection.
//!
//! RFC 9112 §9.6 describes the remedy, a lingering close: go on reading for a while after the
//! response. Here, a body dropped before its end is handed to a background task that reads and
//! discards it. As long as that task holds the body, the connection keeps reading and the response
//! goes out at once. Bytes and time are bounded, so nobody can make the server read forever, and
//! beyond the bounds a connection behaves as it did without this layer.

use std::pin::Pin;
use std::task::{Context, Poll};
use std::time::Duration;

use axum::body::{Body, Bytes};
use axum::extract::Request;
use axum::middleware::Next;
use axum::response::Response;
use http_body::{Body as HttpBody, Frame, SizeHint};
use http_body_util::BodyExt;

/// Most clients stop sending as soon as they see the response, so this is rarely reached.
const MAX_LINGER_BYTES: u64 = 64 * 1024 * 1024;
const MAX_LINGER_TIME: Duration = Duration::from_secs(30);

/// Layer for routes that may answer without reading the request body.
/// Place it outside the auth layers, as they answer early too.
pub async fn lingering_body_middleware(request: Request, next: Next) -> Response {
    let (parts, body) = request.into_parts();
    let body = Body::new(LingeringBody {
        inner: Some(body),
        finished: false,
        max_bytes: MAX_LINGER_BYTES,
        max_time: MAX_LINGER_TIME,
    });
    next.run(Request::from_parts(parts, body)).await
}

struct LingeringBody {
    /// `Some` until dropped.
    inner: Option<Body>,
    finished: bool,
    max_bytes: u64,
    max_time: Duration,
}

impl HttpBody for LingeringBody {
    type Data = Bytes;
    type Error = axum::Error;

    fn poll_frame(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Bytes>, axum::Error>>> {
        let this = self.get_mut();
        let Some(inner) = this.inner.as_mut() else {
            return Poll::Ready(None);
        };
        let polled = Pin::new(inner).poll_frame(cx);
        if matches!(polled, Poll::Ready(None | Some(Err(_)))) {
            this.finished = true;
        }
        polled
    }

    fn is_end_stream(&self) -> bool {
        self.inner.as_ref().is_none_or(HttpBody::is_end_stream)
    }

    fn size_hint(&self) -> SizeHint {
        self.inner
            .as_ref()
            .map_or_else(|| SizeHint::with_exact(0), HttpBody::size_hint)
    }
}

impl Drop for LingeringBody {
    fn drop(&mut self) {
        let Some(body) = self.inner.take() else {
            return;
        };
        if self.finished || body.is_end_stream() {
            return;
        }
        // No runtime means shutdown: nothing to wait for.
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            let (max_bytes, max_time) = (self.max_bytes, self.max_time);
            runtime.spawn(drain(body, max_bytes, max_time));
        }
    }
}

/// Read and discard until the end of `body`, an error or a limit. Returns the bytes read.
async fn drain(mut body: Body, max_bytes: u64, max_time: Duration) -> u64 {
    let mut read = 0u64;
    let reading = async {
        while read < max_bytes {
            match body.frame().await {
                Some(Ok(frame)) => {
                    read += frame.data_ref().map_or(0, |d| d.len() as u64);
                }
                Some(Err(_)) | None => break,
            }
        }
    };
    let _ = tokio::time::timeout(max_time, reading).await;
    read
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::Router;
    use axum::http::StatusCode;
    use axum::routing::put;
    use futures::{StreamExt, stream};
    use std::convert::Infallible;

    /// Answers without reading the body, like `PUT` into a missing collection does.
    async fn refuse() -> StatusCode {
        StatusCode::CONFLICT
    }

    async fn read_all(body: Bytes) -> String {
        body.len().to_string()
    }

    async fn serve(app: Router) -> String {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        url
    }

    /// `(answers with the status, requests that failed)`, as seen by `hyper`'s client.
    async fn refused_uploads(url: &str, requests: usize) -> (usize, usize) {
        let client = reqwest::Client::new();
        let body = Bytes::from(vec![1u8; 2_400_000]);
        let (mut answered, mut failed) = (0, 0);
        for i in 0..requests {
            match client
                .put(format!("{url}/{i}"))
                .body(body.clone())
                .send()
                .await
            {
                Ok(res) => {
                    assert_eq!(res.status(), StatusCode::CONFLICT);
                    answered += 1;
                }
                Err(_) => failed += 1,
            }
        }
        (answered, failed)
    }

    // client and server need threads of their own: taking turns on one thread, they never race
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn the_client_gets_the_answer_to_a_request_whose_body_nobody_read() {
        let app = Router::new()
            .route("/{i}", put(refuse))
            .layer(axum::middleware::from_fn(lingering_body_middleware));
        let url = serve(app).await;
        let (answered, failed) = refused_uploads(&url, 200).await;
        assert_eq!((answered, failed), (200, 0));
    }

    #[tokio::test]
    async fn a_handler_that_reads_the_body_is_not_affected() {
        let app = Router::new()
            .route("/{i}", put(read_all))
            .layer(axum::middleware::from_fn(lingering_body_middleware));
        let url = serve(app).await;
        let client = reqwest::Client::new();
        for _ in 0..3 {
            let res = client
                .put(format!("{url}/1"))
                .body(vec![1u8; 100_000])
                .send()
                .await
                .unwrap();
            assert_eq!(
                res.text().await.unwrap(),
                "100000",
                "the connection is reused"
            );
        }
    }

    #[tokio::test]
    async fn draining_stops_at_the_byte_limit() {
        let chunks = stream::repeat_with(|| Ok::<_, Infallible>(Bytes::from(vec![0u8; 1024])));
        let read = drain(Body::from_stream(chunks), 10 * 1024, MAX_LINGER_TIME).await;
        assert_eq!(read, 10 * 1024);
    }

    #[tokio::test]
    async fn draining_stops_at_the_time_limit() {
        let first = stream::once(async { Ok::<_, Infallible>(Bytes::from_static(b"abc")) });
        let stalled = first.chain(stream::pending());
        let started = std::time::Instant::now();
        let read = drain(
            Body::from_stream(stalled),
            MAX_LINGER_BYTES,
            Duration::from_millis(50),
        )
        .await;
        assert_eq!(read, 3);
        assert!(started.elapsed() < MAX_LINGER_TIME);
    }

    #[tokio::test]
    async fn only_a_body_left_unfinished_is_drained() {
        let (tx, mut rx) = tokio::sync::oneshot::channel::<()>();
        // holds `tx` until the stream itself is dropped, so `rx` tells when reading ended
        let held = stream::unfold(Some(tx), |tx| async move {
            let _keep = tx;
            std::future::pending::<Option<(Result<Bytes, Infallible>, _)>>().await
        });
        let unfinished = LingeringBody {
            inner: Some(Body::from_stream(held)),
            finished: false,
            max_bytes: MAX_LINGER_BYTES,
            max_time: Duration::from_millis(200),
        };
        drop(unfinished);
        assert_eq!(
            rx.try_recv(),
            Err(tokio::sync::oneshot::error::TryRecvError::Empty),
            "the task reading it holds the body after the drop"
        );
        assert!(
            tokio::time::timeout(Duration::from_secs(5), rx)
                .await
                .is_ok(),
            "the task ends at its limit"
        );

        let empty = LingeringBody {
            inner: Some(Body::empty()),
            finished: false,
            max_bytes: MAX_LINGER_BYTES,
            max_time: MAX_LINGER_TIME,
        };
        assert!(empty.is_end_stream());
        drop(empty);
    }
}
