import { describe, expect, it } from 'vitest';
import type { AutoScanSettings, CacheLimits } from '../../api/settings';
import {
  CACHE_MIN_TENTHS,
  cacheChange,
  cacheValuesOf,
  gbText,
  parseGb,
  validateCache,
} from './cacheForm';
import { scanChange, scanValuesOf, validateScan } from './scanForm';

const NO_LIMITS: CacheLimits = { maxBytes: null, maxAgeDays: null };

describe('the size limit in GB', () => {
  it('reads digits with at most one decimal, after a point or a comma', () => {
    expect(parseGb('50')).toBe(50_000_000_000);
    expect(parseGb(' 12.5 ')).toBe(12_500_000_000);
    expect(parseGb('12,5')).toBe(12_500_000_000);
    expect(parseGb('0.2')).toBe(200_000_000);
    for (const text of ['', '12.55', '1,500', '-1', '1e3', '12.', '.5', 'ten']) {
      expect(parseGb(text)).toBeNull();
    }
  });

  it('shows a saved limit rounded to a tenth of a GB', () => {
    expect(gbText(50_000_000_000)).toBe('50');
    expect(gbText(53_687_091_200)).toBe('53.7');
    expect(gbText(104_857_600)).toBe('0.1');
    expect(CACHE_MIN_TENTHS).toBe(2);
  });
});

describe('validateCache and cacheChange', () => {
  it('takes empty fields as no limit', () => {
    const values = { size: '', age: '' };
    expect(validateCache(NO_LIMITS, values)).toEqual({});
    expect(cacheChange(NO_LIMITS, values)).toBeNull();
    const saved = { maxBytes: 50_000_000_000, maxAgeDays: 90 };
    expect(cacheChange(saved, values)).toEqual(NO_LIMITS);
  });

  it('refuses a size below 100 MiB, more than one decimal and days out of range', () => {
    expect(validateCache(NO_LIMITS, { size: '0.1', age: '' }).size).toContain('0.2 GB');
    expect(validateCache(NO_LIMITS, { size: '12.55', age: '' }).size).toContain('such as 50 or 12.5');
    expect(validateCache(NO_LIMITS, { size: '', age: '0' }).age).toContain('from 1 to 3,650');
    expect(validateCache(NO_LIMITS, { size: '', age: '3651' }).age).toBeDefined();
    expect(validateCache(NO_LIMITS, { size: '', age: '1.5' }).age).toBeDefined();
  });

  it('sends a saved limit back to the byte while its text is unchanged', () => {
    // 100 MiB shows as 0.1 GB, which could not be entered, but is the server's own value.
    const saved = { maxBytes: 104_857_600, maxAgeDays: 30 };
    const values = { ...cacheValuesOf(saved), age: '60' };
    expect(validateCache(saved, values)).toEqual({});
    expect(cacheChange(saved, values)).toEqual({ maxBytes: 104_857_600, maxAgeDays: 60 });
  });

  it('sends the whole object when either limit changed', () => {
    expect(cacheChange(NO_LIMITS, { size: '12,5', age: '' })).toEqual({
      maxBytes: 12_500_000_000,
      maxAgeDays: null,
    });
  });
});

const SCAN: AutoScanSettings = {
  enabled: false,
  roots: ['archive', 'offsite'],
  intervalMinutes: 60,
  settleMinutes: 15,
  maxFilesPerRun: 2000,
};

describe('validateScan and scanChange', () => {
  it('finds no change for the saved values, whatever the order of the roots', () => {
    const values = scanValuesOf(SCAN);
    expect(validateScan(values)).toEqual({});
    expect(scanChange(SCAN, { ...values, roots: ['offsite', 'archive'] })).toBeNull();
  });

  it('sends the whole object when anything changed', () => {
    const values = { ...scanValuesOf(SCAN), enabled: true, roots: ['archive'], maxFiles: '50000' };
    expect(scanChange(SCAN, values)).toEqual({
      ...SCAN,
      enabled: true,
      roots: ['archive'],
      maxFilesPerRun: 50000,
    });
  });

  it('applies the ranges of the protocol and wants a root while the scan is on', () => {
    const values = scanValuesOf(SCAN);
    expect(validateScan({ ...values, interval: '4' }).interval).toContain('from 5 to 1,440');
    expect(validateScan({ ...values, interval: '1441' }).interval).toBeDefined();
    expect(validateScan({ ...values, settle: '0' })).toEqual({});
    expect(validateScan({ ...values, settle: '-1' }).settle).toContain('from 0 to 1,440');
    expect(validateScan({ ...values, maxFiles: '0' }).maxFiles).toContain('from 1 to 50,000');
    expect(validateScan({ ...values, maxFiles: '50001' }).maxFiles).toBeDefined();
    expect(validateScan({ ...values, enabled: true, roots: [] }).roots).toContain('at least one root');
    expect(validateScan({ ...values, enabled: false, roots: [] })).toEqual({});
  });
});
