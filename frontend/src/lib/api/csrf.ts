/**
 * CSRF double-submit cookie utility — ported from static/js/core/csrf.js.
 *
 * Reads the `oxicloud_csrf` cookie (NOT HttpOnly) and exposes its value as the
 * `X-CSRF-Token` header. The server's `csrf_middleware` validates that the
 * header matches the cookie for every mutating (POST/PUT/DELETE/PATCH) request
 * authenticated via the HttpOnly session cookie.
 */

export function getCsrfToken(): string {
	const match = document.cookie.split('; ').find((row) => row.startsWith('oxicloud_csrf='));
	return match ? (match.split('=')[1] ?? '') : '';
}

/** Headers to merge into a mutating request; empty when no token is present. */
export function getCsrfHeaders(): Record<string, string> {
	const token = getCsrfToken();
	return token ? { 'X-CSRF-Token': token } : {};
}
