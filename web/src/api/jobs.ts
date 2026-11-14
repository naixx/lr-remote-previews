import {
  asArray,
  asBoolean,
  asCount,
  asId,
  asInteger,
  asNullableString,
  asNullableTimestamp,
  asObject,
  asOneOf,
  asString,
  asTimestamp,
  fieldPath,
  nullable,
  optional,
} from './validate';

export const JOB_STATES = ['active', 'done', 'cancelled'] as const;
/** `active` while any item is queued or building; `done` when none is; `cancelled` after a cancel. */
export type JobState = (typeof JOB_STATES)[number];

export const JOB_PRIORITIES = ['normal', 'background'] as const;
/**
 * `normal` or `background`: the server builds every queued item of normal jobs before any item
 * of a background job, and within a priority the oldest job first.
 */
export type JobPriority = (typeof JOB_PRIORITIES)[number];

/** The `client` of the jobs the automatic scan makes. */
export const AUTO_SCAN_CLIENT = 'auto-scan';
/** The `client` of the jobs made by queueing a folder in the dashboard. */
export const DASHBOARD_CLIENT = 'dashboard';

export const ITEM_STATES = ['queued', 'building', 'ready', 'failed', 'rejected', 'cancelled'] as const;
/** The state of one file of a job; see the protocol's table of item states. */
export type ItemState = (typeof ITEM_STATES)[number];

/** How many of a job's items are in each state. */
export interface JobCounts {
  total: number;
  queued: number;
  building: number;
  ready: number;
  failed: number;
  rejected: number;
  cancelled: number;
}

/** The job object of the protocol. */
export interface Job {
  id: number;
  /** Free text from the client; null when it sent none. */
  label: string | null;
  /** Free text naming the client, such as `lr-plugin/0.2.0`; null when it sent none. */
  client: string | null;
  /** The identifier a client sends to find its own jobs again; null when it sent none. */
  clientId: string | null;
  /** Null from a server older than 0.5, which builds every job at the same priority. */
  priority: JobPriority | null;
  state: JobState;
  /** ISO 8601 time, UTC. */
  created: string;
  /** When the job left `active`, or null. */
  finished: string | null;
  /** Change counter: grows by one with every state change of any of the job's items. */
  seq: number;
  counts: JobCounts;
}

/** Response of `GET /api/v1/jobs`. */
export interface JobList {
  /** Newest first. */
  jobs: Job[];
}

/** Why an item failed or was rejected. */
export interface ItemError {
  code: string;
  message: string;
}

/** The finished DNG of a `ready` item. */
export interface ItemResult {
  /** Names the DNG in the server's cache. */
  key: string;
  size: number;
  sha256: string;
  /** As the DNG records them; null where it has no such tag. */
  originalName: string | null;
  originalWidth: number | null;
  originalHeight: number | null;
}

/** The item object of the protocol: one file of a job. */
export interface JobItem {
  id: number;
  /** Chosen by the client and echoed back. */
  ref: string;
  /** Root id and the path relative to it, with forward slashes. */
  root: string;
  path: string;
  state: ItemState;
  /** The job's change counter at the item's last state change. */
  seq: number;
  /** Set for `failed` and `rejected` items. */
  error: ItemError | null;
  /** Set for `ready` items. */
  result: ItemResult | null;
}

/** Response of `GET /api/v1/jobs/{id}/items`. */
export interface ItemPage {
  job: Job;
  /** Items whose seq is above the `since` that was asked for, ordered by seq. */
  items: JobItem[];
  /** True when the limit cut the list. */
  more: boolean;
}

function parseCounts(value: unknown, path: string): JobCounts {
  const obj = asObject(value, path);
  const count = (key: keyof JobCounts) => asCount(obj[key], fieldPath(path, key));
  return {
    total: count('total'),
    queued: count('queued'),
    building: count('building'),
    ready: count('ready'),
    failed: count('failed'),
    rejected: count('rejected'),
    cancelled: count('cancelled'),
  };
}

/** Checks one job object; `path` names it in errors (`jobs[3]`). */
export function parseJob(value: unknown, path: string): Job {
  const obj = asObject(value, path);
  return {
    id: asInteger(obj.id, fieldPath(path, 'id')),
    // The protocol makes these optional in a request; a server may send null or leave them out.
    label: optional(obj.label, fieldPath(path, 'label'), asNullableString),
    client: optional(obj.client, fieldPath(path, 'client'), asNullableString),
    clientId: optional(obj.clientId, fieldPath(path, 'clientId'), asNullableString),
    priority: optional(obj.priority, fieldPath(path, 'priority'), (value, at) =>
      asOneOf(value, at, JOB_PRIORITIES),
    ),
    state: asOneOf(obj.state, fieldPath(path, 'state'), JOB_STATES),
    created: asTimestamp(obj.created, fieldPath(path, 'created')),
    finished: asNullableTimestamp(obj.finished, fieldPath(path, 'finished')),
    seq: asInteger(obj.seq, fieldPath(path, 'seq')),
    counts: parseCounts(obj.counts, fieldPath(path, 'counts')),
  };
}

/** Checks the shape of a job list response; throws a ShapeError naming the first bad field. */
export function parseJobList(data: unknown): JobList {
  const obj = asObject(data, '');
  return { jobs: asArray(obj.jobs, 'jobs', parseJob) };
}

/** Checks `{"job": {...}}`, the answer of reading, cancelling and retrying a job. */
export function parseJobResponse(data: unknown): Job {
  const obj = asObject(data, '');
  return parseJob(obj.job, 'job');
}

function parseItemError(value: unknown, path: string): ItemError {
  const obj = asObject(value, path);
  return {
    code: asString(obj.code, fieldPath(path, 'code')),
    message: asString(obj.message, fieldPath(path, 'message')),
  };
}

function parseItemResult(value: unknown, path: string): ItemResult {
  const obj = asObject(value, path);
  return {
    key: asString(obj.key, fieldPath(path, 'key')),
    size: asCount(obj.size, fieldPath(path, 'size')),
    sha256: asString(obj.sha256, fieldPath(path, 'sha256')),
    originalName: asNullableString(obj.originalName, fieldPath(path, 'originalName')),
    originalWidth: nullable(obj.originalWidth, fieldPath(path, 'originalWidth'), asCount),
    originalHeight: nullable(obj.originalHeight, fieldPath(path, 'originalHeight'), asCount),
  };
}

/** Checks one item object; `path` names it in errors (`items[3]`). */
export function parseItem(value: unknown, path: string): JobItem {
  const obj = asObject(value, path);
  return {
    id: asId(obj.id, fieldPath(path, 'id')),
    ref: asString(obj.ref, fieldPath(path, 'ref')),
    root: asString(obj.root, fieldPath(path, 'root')),
    path: asString(obj.path, fieldPath(path, 'path')),
    state: asOneOf(obj.state, fieldPath(path, 'state'), ITEM_STATES),
    seq: asInteger(obj.seq, fieldPath(path, 'seq')),
    error: nullable(obj.error, fieldPath(path, 'error'), parseItemError),
    result: nullable(obj.result, fieldPath(path, 'result'), parseItemResult),
  };
}

/** Checks the shape of an item page; throws a ShapeError naming the first bad field. */
export function parseItemPage(data: unknown): ItemPage {
  const obj = asObject(data, '');
  return {
    job: parseJob(obj.job, 'job'),
    items: asArray(obj.items, 'items', parseItem),
    more: asBoolean(obj.more, 'more'),
  };
}

/** Items that will not change any more. */
export function finishedCount(counts: JobCounts): number {
  return counts.ready + counts.failed + counts.rejected + counts.cancelled;
}

/**
 * Who made the job, in words: the automatic scan and the dashboard by name, anything else as it
 * calls itself (`lr-plugin/0.3.0`); null when the job does not say.
 */
export function clientName(client: string | null): string | null {
  const name = client?.trim();
  if (!name) return null;
  if (name === AUTO_SCAN_CLIENT) return 'Automatic scan';
  if (name === DASHBOARD_CLIENT) return 'Dashboard';
  return name;
}

/** The label a person gave the job, or «Job 7». */
export function jobTitle(job: Job): string {
  const label = job.label?.trim();
  return label ? label : `Job ${job.id}`;
}
