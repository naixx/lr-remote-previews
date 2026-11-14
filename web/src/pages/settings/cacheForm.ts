import {
  CACHE_AGE_MAX,
  CACHE_AGE_MIN,
  CACHE_MIN_BYTES,
  type CacheLimits,
} from '../../api/settings';
import { formatCount } from '../../lib/format';
import { wholeNumber } from './form';

/**
 * The size limit is entered in GB with at most one decimal. GB are decimal, 1,000,000,000 bytes,
 * as every size on the dashboard is shown.
 */
const BYTES_PER_TENTH_GB = 100_000_000;

/** The smallest size limit that can be entered: the server's 100 MiB, rounded up to 0.2 GB. */
export const CACHE_MIN_TENTHS = Math.ceil(CACHE_MIN_BYTES / BYTES_PER_TENTH_GB);

/** The cache limits as typed; empty text means no limit. */
export interface CacheValues {
  /** GB, with at most one decimal. */
  size: string;
  /** Whole days. */
  age: string;
}

export interface CacheErrors {
  size?: string;
  age?: string;
}

/** `53687091200` → `"53.7"`, `50000000000` → `"50"`. */
export function gbText(bytes: number): string {
  return String(Math.round(bytes / BYTES_PER_TENTH_GB) / 10);
}

/**
 * Bytes from a size in GB written with digits and at most one decimal, after a point or a
 * comma (`12.5`, `12,5`); null for anything else. One decimal only, so `1,500` is not read as
 * fifteen hundred.
 */
export function parseGb(text: string): number | null {
  const match = /^(\d{1,6})(?:[.,](\d))?$/.exec(text.trim());
  if (!match) return null;
  const tenths = Number(match[1]) * 10 + Number(match[2] ?? '0');
  return tenths * BYTES_PER_TENTH_GB;
}

export function cacheValuesOf(limits: CacheLimits): CacheValues {
  return {
    size: limits.maxBytes === null ? '' : gbText(limits.maxBytes),
    age: limits.maxAgeDays === null ? '' : String(limits.maxAgeDays),
  };
}

/**
 * True while the size is the text the form started with: the saved limit is then sent back to
 * the byte, even when it is not a whole tenth of a GB (or below 0.2 GB, set on the server).
 */
function sizeUnchanged(initial: CacheLimits, values: CacheValues): boolean {
  return values.size.trim() === cacheValuesOf(initial).size;
}

/** The server's rules, so most mistakes are caught before sending. */
export function validateCache(initial: CacheLimits, values: CacheValues): CacheErrors {
  const errors: CacheErrors = {};
  const size = values.size.trim();
  if (size !== '' && !sizeUnchanged(initial, values)) {
    const bytes = parseGb(size);
    if (bytes === null) {
      errors.size = 'Enter a size in GB such as 50 or 12.5, or leave it empty for no limit.';
    } else if (bytes < CACHE_MIN_BYTES) {
      errors.size = `The smallest size limit is ${CACHE_MIN_TENTHS / 10} GB; leave it empty for no limit.`;
    }
  }
  const age = values.age.trim();
  if (age !== '') {
    const days = wholeNumber(age, 4);
    if (days === null || days < CACHE_AGE_MIN || days > CACHE_AGE_MAX) {
      errors.age = `Enter a whole number of days from ${CACHE_AGE_MIN} to ${formatCount(CACHE_AGE_MAX)}, or leave it empty for no limit.`;
    }
  }
  return errors;
}

/**
 * The whole `cache` object to send when the form differs from the saved limits, or null when
 * nothing changed. Call only when `validateCache` found nothing.
 */
export function cacheChange(initial: CacheLimits, values: CacheValues): CacheLimits | null {
  const size = values.size.trim();
  const age = values.age.trim();
  const next: CacheLimits = {
    maxBytes: sizeUnchanged(initial, values) ? initial.maxBytes : size === '' ? null : parseGb(size),
    maxAgeDays: age === '' ? null : wholeNumber(age, 4),
  };
  return next.maxBytes === initial.maxBytes && next.maxAgeDays === initial.maxAgeDays ? null : next;
}
