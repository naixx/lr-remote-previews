import { describe, expect, it } from 'vitest';
import {
  byteParts,
  formatCount,
  formatLocalTime,
  formatQuantity,
  formatRelative,
  formatTemperature,
  formatTimeLeft,
  plural,
  rateParts,
} from './format';

describe('formatTimeLeft', () => {
  it('stays rough: minutes, then hours and minutes, then days', () => {
    expect(formatTimeLeft(0)).toBe('less than a minute left');
    expect(formatTimeLeft(29)).toBe('less than a minute left');
    expect(formatTimeLeft(104)).toBe('about 2 min left');
    expect(formatTimeLeft(59 * 60)).toBe('about 59 min left');
    expect(formatTimeLeft(3600)).toBe('about 1 h left');
    expect(formatTimeLeft(8100)).toBe('about 2 h 15 min left');
    expect(formatTimeLeft(47 * 3600)).toBe('about 47 h left');
    expect(formatTimeLeft(5 * 86400)).toBe('about 5 days left');
  });
});

describe('formatTemperature and plural', () => {
  it('rounds to whole degrees', () => {
    expect(formatTemperature(67.5)).toBe('68 °C');
    expect(formatTemperature(41.2)).toBe('41 °C');
  });

  it('picks the word for the count and groups digits', () => {
    expect(plural(1, 'file', 'files')).toBe('1 file');
    expect(plural(0, 'file', 'files')).toBe('0 files');
    expect(plural(1384, 'file', 'files')).toBe('1,384 files');
  });
});

describe('formatCount', () => {
  it('groups thousands as the English page does', () => {
    expect(formatCount(0)).toBe('0');
    expect(formatCount(1234)).toBe('1,234');
    expect(formatCount(2890000000)).toBe('2,890,000,000');
  });
});

describe('rateParts', () => {
  it('rounds to whole photos from 10 per minute up', () => {
    expect(rateParts(172.5)).toEqual({ value: '173', unit: 'photos/min' });
    expect(rateParts(12)).toEqual({ value: '12', unit: 'photos/min' });
  });

  it('keeps one decimal for slow rates and says "photo" for exactly one', () => {
    expect(rateParts(0.5)).toEqual({ value: '0.5', unit: 'photos/min' });
    expect(rateParts(1)).toEqual({ value: '1', unit: 'photo/min' });
    expect(rateParts(9.96)).toEqual({ value: '10', unit: 'photos/min' });
  });
});

describe('byteParts', () => {
  it('uses decimal units with one decimal below 100', () => {
    expect(formatQuantity(byteParts(0))).toBe('0 B');
    expect(formatQuantity(byteParts(999))).toBe('999 B');
    expect(formatQuantity(byteParts(1000))).toBe('1.0 kB');
    expect(formatQuantity(byteParts(359310))).toBe('359 kB');
    expect(formatQuantity(byteParts(2890000000))).toBe('2.9 GB');
    expect(formatQuantity(byteParts(3021000000))).toBe('3.0 GB');
    expect(formatQuantity(byteParts(45_600_000_000))).toBe('45.6 GB');
    expect(formatQuantity(byteParts(1.2e15))).toBe('1.2 PB');
  });

  it('moves to the next unit instead of showing 1,000', () => {
    expect(formatQuantity(byteParts(999_960))).toBe('1.0 MB');
  });
});

describe('formatRelative', () => {
  const now = Date.parse('2026-11-14T09:33:00Z');

  it('says how long ago, in the largest whole unit', () => {
    expect(formatRelative('2026-11-14T09:32:30Z', now)).toBe('just now');
    expect(formatRelative('2026-11-14T09:30:00Z', now)).toBe('3 min ago');
    expect(formatRelative('2026-11-14T08:05:00Z', now)).toBe('1 h ago');
    expect(formatRelative('2026-11-13T09:33:00Z', now)).toBe('1 day ago');
    expect(formatRelative('2026-11-10T12:00:00Z', now)).toBe('3 days ago');
  });

  it('treats a time ahead of the clock as just now', () => {
    expect(formatRelative('2026-11-14T09:40:00Z', now)).toBe('just now');
  });
});

describe('formatLocalTime', () => {
  // Built from local dates, so the test holds in any time zone.
  const local = (...parts: [number, number, number, number, number]) => new Date(...parts);
  const now = local(2026, 10, 14, 12, 0).getTime();

  it('shows the year only for another year', () => {
    expect(formatLocalTime(local(2025, 2, 1, 12, 0).toISOString(), now)).toContain('2025');
    expect(formatLocalTime(local(2026, 2, 1, 12, 0).toISOString(), now)).not.toContain('2026');
  });

  it('shows only the time of day for today', () => {
    const created = local(2026, 10, 14, 9, 30);
    const time = new Intl.DateTimeFormat(undefined, { hour: '2-digit', minute: '2-digit' });
    expect(formatLocalTime(created.toISOString(), now)).toBe(time.format(created));
  });
});
