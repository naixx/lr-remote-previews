import {
  asArray,
  asCount,
  asInteger,
  asNullableString,
  asNullableTimestamp,
  asObject,
  asOneOf,
  asTimestamp,
  fieldPath,
  optional,
} from './validate';

export const JOB_STATES = ['active', 'done', 'cancelled'] as const;
/** `active` while any item is queued or building; `done` when none is; `cancelled` after a cancel. */
export type JobState = (typeof JOB_STATES)[number];

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
    // The protocol makes both optional in a request; a server may send null or leave them out.
    label: optional(obj.label, fieldPath(path, 'label'), asNullableString),
    client: optional(obj.client, fieldPath(path, 'client'), asNullableString),
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
