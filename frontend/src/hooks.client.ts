/**
 * Client startup hook. Runs once before the first route renders:
 *  - wires the API client's session-expired behaviour (clear store + redirect),
 *  - loads translations for the resolved locale.
 */
import { setSessionExpiredHandler } from '$lib/api/client';
import { initI18n } from '$lib/i18n/index.svelte';
import { session } from '$lib/stores/session.svelte';

export async function init(): Promise<void> {
	setSessionExpiredHandler(() => {
		session.reset();
		if (typeof window !== 'undefined') {
			window.location.href = '/login?source=session_expired';
		}
	});

	await initI18n();
}
