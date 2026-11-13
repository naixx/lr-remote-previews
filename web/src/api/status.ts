import { asCount, asNumber, asObject } from './validate';

/** Response of `GET /api/v1/status`: the server's work at this moment. */
export interface ServerStatus {
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
  };
}

/** True while any item is waiting or being built: the dashboard then refreshes more often. */
export function isQueueBusy(status: ServerStatus): boolean {
  return status.queue.queued > 0 || status.queue.building > 0 || status.workers.busy > 0;
}
