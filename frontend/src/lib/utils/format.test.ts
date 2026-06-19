import { describe, expect, it } from 'vitest';
import { formatBytes } from './format';

describe('formatBytes', () => {
	it('formats zero', () => {
		expect(formatBytes(0)).toBe('0 B');
	});

	it('formats bytes without decimals', () => {
		expect(formatBytes(512)).toBe('512 B');
	});

	it('formats kilobytes and megabytes', () => {
		expect(formatBytes(1024)).toBe('1.0 KB');
		expect(formatBytes(1536)).toBe('1.5 KB');
		expect(formatBytes(5 * 1024 * 1024)).toBe('5.0 MB');
	});

	it('handles invalid input', () => {
		expect(formatBytes(-1)).toBe('—');
		expect(formatBytes(NaN)).toBe('—');
	});
});
