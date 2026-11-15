import {
  asBoolean,
  asCount,
  asNonNegative,
  asNullableTimestamp,
  asNumber,
  asObject,
  asOneOf,
  fieldPath,
  nullable,
  optional,
} from './validate';

export const SERVER_STATES = ['running', 'idle', 'paused', 'waiting'] as const;
/**
 * `running`: building, or about to; `idle`: nothing queued; `paused`: the `paused` setting is
 * on; `waiting`: work is queued but the working hours have not begun.
 */
export type ServerState = (typeof SERVER_STATES)[number];

/** What the automatic scan is doing, as the status reports it. */
export interface AutoScanStatus {
  /** True while a scan walks the roots, automatic or started with Scan now. */
  running: boolean;
  /** When the last scan finished; null before the first. */
  lastRun: string | null;
  /** How many files the last scan queued; 0 before the first. */
  lastQueued: number;
  /** When the next automatic scan is due; null while the automatic scan is off. */
  nextRun: string | null;
}

/** Response of `GET /api/v1/status`: the server's work at this moment. */
export interface ServerStatus {
  /** What the server is doing; null from a server older than 0.4 that does not send it. */
  state: ServerState | null;
  /** Items over all jobs. */
  queue: {
    /** Waiting for a converter process. */
    queued: number;
    /** Given to a converter process. */
    building: number;
  };
  workers: {
    /** Converter processes the server may run side by side. */
    configured: number;
    /** Converter processes running now. */
    busy: number;
  };
  rate: {
    /** Items built in the last `windowSeconds`, scaled to a minute; 0 when idle. */
    perMinute: number;
    windowSeconds: number;
  };
  /**
   * Estimated seconds until the queue is empty at the current rate; null when there is nothing
   * to estimate, and from an older server.
   */
  etaSeconds: number | null;
  /** Since local midnight of the server. */
  today: {
    built: number;
    failed: number;
  };
  /** The DNGs the server keeps. */
  cache: {
    entries: number;
    bytes: number;
  };
  jobs: {
    active: number;
  };
  /** Degrees Celsius of the hottest CPU sensor; null when unreadable, and from an older server. */
  cpuTemperature: number | null;
  /** Null from a server older than 0.5, which has no automatic scan. */
  autoScan: AutoScanStatus | null;
}

function parseAutoScanStatus(value: unknown, path: string): AutoScanStatus {
  const obj = asObject(value, path);
  return {
    running: asBoolean(obj.running, fieldPath(path, 'running')),
    lastRun: asNullableTimestamp(obj.lastRun, fieldPath(path, 'lastRun')),
    lastQueued: asCount(obj.lastQueued, fieldPath(path, 'lastQueued')),
    nextRun: asNullableTimestamp(obj.nextRun, fieldPath(path, 'nextRun')),
  };
}

/** Checks the shape of a status response; throws a ShapeError naming the first bad field. */
export function parseServerStatus(data: unknown): ServerStatus {
  const obj = asObject(data, '');
  const queue = asObject(obj.queue, 'queue');
  const workers = asObject(obj.workers, 'workers');
  const rate = asObject(obj.rate, 'rate');
  const today = asObject(obj.today, 'today');
  const cache = asObject(obj.cache, 'cache');
  const jobs = asObject(obj.jobs, 'jobs');

  return {
    state: optional(obj.state, 'state', (value, path) => asOneOf(value, path, SERVER_STATES)),
    queue: {
      queued: asCount(queue.queued, 'queue.queued'),
      building: asCount(queue.building, 'queue.building'),
    },
    workers: {
      configured: asCount(workers.configured, 'workers.configured'),
      busy: asCount(workers.busy, 'workers.busy'),
    },
    rate: {
      perMinute: asNumber(rate.perMinute, 'rate.perMinute'),
      windowSeconds: asNumber(rate.windowSeconds, 'rate.windowSeconds'),
    },
    etaSeconds: optional(obj.etaSeconds, 'etaSeconds', (value, path) =>
      nullable(value, path, asNonNegative),
    ),
    today: {
      built: asCount(today.built, 'today.built'),
      failed: asCount(today.failed, 'today.failed'),
    },
    cache: {
      entries: asCount(cache.entries, 'cache.entries'),
      bytes: asCount(cache.bytes, 'cache.bytes'),
    },
    jobs: {
      active: asCount(jobs.active, 'jobs.active'),
    },
    cpuTemperature: optional(obj.cpuTemperature, 'cpuTemperature', (value, path) =>
      nullable(value, path, asNumber),
    ),
    autoScan: optional(obj.autoScan, 'autoScan', parseAutoScanStatus),
  };
}

/** True while any item is waiting or being built: the dashboard then refreshes more often. */
export function isQueueBusy(status: ServerStatus): boolean {
  return status.queue.queued > 0 || status.queue.building > 0 || status.workers.busy > 0;
}

/** The state as the server reports it; an older server without `state` gets it from the queue. */
export function serverState(status: ServerStatus): ServerState {
  return status.state ?? (isQueueBusy(status) ? 'running' : 'idle');
}
