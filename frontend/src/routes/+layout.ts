// Pure client-rendered SPA: no SSR, no prerendering. The static adapter emits a
// single `index.html` fallback that the Rust web layer serves for every client
// route (including deep links like /s/<token> and /files/<path>).
export const ssr = false;
export const prerender = false;
export const trailingSlash = 'never';
