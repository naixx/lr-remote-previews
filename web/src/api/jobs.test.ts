import { describe, expect, it } from 'vitest';
import { sampleJob, sampleJobs } from '../test/fixtures';
import { parseJobList } from './jobs';
import { ShapeError } from './validate';

function shapeErrorOf(data: unknown): ShapeError {
  try {
    parseJobList(data);
  } catch (error) {
    if (error instanceof ShapeError) return error;
    throw error;
  }
  throw new Error('Expected a ShapeError.');
}

function listOf(job: unknown) {
  return { jobs: [job] };
}

describe('parseJobList', () => {
  it('accepts the contract example and keeps only known fields', () => {
    const job = { ...sampleJob(), priority: 3, counts: { ...sampleJob().counts, skipped: 0 } };
    expect(parseJobList({ jobs: [job], more: false })).toEqual(listOf(sampleJob()));
  });

  it('accepts every job state and an empty list', () => {
    expect(parseJobList(sampleJobs()).jobs.map((job) => job.state)).toEqual([
      'active',
      'done',
      'cancelled',
    ]);
    expect(parseJobList({ jobs: [] })).toEqual({ jobs: [] });
  });

  it('treats a label or client that is null or left out as none', () => {
    const withNulls = parseJobList(listOf(sampleJob({ label: null, client: null })));
    expect(withNulls.jobs[0]).toMatchObject({ label: null, client: null });

    const job: Record<string, unknown> = sampleJob();
    delete job.label;
    delete job.client;
    expect(parseJobList(listOf(job)).jobs[0]).toMatchObject({ label: null, client: null });
  });

  it('accepts times with an offset or fractions of a second', () => {
    const job = sampleJob({ created: '2026-11-14T09:30:00.123+00:00', finished: null });
    expect(parseJobList(listOf(job)).jobs[0]?.created).toBe('2026-11-14T09:30:00.123+00:00');
  });

  it('names the field that is wrong', () => {
    expect(shapeErrorOf(listOf(sampleJob({ state: 'paused' }))).path).toBe('jobs[0].state');
    expect(shapeErrorOf(listOf(sampleJob({ label: 7 as unknown as string }))).path).toBe(
      'jobs[0].label',
    );
    expect(shapeErrorOf(listOf(sampleJob({ counts: { failed: -2 } }))).path).toBe(
      'jobs[0].counts.failed',
    );
    expect(shapeErrorOf({ jobs: 'none' }).message).toBe('jobs: expected an array, got string "none"');
  });

  it('rejects times without a zone or that are not times', () => {
    expect(shapeErrorOf(listOf(sampleJob({ created: '2026-11-14 09:30' }))).path).toBe(
      'jobs[0].created',
    );
    expect(shapeErrorOf(listOf(sampleJob({ created: '2026-11-14T09:30:00' }))).path).toBe(
      'jobs[0].created',
    );
    expect(shapeErrorOf(listOf(sampleJob({ finished: 'yesterday' }))).path).toBe(
      'jobs[0].finished',
    );
  });
});
