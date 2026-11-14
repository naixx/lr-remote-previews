import {
  asBoolean,
  asClockTime,
  asCount,
  asObject,
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
}

/** The body of `PATCH /api/v1/settings`: any subset; `workingHours` only as a whole. */
export interface SettingsChange {
  workers?: WorkersSetting;
  batchSize?: number;
  paused?: boolean;
  workingHours?: WorkingHours;
}

/** Limits of the settings, as the protocol states them. */
export const WORKERS_MIN = 1;
export const WORKERS_MAX = 32;
/** Two converter processes side by side waste CPU time, so the server refuses exactly 2. */
export const WORKERS_FORBIDDEN = 2;
export const BATCH_MIN = 1;
export const BATCH_MAX = 64;

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

/** Checks the shape of a settings response; throws a ShapeError naming the first bad field. */
export function parseSettings(data: unknown): ServerSettings {
  const obj = asObject(data, '');
  return {
    workers: parseWorkers(obj.workers, 'workers'),
    effectiveWorkers: asCount(obj.effectiveWorkers, 'effectiveWorkers'),
    batchSize: asCount(obj.batchSize, 'batchSize'),
    paused: asBoolean(obj.paused, 'paused'),
    workingHours: parseWorkingHours(obj.workingHours, 'workingHours'),
  };
}
