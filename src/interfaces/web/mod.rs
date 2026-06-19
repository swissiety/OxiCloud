use crate::common::config::AppConfig;
use crate::common::di::AppState;
use axum::Router;
use axum::http::header::{CACHE_CONTROL, HeaderValue};
use axum::routing::get_service;
use std::path::Path;
use std::sync::Arc;
use tower_http::compression::CompressionLayer;
use tower_http::services::{ServeDir, ServeFile};
use tower_http::set_header::SetResponseHeaderLayer;

/// Serves the SvelteKit single-page app.
///
/// The frontend is built by Vite into `static-dist/` (repo root). Real files are
/// served from disk; any unmatched client route (deep links such as
/// `/files/<id>`, `/s/<token>`, `/login`) falls back to the SPA shell
/// `index.html`, which boots the client router.
///
/// Caching: content-hashed assets under `/_app/immutable` are cached forever;
/// everything else — crucially the `index.html` shell — is `no-cache` so a deploy
/// can't leave a stale app pinned in browsers.
pub fn create_web_routes() -> Router<Arc<AppState>> {
    let config = AppConfig::from_env();

    // `PROFILE=dev` (the `just front-dev`/legacy path) serves the unbuilt source
    // dir; normal release serves the Vite output in `static-dist/`.
    let is_dev = std::env::var("PROFILE").is_ok_and(|profile| profile == "dev");
    let assets_dir = if is_dev { "static" } else { "static-dist" };

    let static_path = if cfg!(not(debug_assertions)) {
        let dist = config
            .static_path
            .parent()
            .unwrap_or(Path::new("."))
            .join(assets_dir);
        if dist.exists() {
            dist
        } else {
            config.static_path.clone()
        }
    } else {
        config.static_path.clone()
    };

    // SPA fallback: serve the file if it exists, else the app shell.
    let spa = ServeDir::new(&static_path).fallback(ServeFile::new(static_path.join("index.html")));

    // Hashed, immutable assets (SvelteKit emits these under /_app/immutable).
    let app_immutable = ServeDir::new(static_path.join("_app").join("immutable"));

    let shell_cache = if is_dev {
        "max-age=0, no-cache, no-store"
    } else {
        "no-cache"
    };

    Router::new()
        .nest_service(
            "/_app/immutable",
            get_service(app_immutable).layer(SetResponseHeaderLayer::overriding(
                CACHE_CONTROL,
                HeaderValue::from_static("public, max-age=31536000, immutable"),
            )),
        )
        .fallback_service(spa)
        .layer(CompressionLayer::new().br(true).gzip(true))
        // `if_not_present` so the immutable assets above keep their long cache.
        .layer(SetResponseHeaderLayer::if_not_present(
            CACHE_CONTROL,
            HeaderValue::from_static(shell_cache),
        ))
}
