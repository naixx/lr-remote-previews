import { describe, expect, it } from 'vitest';
import { sampleCacheClean } from '../test/fixtures';
import { parseAutoScanStarted } from './autoscan';
import { parseCacheClean, removedTotal } from './cache';
import { ShapeError } from './validate';

function shapeErrorOf(parse: (data: unknown) => unknown, data: unknown): ShapeError {
  try {
    parse(data);
  } catch (error) {
    if (error instanceof ShapeError) return error;
    throw error;
  }
  throw new Error('Expected a ShapeError.');
}

describe('parseCacheClean', () => {
  it('accepts the contract example and keeps only known fields', () => {
    const body = sampleCacheClean({ dryRun: false });
    expect(parseCacheClean({ ...body, took: 1.5 })).toEqual(body);
  });

  it('counts every removed DNG', () => {
    const result = parseCacheClean(
      sampleCacheClean({ removed: { originalGone: 12, expired: 30, overLimit: 4 } }),
    );
    expect(removedTotal(result)).toBe(46);
    expect(removedTotal(parseCacheClean(sampleCacheClean({ removed: { originalGone: 0 } })))).toBe(0);
  });

  it('names the field that is wrong', () => {
    expect(shapeErrorOf(parseCacheClean, { ...sampleCacheClean(), dryRun: 'yes' }).path).toBe(
      'dryRun',
    );
    expect(
      shapeErrorOf(parseCacheClean, sampleCacheClean({ removed: { expired: -1 } })).path,
    ).toBe('removed.expired');
    expect(shapeErrorOf(parseCacheClean, { dryRun: true, bytesFreed: 0 }).path).toBe('removed');
    expect(shapeErrorOf(parseCacheClean, { ...sampleCacheClean(), bytesFreed: 1.5 }).path).toBe(
      'bytesFreed',
    );
  });
});

describe('parseAutoScanStarted', () => {
  it('accepts the contract example and names a wrong field', () => {
    expect(parseAutoScanStarted({ started: true, extra: 1 })).toEqual({ started: true });
    expect(shapeErrorOf(parseAutoScanStarted, { started: 'yes' }).path).toBe('started');
  });
});
