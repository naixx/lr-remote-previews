import { asBoolean, asCount, asObject, fieldPath } from './validate';

/** How many DNGs a clean-up removed, or would remove, for each of its reasons. */
export interface CacheRemoved {
  /** The original is gone or has changed (another size or modification time). */
  originalGone: number;
  /** Not used for `cache.maxAgeDays` days. */
  expired: number;
  /** The least recently used, removed until the cache fits `cache.maxBytes`. */
  overLimit: number;
}

/** Response of `POST /api/v1/cache/clean`. */
export interface CacheCleanResult {
  /** True when nothing was removed, only counted. */
  dryRun: boolean;
  removed: CacheRemoved;
  bytesFreed: number;
}

/** Checks the answer to a clean-up; throws a ShapeError naming the first bad field. */
export function parseCacheClean(data: unknown): CacheCleanResult {
  const obj = asObject(data, '');
  const removed = asObject(obj.removed, 'removed');
  const count = (key: keyof CacheRemoved) => asCount(removed[key], fieldPath('removed', key));
  return {
    dryRun: asBoolean(obj.dryRun, 'dryRun'),
    removed: {
      originalGone: count('originalGone'),
      expired: count('expired'),
      overLimit: count('overLimit'),
    },
    bytesFreed: asCount(obj.bytesFreed, 'bytesFreed'),
  };
}

/** Every DNG the clean-up removed or would remove. */
export function removedTotal(result: CacheCleanResult): number {
  const { originalGone, expired, overLimit } = result.removed;
  return originalGone + expired + overLimit;
}
