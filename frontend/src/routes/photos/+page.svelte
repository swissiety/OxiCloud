<script lang="ts">
	import Button from '$lib/components/Button.svelte';
	import EmptyState from '$lib/components/EmptyState.svelte';
	import PeopleView from '$lib/components/PeopleView.svelte';
	import PhotoLightbox from '$lib/components/PhotoLightbox.svelte';
	import PlacesMap from '$lib/components/PlacesMap.svelte';
	import { useSelection } from '$lib/composables/useSelection.svelte';
	import { errorToast } from '$lib/utils/errors';
	import { onMount } from 'svelte';
	import {
		batchTrash,
		fetchPhotos,
		uploadThumbnail,
		type PhotoItem
	} from '$lib/api/endpoints/photos';
	import { peopleEnabled } from '$lib/api/endpoints/people';
	import { fileDownloadUrl, fileThumbnailUrl } from '$lib/api/endpoints/files';
	import Icon from '$lib/icons/Icon.svelte';
	import { confirmDialog } from '$lib/stores/dialogs.svelte';
	import { t } from '$lib/i18n/index.svelte';
	import { ui } from '$lib/stores/ui.svelte';
	import { isVideo, photoTimestamp } from '$lib/utils/media';

	type Tab = 'moments' | 'places' | 'people';
	let tab = $state<Tab>('moments');
	let peopleAvailable = $state(false);

	let items = $state<PhotoItem[]>([]);
	let cursor = $state<string | null>(null);
	let exhausted = $state(false);
	let loading = $state(false);
	let error = $state<string | null>(null);
	let sentinel = $state<HTMLElement | null>(null);
	/** Usable content width of the grid, for the justified layout. */
	let gridWidth = $state(0);

	type GroupMode = 'day' | 'month' | 'year';
	type LayoutMode = 'square' | 'justified';
	const GROUP_KEY = 'oxicloud-photos-group';
	const LAYOUT_KEY = 'oxicloud-photos-layout';
	let groupMode = $state<GroupMode>('month');
	let layoutMode = $state<LayoutMode>('square');
	const selected = useSelection();
	let lightbox = $state(-1); // index into `items`, -1 = closed

	/** Client-generated video frame thumbnails (file id → data/URL). */
	let videoThumbs = $state<Record<string, string>>({});

	/** EXIF-aware timestamp (seconds → ms), matching the OLD grouping logic. */
	function bucketKey(d: Date): string {
		const y = d.getFullYear();
		if (groupMode === 'year') return `${y}`;
		const m = `${d.getMonth() + 1}`.padStart(2, '0');
		if (groupMode === 'month') return `${y}-${m}`;
		return `${y}-${m}-${`${d.getDate()}`.padStart(2, '0')}`;
	}

	function bucketLabel(d: Date): string {
		if (groupMode === 'year') return `${d.getFullYear()}`;
		if (groupMode === 'month')
			return d.toLocaleDateString(undefined, { year: 'numeric', month: 'long' });
		return d.toLocaleDateString(undefined, {
			weekday: 'long',
			year: 'numeric',
			month: 'long',
			day: 'numeric'
		});
	}

	const groups = $derived.by(() => {
		const out: Array<{ key: string; label: string; photos: PhotoItem[] }> = [];
		const index = new Map<string, number>();
		for (const p of items) {
			const d = new Date(photoTimestamp(p));
			const key = bucketKey(d);
			let i = index.get(key);
			if (i === undefined) {
				i = out.length;
				index.set(key, i);
				out.push({ key, label: bucketLabel(d), photos: [] });
			}
			out[i].photos.push(p);
		}
		return out;
	});

	interface JustifiedTile {
		file: PhotoItem;
		w: number;
		h: number;
	}

	/**
	 * Pack files into justified rows (Flickr-style): each full row is scaled to
	 * fill `width` while preserving every tile's aspect ratio. Missing dimensions
	 * fall back to 1:1.
	 */
	function justifiedRows(
		files: PhotoItem[],
		width: number
	): Array<{ height: number; tiles: JustifiedTile[] }> {
		const gap = 8;
		const target = window.matchMedia('(max-width: 768px)').matches ? 150 : 200;
		const rows: Array<{ height: number; tiles: JustifiedTile[] }> = [];
		let cur: Array<{ file: PhotoItem; aspect: number }> = [];
		let aspectSum = 0;
		for (const file of files) {
			let aspect = file.width && file.height ? file.width / file.height : 1;
			if (!Number.isFinite(aspect) || aspect <= 0) aspect = 1;
			aspect = Math.min(Math.max(aspect, 0.4), 3);
			cur.push({ file, aspect });
			aspectSum += aspect;
			const rowWidth = aspectSum * target + (cur.length - 1) * gap;
			if (rowWidth >= width) {
				const h = (width - (cur.length - 1) * gap) / aspectSum;
				rows.push({
					height: Math.round(h),
					tiles: cur.map((tt) => ({
						file: tt.file,
						w: Math.max(1, Math.round(tt.aspect * h)),
						h: Math.round(h)
					}))
				});
				cur = [];
				aspectSum = 0;
			}
		}
		if (cur.length) {
			rows.push({
				height: target,
				tiles: cur.map((tt) => ({
					file: tt.file,
					w: Math.max(1, Math.round(tt.aspect * target)),
					h: target
				}))
			});
		}
		return rows;
	}

	async function loadMore() {
		if (loading || exhausted) return;
		loading = true;
		error = null;
		try {
			const page = await fetchPhotos(60, cursor);
			items = [...items, ...page.items];
			cursor = page.nextCursor;
			if (!page.nextCursor) exhausted = true;
		} catch (e) {
			error = e instanceof Error ? e.message : String(e);
			exhausted = true;
		} finally {
			loading = false;
		}
	}

	function setGroupMode(m: GroupMode) {
		if (groupMode === m) return;
		groupMode = m;
		if (typeof localStorage !== 'undefined') localStorage.setItem(GROUP_KEY, m);
	}

	function setLayoutMode(m: LayoutMode) {
		if (layoutMode === m) return;
		layoutMode = m;
		if (typeof localStorage !== 'undefined') localStorage.setItem(LAYOUT_KEY, m);
	}

	/** A plain tile click toggles selection once anything is selected, else opens the lightbox. */
	function onTileClick(p: PhotoItem) {
		if (selected.size > 0) selected.toggle(p.id);
		else lightbox = items.findIndex((x) => x.id === p.id);
	}

	function onDeletePhoto(id: string) {
		items = items.filter((p) => p.id !== id);
		selected.delete(id);
	}

	function downloadSelected() {
		for (const id of selected.ids) {
			const a = document.createElement('a');
			a.href = fileDownloadUrl(id);
			a.download = '';
			document.body.appendChild(a);
			a.click();
			a.remove();
		}
	}

	async function trashSelected() {
		const ids = selected.values();
		const ok = await confirmDialog({
			title: t('photos.delete', 'Delete photos'),
			message: t('photos.confirm_delete', { n: ids.length }, 'Move {{n}} photos to trash?'),
			confirmText: t('common.delete', 'Delete'),
			danger: true
		});
		if (!ok) return;
		try {
			const trashed = await batchTrash(ids);
			if (trashed.size > 0) {
				items = items.filter((p) => !trashed.has(p.id));
				for (const id of trashed) selected.delete(id);
			}
			if (trashed.size < ids.length) {
				ui.notify(
					t(
						'photos.trash_partial',
						{ ok: trashed.size, total: ids.length },
						'{{ok}} of {{total}} moved to trash.'
					),
					'warning'
				);
			} else {
				ui.notify(t('photos.trashed', { n: trashed.size }, '{{n}} moved to trash.'), 'success');
			}
		} catch (e) {
			errorToast(e);
		}
	}

	// ── Client-side video thumbnail generation ──────────────────────────────
	// When the server has no thumbnail for a video tile the <img> errors; we
	// then extract a frame with the browser's native decoder and upload it.

	async function generateVideoThumb(file: PhotoItem) {
		if (videoThumbs[file.id]) return;
		try {
			const bitmap = await frameFromVideo(`/api/files/${file.id}?inline=true`);
			const SIZES: Array<['icon' | 'preview' | 'large', number, number]> = [
				['icon', 150, 150],
				['preview', 400, 400],
				['large', 800, 800]
			];
			let previewData = '';
			for (const [size, w, h] of SIZES) {
				const blob = await bitmapToBlob(bitmap, w, h);
				if (size === 'preview') previewData = await blobToDataUrl(blob);
				await uploadThumbnail(file.id, size, blob).catch(() => {});
			}
			if (previewData) videoThumbs = { ...videoThumbs, [file.id]: previewData };
		} catch {
			// Keep the generic play badge on failure.
		}
	}

	function frameFromVideo(src: string): Promise<ImageBitmap> {
		return new Promise((resolve, reject) => {
			const video = document.createElement('video');
			video.src = src;
			video.muted = true;
			video.preload = 'metadata';
			video.onloadedmetadata = () => {
				video.currentTime = (video.duration || 3) / 3;
			};
			video.onseeked = async () => {
				try {
					const bitmap = await createImageBitmap(video);
					video.removeAttribute('src');
					video.load();
					resolve(bitmap);
				} catch (e) {
					reject(e instanceof Error ? e : new Error(String(e)));
				}
			};
			video.onerror = () => reject(new Error('video frame extraction failed'));
		});
	}

	async function bitmapToBlob(bitmap: ImageBitmap, tw: number, th: number): Promise<Blob> {
		const ratio = bitmap.width / bitmap.height;
		const target = tw / th;
		const w = ratio > target ? tw : Math.round(th * ratio);
		const h = ratio > target ? Math.round(tw / ratio) : th;
		const canvas = document.createElement('canvas');
		canvas.width = w;
		canvas.height = h;
		canvas.getContext('2d')?.drawImage(bitmap, 0, 0, w, h);
		return new Promise<Blob>((resolve, reject) => {
			canvas.toBlob(
				(b) => (b ? resolve(b) : reject(new Error('canvas toBlob failed'))),
				'image/jpeg',
				0.8
			);
		});
	}

	function blobToDataUrl(blob: Blob): Promise<string> {
		return new Promise((resolve, reject) => {
			const reader = new FileReader();
			reader.onload = () => resolve(String(reader.result));
			reader.onerror = () => reject(new Error('blob read failed'));
			reader.readAsDataURL(blob);
		});
	}

	onMount(() => {
		const savedGroup = typeof localStorage !== 'undefined' ? localStorage.getItem(GROUP_KEY) : null;
		if (savedGroup === 'day' || savedGroup === 'month' || savedGroup === 'year')
			groupMode = savedGroup;
		const savedLayout =
			typeof localStorage !== 'undefined' ? localStorage.getItem(LAYOUT_KEY) : null;
		if (savedLayout === 'square' || savedLayout === 'justified') layoutMode = savedLayout;
		void loadMore();
		void peopleEnabled().then((ok) => (peopleAvailable = ok));
		if (!sentinel) return;
		const obs = new IntersectionObserver(
			(entries) => {
				if (entries.some((e) => e.isIntersecting)) void loadMore();
			},
			{ rootMargin: '600px' }
		);
		obs.observe(sentinel);
		return () => obs.disconnect();
	});

	const MODES: GroupMode[] = ['day', 'month', 'year'];
</script>

<svelte:head><title>{t('nav.photos', 'Photos')} · OxiCloud</title></svelte:head>

<div class="page-sticky-header photos-head">
	<h1 class="page-title">{t('nav.photos', 'Photos')}</h1>
	<div class="photos-subnav" role="tablist" aria-label={t('nav.photos', 'Photos')}>
		<button
			class="subnav__tab"
			class:active={tab === 'moments'}
			role="tab"
			aria-selected={tab === 'moments'}
			onclick={() => (tab = 'moments')}
		>
			{t('photos.tab_moments', 'Moments')}
		</button>
		<button
			class="subnav__tab"
			class:active={tab === 'places'}
			role="tab"
			aria-selected={tab === 'places'}
			onclick={() => (tab = 'places')}
		>
			{t('photos.tab_places', 'Places')}
		</button>
		{#if peopleAvailable}
			<button
				class="subnav__tab"
				class:active={tab === 'people'}
				role="tab"
				aria-selected={tab === 'people'}
				onclick={() => (tab = 'people')}
			>
				{t('photos.tab_people', 'People')}
			</button>
		{/if}
	</div>
</div>

{#if tab === 'moments'}
	<div class="photos-toolbar">
		<div class="seg" role="group" aria-label={t('photos.group_by', 'Group by')}>
			{#each MODES as m (m)}
				<button class="seg__btn" class:active={groupMode === m} onclick={() => setGroupMode(m)}>
					{t(`photos.${m}`, m)}
				</button>
			{/each}
		</div>
		<div class="seg" role="group" aria-label={t('photos.layout_square', 'Layout')}>
			<button
				class="seg__btn"
				class:active={layoutMode === 'square'}
				title={t('photos.layout_square', 'Grid')}
				aria-label={t('photos.layout_square', 'Grid')}
				onclick={() => setLayoutMode('square')}><Icon name="th" /></button
			>
			<button
				class="seg__btn"
				class:active={layoutMode === 'justified'}
				title={t('photos.layout_justified', 'Justified')}
				aria-label={t('photos.layout_justified', 'Justified')}
				onclick={() => setLayoutMode('justified')}><Icon name="layer-group" /></button
			>
		</div>
	</div>

	{#if selected.size > 0}
		<div class="batch-bar">
			<span>{t('files.selected_count', { n: selected.size }, '{{n}} selected')}</span>
			<div class="batch-bar__actions">
				<Button onclick={downloadSelected}>{t('common.download', 'Download')}</Button>
				<Button onclick={() => selected.clear()}>{t('common.clear', 'Clear')}</Button>
				<Button variant="danger" onclick={trashSelected}>{t('common.delete', 'Delete')}</Button>
			</div>
		</div>
	{/if}

	{#if error}
		<p class="status status--error" role="alert">{error}</p>
	{:else if items.length === 0 && exhausted}
		<EmptyState
			icon="images"
			title={t('photos.empty', 'No photos yet.')}
			hint={t(
				'photos.empty_hint',
				'Photos and videos you upload will appear here, grouped by date.'
			)}
		/>
	{:else}
		<div class="photos-area">
			<div class="photos-measure" bind:clientWidth={gridWidth}>
				{#each groups as group (group.key)}
					<h2 class="photos-group">
						{group.label} <span class="photos-group__count">{group.photos.length}</span>
					</h2>
					{#if layoutMode === 'justified' && gridWidth > 0}
						{#each justifiedRows(group.photos, gridWidth) as row, ri (group.key + '-' + ri)}
							<div class="photos-jrow" style:height="{row.height}px">
								{#each row.tiles as cell (cell.file.id)}
									{@render tile(cell.file, `width:${cell.w}px;height:${cell.h}px`)}
								{/each}
							</div>
						{/each}
					{:else}
						<ul class="photos">
							{#each group.photos as photo (photo.id)}
								<li
									class="photos__cell photos__cell--square"
									class:selected={selected.has(photo.id)}
								>
									{@render tile(photo)}
								</li>
							{/each}
						</ul>
					{/if}
				{/each}
			</div>
		</div>
	{/if}

	<div bind:this={sentinel} class="sentinel" aria-hidden="true"></div>
	{#if loading}<p class="status">{t('common.loading', 'Loading…')}</p>{/if}

	<PhotoLightbox {items} bind:index={lightbox} onDelete={onDeletePhoto} />
{:else if tab === 'places'}
	<PlacesMap />
{:else if tab === 'people'}
	<PeopleView />
{/if}

{#snippet tile(photo: PhotoItem, sizeStyle?: string)}
	<div class="photo-tile" class:selected={selected.has(photo.id)} style={sizeStyle}>
		<button class="photo-tile__open" onclick={() => onTileClick(photo)}>
			{#if videoThumbs[photo.id]}
				<img src={videoThumbs[photo.id]} alt={photo.name} loading="lazy" decoding="async" />
			{:else}
				<img
					src={fileThumbnailUrl(photo.id, 'preview')}
					srcset={`${fileThumbnailUrl(photo.id, 'icon')} 150w, ${fileThumbnailUrl(photo.id, 'preview')} 400w, ${fileThumbnailUrl(photo.id, 'large')} 800w`}
					sizes="(max-width: 768px) 33vw, 200px"
					alt={photo.name}
					loading="lazy"
					decoding="async"
					onerror={isVideo(photo) ? () => generateVideoThumb(photo) : undefined}
				/>
			{/if}
			{#if isVideo(photo)}
				<span class="photo-tile__video-badge" aria-hidden="true"><Icon name="play" /></span>
			{/if}
		</button>
		<button
			class="photo-tile__check"
			class:on={selected.has(photo.id)}
			aria-label={t('common.select', 'Select')}
			onclick={() => selected.toggle(photo.id)}
		>
			<Icon name="check" />
		</button>
	</div>
{/snippet}

<style>
	.photos-head {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: var(--space-3);
		flex-wrap: wrap;
		padding: 1rem 1rem 0;
	}

	.page-title {
		margin: 0;
		font-size: 1.5rem;
		color: var(--color-text-heading);
	}

	.photos-subnav {
		display: flex;
		gap: var(--space-1);
	}

	.subnav__tab {
		padding: var(--space-2) var(--space-3);
		border: none;
		border-bottom: 2px solid transparent;
		background: none;
		color: var(--color-text-muted);
		cursor: pointer;
		font-size: var(--text-base);
	}

	.subnav__tab.active {
		color: var(--color-accent);
		border-bottom-color: var(--color-accent);
	}

	.photos-toolbar {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: var(--space-3);
		padding: var(--space-3) 1rem 0;
	}

	.seg {
		display: flex;
		border: 1px solid var(--color-border);
		border-radius: var(--radius-md);
		overflow: hidden;
	}

	.seg__btn {
		display: grid;
		place-items: center;
		padding: var(--space-2) var(--space-3);
		border: none;
		background: var(--color-bg-surface);
		color: var(--color-text-muted);
		cursor: pointer;
		text-transform: capitalize;
	}

	.seg__btn.active {
		background: var(--color-accent);
		color: var(--color-on-accent);
	}

	.batch-bar {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: var(--space-3);
		margin: var(--space-3) 1rem 0;
		padding: var(--space-2) var(--space-3);
		background: var(--color-accent-tint, var(--color-bg-hover));
		border: 1px solid var(--color-border);
		border-radius: var(--radius-md);
	}

	.batch-bar__actions {
		display: flex;
		gap: var(--space-2);
	}

	.photos-area {
		padding: 0 1rem;
	}

	.photos-group {
		margin: var(--space-4) 0 var(--space-2);
		font-size: 1rem;
		color: var(--color-text-heading);
	}

	.photos-group__count {
		color: var(--color-text-muted);
		font-size: var(--text-sm);
		font-weight: var(--weight-normal);
	}

	.photos {
		list-style: none;
		margin: 0;
		padding: 0;
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(9rem, 1fr));
		gap: 0.25rem;
	}

	/* Justified rows: a flex row of aspect-preserving tiles. */
	.photos-jrow {
		display: flex;
		gap: 8px;
		margin-bottom: 8px;
	}

	.photo-tile {
		position: relative;
		overflow: hidden;
		border-radius: var(--radius-sm);
		background: var(--color-bg-muted);
	}

	.photos__cell--square,
	.photos__cell--square .photo-tile {
		aspect-ratio: 1;
		height: 100%;
	}

	.photos__cell--square {
		list-style: none;
	}

	.photo-tile.selected {
		outline: 3px solid var(--color-accent);
		outline-offset: -3px;
	}

	.photo-tile__open {
		display: block;
		width: 100%;
		height: 100%;
		border: none;
		padding: 0;
		cursor: pointer;
		background: none;
	}

	.photo-tile__open img {
		width: 100%;
		height: 100%;
		object-fit: cover;
		display: block;
	}

	.photo-tile__video-badge {
		position: absolute;
		right: 6px;
		bottom: 6px;
		width: 26px;
		height: 26px;
		border-radius: 50%;
		background: var(--color-scrim-control);
		color: var(--color-on-accent);
		display: grid;
		place-items: center;
		font-size: 0.7rem;
		pointer-events: none;
	}

	.photo-tile__check {
		position: absolute;
		top: 6px;
		left: 6px;
		width: 24px;
		height: 24px;
		border-radius: 50%;
		border: 2px solid var(--color-on-accent);
		background: var(--color-scrim-control);
		color: transparent;
		display: grid;
		place-items: center;
		cursor: pointer;
		opacity: 0;
		transition: opacity 0.15s;
	}

	.photo-tile:hover .photo-tile__check,
	.photo-tile__check.on {
		opacity: 1;
	}

	.photo-tile__check.on {
		background: var(--color-accent);
		color: var(--color-on-accent);
		border-color: var(--color-accent);
	}

	.status {
		text-align: center;
		color: var(--color-text-muted);
		padding: 2rem 0;
	}

	.status--error {
		color: var(--color-danger-text);
	}

	.sentinel {
		height: 1px;
	}
</style>
