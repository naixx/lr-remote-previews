import {
  asArray,
  asBoolean,
  asClockTime,
  asCount,
  asObject,
  asString,
  fieldPath,
  nullable,
  optional,
  ShapeError,
} from './validate';

/** `"auto"` or a whole number of converter processes, 1 to 32, never 2. */
export type WorkersSetting = 'auto' | number;

export interface WorkingHours {
  /** When true, waves start only between `from` and `to`. */
  enabled: boolean;
  /** Local time of the server, `HH:MM`. `from` later than `to` is a window across midnight. */
  from: string;
  to: string;
}

/** The automatic scan: which roots the server walks, how often, and how much it queues. */
export interface AutoScanSettings {
  /** Off unless set. Scan now works either way. */
  enabled: boolean;
  /** Ids of the roots to scan; each must exist on the server. */
  roots: string[];
  /** Minutes between two scans, 5 to 1440. */
  intervalMinutes: number;
  /** A file modified more recently than this many minutes is left for a later scan, 0 to 1440. */
  settleMinutes: number;
  /** The most files one scan queues, 1 to 50000; the rest wait for the next scan. */
  maxFilesPerRun: number;
}

/** Limits for the cache clean-up; null means no limit. */
export interface CacheLimits {
  /** Null, or at least 104857600 bytes (100 MiB). */
  maxBytes: number | null;
  /** Null, or 1 to 3650 days since a DNG was last used. */
  maxAgeDays: number | null;
}

/** Response of `GET` and `PATCH /api/v1/settings`. */
export interface ServerSettings {
  workers: WorkersSetting;
  /** What `workers` comes to on the server's machine. Read-only. */
  effectiveWorkers: number;
  /** Files per converter process in one wave, 1 to 64. */
  batchSize: number;
  /** When true no new wave starts; a wave that is running finishes. */
  paused: boolean;
  workingHours: WorkingHours;
  /** Null from a server older than 0.5, which has no automatic scan. */
  autoScan: AutoScanSettings | null;
  /** Null from a server older than 0.5, which has no cache clean-up. */
  cache: CacheLimits | null;
}

/**
 * The body of `PATCH /api/v1/settings`: any subset; `workingHours`, `autoScan` and `cache` only
 * as whole objects.
 */
export interface SettingsChange {
  workers?: WorkersSetting;
  batchSize?: number;
  paused?: boolean;
  workingHours?: WorkingHours;
  autoScan?: AutoScanSettings;
  cache?: CacheLimits;
}

/** Limits of the settings, as the protocol states them. */
export const WORKERS_MIN = 1;
export const WORKERS_MAX = 32;
/** Two converter processes side by side waste CPU time, so the server refuses exactly 2. */
export const WORKERS_FORBIDDEN = 2;
export const BATCH_MIN = 1;
export const BATCH_MAX = 64;
export const SCAN_INTERVAL_MIN = 5;
export const SCAN_INTERVAL_MAX = 1440;
export const SCAN_SETTLE_MIN = 0;
export const SCAN_SETTLE_MAX = 1440;
export const SCAN_FILES_MIN = 1;
export const SCAN_FILES_MAX = 50_000;
/** The smallest size limit the server accepts: 100 MiB. */
export const CACHE_MIN_BYTES = 104_857_600;
export const CACHE_AGE_MIN = 1;
export const CACHE_AGE_MAX = 3650;

function parseWorkers(value: unknown, path: string): WorkersSetting {
  if (value === 'auto') return 'auto';
  if (typeof value === 'number' && Number.isInteger(value) && value >= 1) return value;
  throw new ShapeError(path, '"auto" or a whole number of 1 or more', value);
}

function parseWorkingHours(value: unknown, path: string): WorkingHours {
  const obj = asObject(value, path);
  return {
    enabled: asBoolean(obj.enabled, `${path}.enabled`),
    from: asClockTime(obj.from, `${path}.from`),
    to: asClockTime(obj.to, `${path}.to`),
  };
}

function parseAutoScan(value: unknown, path: string): AutoScanSettings {
  const obj = asObject(value, path);
  return {
    enabled: asBoolean(obj.enabled, fieldPath(path, 'enabled')),
    roots: asArray(obj.roots, fieldPath(path, 'roots'), asString),
    intervalMinutes: asCount(obj.intervalMinutes, fieldPath(path, 'intervalMinutes')),
    settleMinutes: asCount(obj.settleMinutes, fieldPath(path, 'settleMinutes')),
    maxFilesPerRun: asCount(obj.maxFilesPerRun, fieldPath(path, 'maxFilesPerRun')),
  };
}

function parseCacheLimits(value: unknown, path: string): CacheLimits {
  const obj = asObject(value, path);
  return {
    maxBytes: nullable(obj.maxBytes, fieldPath(path, 'maxBytes'), asCount),
    maxAgeDays: nullable(obj.maxAgeDays, fieldPath(path, 'maxAgeDays'), asCount),
  };
}

/** Checks the shape of a settings response; throws a ShapeError naming the first bad field. */
export function parseSettings(data: unknown): ServerSettings {
  const obj = asObject(data, '');
  return {
    workers: parseWorkers(obj.workers, 'workers'),
    effectiveWorkers: asCount(obj.effectiveWorkers, 'effectiveWorkers'),
    batchSize: asCount(obj.batchSize, 'batchSize'),
    paused: asBoolean(obj.paused, 'paused'),
    workingHours: parseWorkingHours(obj.workingHours, 'workingHours'),
    autoScan: optional(obj.autoScan, 'autoScan', parseAutoScan),
    cache: optional(obj.cache, 'cache', parseCacheLimits),
  };
}
