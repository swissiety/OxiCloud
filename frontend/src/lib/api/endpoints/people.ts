/** People (faces) endpoints — ported from features/library/people.js. */
import { apiFetch } from '$lib/api/client';
import { getCsrfHeaders } from '$lib/api/csrf';

/** An identity cluster from `GET /api/people`. */
export interface Person {
	id: string;
	/** Absent until the user names the person. */
	name?: string;
	/** File id of the cover face's photo, for the tile thumbnail. */
	cover_file_id?: string;
	face_count: number;
	is_hidden: boolean;
}

/**
 * List identity clusters. The feature is gated on `OXICLOUD_ENABLE_FACES` —
 * when it is off the route 404s; callers treat that as "faces disabled".
 */
export async function fetchPeople(): Promise<Person[]> {
	const res = await apiFetch('/api/people', { credentials: 'same-origin' });
	if (!res.ok) throw new Error(`people failed: ${res.status}`);
	return (await res.json()) as Person[];
}

/**
 * Probe whether the People feature is available (faces enabled). Used to reveal
 * the People tab only when the backend can serve it.
 */
export async function peopleEnabled(): Promise<boolean> {
	try {
		const res = await apiFetch('/api/people', { credentials: 'same-origin' });
		return res.ok;
	} catch {
		return false;
	}
}

/** File ids of the photos a person appears in. */
export async function fetchPersonPhotos(personId: string): Promise<string[]> {
	const res = await apiFetch(`/api/people/${personId}/photos`, { credentials: 'same-origin' });
	if (!res.ok) throw new Error(`person photos failed: ${res.status}`);
	return (await res.json()) as string[];
}

/** Rename a person, or pass `null` to clear the name. */
export async function renamePerson(personId: string, name: string | null): Promise<void> {
	const res = await apiFetch(`/api/people/${personId}`, {
		method: 'PATCH',
		credentials: 'same-origin',
		headers: { 'Content-Type': 'application/json', ...getCsrfHeaders() },
		body: JSON.stringify({ name })
	});
	if (!res.ok) throw new Error(`rename failed: ${res.status}`);
}
