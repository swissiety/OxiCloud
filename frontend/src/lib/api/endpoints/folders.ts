/** Folder endpoints — ported from filesModel.js + fileOperations.js. */
import { apiFetch, apiJson } from '$lib/api/client';
import { getCsrfHeaders } from '$lib/api/csrf';
import type { FileItem, FolderItem } from '$lib/api/types';

const JSON_HEADERS = { 'Content-Type': 'application/json' };
const NO_CACHE: RequestInit = {
	credentials: 'same-origin',
	cache: 'no-store',
	headers: { 'Cache-Control': 'no-cache, no-store, must-revalidate' }
};

export interface FolderListing {
	folders: FolderItem[];
	files: FileItem[];
}

/** Top-level folders for the user; the first entry is the home folder. */
export function listRootFolders(): Promise<FolderItem[]> {
	return apiJson<FolderItem[]>('/api/folders', { credentials: 'same-origin' });
}

export function getFolder(id: string): Promise<FolderItem> {
	return apiJson<FolderItem>(`/api/folders/${id}`, NO_CACHE);
}

export async function listFolder(folderId: string, forceRefresh = false): Promise<FolderListing> {
	const ts = Math.floor(Date.now() / 1000);
	let url = `/api/folders/${folderId}/listing?t=${ts}`;
	const headers: Record<string, string> = {
		'Cache-Control': 'no-cache, no-store, must-revalidate'
	};
	if (forceRefresh) {
		url += '&force_refresh=true';
		headers['X-Force-Refresh'] = 'true';
	}
	const res = await apiFetch(url, { credentials: 'same-origin', cache: 'no-store', headers });
	if (res.status === 403) throw Object.assign(new Error('Forbidden'), { status: 403 });
	if (!res.ok) throw new Error(`listing failed: ${res.status}`);
	const listing = (await res.json()) as Partial<FolderListing>;
	return {
		folders: Array.isArray(listing.folders) ? listing.folders : [],
		files: Array.isArray(listing.files) ? listing.files : []
	};
}

export async function createFolder(name: string, parentId: string | null): Promise<FolderItem> {
	const res = await apiFetch('/api/folders', {
		method: 'POST',
		credentials: 'same-origin',
		headers: { ...JSON_HEADERS, ...getCsrfHeaders() },
		body: JSON.stringify({ name, parent_id: parentId })
	});
	if (!res.ok) throw new Error(`create folder failed: ${res.status}`);
	return (await res.json()) as FolderItem;
}

export async function renameFolder(folderId: string, name: string): Promise<void> {
	const res = await apiFetch(`/api/folders/${folderId}/rename`, {
		method: 'PUT',
		credentials: 'same-origin',
		headers: { ...JSON_HEADERS, ...getCsrfHeaders() },
		body: JSON.stringify({ name })
	});
	if (!res.ok) throw new Error(`rename folder failed: ${res.status}`);
}

export async function moveFolder(folderId: string, targetFolderId: string | null): Promise<void> {
	const res = await apiFetch(`/api/folders/${folderId}/move`, {
		method: 'PUT',
		credentials: 'same-origin',
		headers: { ...JSON_HEADERS, ...getCsrfHeaders() },
		body: JSON.stringify({ parent_id: targetFolderId || null })
	});
	if (!res.ok) throw new Error(`move folder failed: ${res.status}`);
}

export async function deleteFolder(folderId: string): Promise<void> {
	const res = await apiFetch(`/api/folders/${folderId}`, {
		method: 'DELETE',
		credentials: 'same-origin',
		headers: getCsrfHeaders()
	});
	if (!res.ok) throw new Error(`delete folder failed: ${res.status}`);
}

export function folderZipUrl(folderId: string): string {
	return `/api/folders/${folderId}/download?format=zip`;
}
