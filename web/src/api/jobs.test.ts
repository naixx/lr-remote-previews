import { describe, expect, it } from 'vitest';
import {
  failedItem,
  rejectedItem,
  sampleItem,
  sampleItemPage,
  sampleJob,
  sampleJobs,
  sampleResult,
} from '../test/fixtures';
import { jobTitle, parseItemPage, parseJobList } from './jobs';
import { ShapeError } from './validate';

describe('parseItemPage', () => {
  function itemError(data: unknown): ShapeError {
    try {
      parseItemPage(data);
    } catch (error) {
      if (error instanceof ShapeError) return error;
      throw error;
    }
    throw new Error('Expected a ShapeError.');
  }

  it('accepts ready, failed and rejected items and keeps only known fields', () => {
    const page = parseItemPage({
      ...sampleItemPage([{ ...sampleItem(), extra: 1 }, failedItem(), rejectedItem()]),
      cursor: 'ignored',
    });
    expect(page.items[0]).toEqual(sampleItem());
    expect(page.items[1]?.error?.code).toBe('converter_failed');
    expect(page.items[2]?.result).toBeNull();
    expect(page.more).toBe(false);
  });

  it('accepts a result whose DNG lacks the original name and size', () => {
    const result = sampleResult({ originalName: null, originalWidth: null, originalHeight: null });
    const page = parseItemPage(sampleItemPage([sampleItem({ result })]));
    expect(page.items[0]?.result).toMatchObject({ originalName: null, originalWidth: null });
  });

  it('names the field that is wrong', () => {
    expect(itemError(sampleItemPage([sampleItem({ id: 0 })])).path).toBe('items[0].id');
    expect(itemError(sampleItemPage([failedItem({ error: { code: 'x' } as never })])).path).toBe(
      'items[0].error.message',
    );
    expect(itemError({ ...sampleItemPage(), more: 'no' }).path).toBe('more');
    expect(itemError({ items: [], more: false }).path).toBe('job');
  });
});

describe('jobTitle', () => {
  it('uses the label, or the number when there is none', () => {
    expect(jobTitle(parseJobList({ jobs: [sampleJob()] }).jobs[0]!)).toBe('Lightroom selection');
    expect(jobTitle(parseJobList({ jobs: [sampleJob({ label: '  ' })] }).jobs[0]!)).toBe('Job 7');
  });
});

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
    delete job.clientId;
    expect(parseJobList(listOf(job)).jobs[0]).toMatchObject({
      label: null,
      client: null,
      clientId: null,
    });
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
