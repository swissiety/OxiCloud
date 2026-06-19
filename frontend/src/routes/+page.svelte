<script lang="ts">
	import { goto } from '$app/navigation';
	import { onMount } from 'svelte';

	// The app root redirects to the primary files view.
	onMount(() => {
		void goto('/files', { replaceState: true });
	});
</script>

<p>Loading…</p>
