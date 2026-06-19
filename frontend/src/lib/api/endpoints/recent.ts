/** Recent endpoints — ported from recentModel.js. */
import { apiFetch } from '$lib/api/client';
import { getCsrfHeaders } from '$lib/api/csrf';
import {
	fetchResourcePage,
	type ResourceBody,
	type ResourcePage,
	type ResourcePageOpts
} from './resources';
import type { ItemType } from '$lib/api/types';

export interface RecentResourceItem {
	resource_type: ItemType;
	accessed_at: string;
	resource: ResourceBody;
}

export function fetchRecentPage(
	opts?: ResourcePageOpts
): Promise<ResourcePage<RecentResourceItem>> {
	return fetchResourcePage<RecentResourceItem>('/api/recent/resources', 'accessed_at', opts);
}

export async function clearRecent(): Promise<void> {
	const res = await apiFetch('/api/recent/clear', {
		method: 'POST',
		credentials: 'same-origin',
		headers: { 'Content-Type': 'application/json', ...getCsrfHeaders() },
		body: '{}'
	});
	if (!res.ok) throw new Error(`clear recent failed: ${res.status}`);
}
