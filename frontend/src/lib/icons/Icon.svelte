<script lang="ts">
	import { OxiIcons, type IconName } from './registry';

	interface Props {
		/** FA5-style icon name (without the `fa-` prefix), e.g. "folder". */
		name: IconName | string;
		/** Accessible label; when omitted the icon is decorative (aria-hidden). */
		title?: string;
		/** Extra classes forwarded to the <svg>. */
		class?: string;
	}

	let { name, title, class: className = '' }: Props = $props();

	const entry = $derived(OxiIcons[name as IconName]);
	const width = $derived(entry?.[0] ?? 512);
	const path = $derived(entry?.[1] ?? '');
</script>

{#if entry}
	<svg
		class={`oxi-icon ${className}`}
		viewBox={`0 0 ${width} 512`}
		fill="currentColor"
		role={title ? 'img' : undefined}
		aria-hidden={title ? undefined : 'true'}
		aria-label={title}
	>
		{#if title}<title>{title}</title>{/if}
		<path d={path} />
	</svg>
{/if}

<style>
	.oxi-icon {
		display: inline-block;
		width: 1em;
		height: 1em;
		vertical-align: -0.125em;
	}
</style>
