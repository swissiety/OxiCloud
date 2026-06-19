import { describe, expect, it } from 'vitest';
import { getNestedValue, interpolate, resolveBrowserLocale } from './index.svelte';

describe('resolveBrowserLocale', () => {
	it('matches an exact full tag', () => {
		expect(resolveBrowserLocale(['zh-TW'])).toBe('zh-TW');
		expect(resolveBrowserLocale(['fr-FR', 'fr'])).toBe('fr');
	});

	it('maps Traditional Chinese variants to zh-TW', () => {
		expect(resolveBrowserLocale(['zh-Hant'])).toBe('zh-TW');
		expect(resolveBrowserLocale(['zh-HK'])).toBe('zh-TW');
		expect(resolveBrowserLocale(['zh-MO'])).toBe('zh-TW');
	});

	it('maps Simplified/other Chinese to zh', () => {
		expect(resolveBrowserLocale(['zh-CN'])).toBe('zh');
		expect(resolveBrowserLocale(['zh'])).toBe('zh');
	});

	it('falls back to the primary subtag', () => {
		expect(resolveBrowserLocale(['de-AT'])).toBe('de');
	});

	it('defaults to en when nothing matches', () => {
		expect(resolveBrowserLocale(['xx-YY'])).toBe('en');
	});
});

describe('getNestedValue', () => {
	const dict = {
		'flat.key': 'flat value',
		nav: { files: 'Files', shared: 'Shared' },
		button: { save_changes: 'Save changes' }
	};

	it('resolves a direct key that contains dots', () => {
		expect(getNestedValue(dict, 'flat.key')).toBe('flat value');
	});

	it('resolves dotted nested paths', () => {
		expect(getNestedValue(dict, 'nav.files')).toBe('Files');
	});

	it('returns null for missing keys', () => {
		expect(getNestedValue(dict, 'nav.missing')).toBeNull();
		expect(getNestedValue(undefined, 'nav.files')).toBeNull();
	});

	it('applies the prefix_suffix underscore fallback', () => {
		expect(getNestedValue(dict, 'button_save_changes')).toBe('Save changes');
	});
});

describe('interpolate', () => {
	it('replaces {{param}} placeholders', () => {
		expect(interpolate('Hello {{name}}', { name: 'Ada' })).toBe('Hello Ada');
	});

	it('trims whitespace inside placeholders', () => {
		expect(interpolate('Send to {{ email }}', { email: 'a@b.c' })).toBe('Send to a@b.c');
	});

	it('leaves unknown placeholders intact', () => {
		expect(interpolate('Hi {{name}}', {})).toBe('Hi {{name}}');
	});

	it('coerces non-string params', () => {
		expect(interpolate('{{count}} items', { count: 5 })).toBe('5 items');
	});
});
