import { describe, expect, it } from 'vitest';
import {
  busyStatus,
  idleStatus,
  legacyStatus,
  scheduledScan,
  stage3Status,
} from '../test/fixtures';
import { isQueueBusy, parseServerStatus } from './status';
import { ShapeError } from './validate';

function shapeErrorOf(data: unknown): ShapeError {
  try {
    parseServerStatus(data);
  } catch (error) {
    if (error instanceof ShapeError) return error;
    throw error;
  }
  throw new Error('Expected a ShapeError.');
}

describe('parseServerStatus', () => {
  it('accepts the contract example and keeps only known fields', () => {
    const body = busyStatus();
    const status = parseServerStatus({ ...body, extra: true, queue: { ...body.queue, paused: 0 } });
    expect(status).toEqual(busyStatus());
  });

  it('accepts a whole-number rate', () => {
    expect(parseServerStatus(idleStatus()).rate.perMinute).toBe(0);
  });

  it('reads state, time left and temperature, each null where the server has none', () => {
    expect(parseServerStatus(busyStatus())).toMatchObject({
      state: 'running',
      etaSeconds: 104,
      cpuTemperature: 67.5,
    });
    expect(parseServerStatus(idleStatus())).toMatchObject({
      state: 'idle',
      etaSeconds: null,
      cpuTemperature: null,
    });
    for (const state of ['paused', 'waiting']) {
      expect(parseServerStatus({ ...idleStatus(), state }).state).toBe(state);
    }
  });

  it('accepts a server before 0.4 that sends none of them', () => {
    expect(parseServerStatus(legacyStatus())).toMatchObject({
      state: null,
      etaSeconds: null,
      cpuTemperature: null,
      autoScan: null,
    });
  });

  it('reads the automatic scan, and none from a server before 0.5', () => {
    expect(parseServerStatus(busyStatus()).autoScan).toEqual({
      running: false,
      lastRun: '2026-11-14T09:00:00Z',
      lastQueued: 120,
      nextRun: '2026-11-14T10:00:00Z',
    });
    expect(parseServerStatus(idleStatus()).autoScan).toEqual({
      running: false,
      lastRun: null,
      lastQueued: 0,
      nextRun: null,
    });
    expect(parseServerStatus(stage3Status())).toMatchObject({ state: 'running', autoScan: null });
  });

  it('names a wrong field of the automatic scan', () => {
    const body = busyStatus();
    expect(shapeErrorOf({ ...body, autoScan: scheduledScan({ running: 'no' as never }) }).path).toBe(
      'autoScan.running',
    );
    expect(shapeErrorOf({ ...body, autoScan: scheduledScan({ lastRun: '09:00' }) }).path).toBe(
      'autoScan.lastRun',
    );
    expect(shapeErrorOf({ ...body, autoScan: scheduledScan({ lastQueued: -1 }) }).path).toBe(
      'autoScan.lastQueued',
    );
    expect(shapeErrorOf({ ...body, autoScan: { running: false, lastRun: null, lastQueued: 0 } }).path).toBe(
      'autoScan.nextRun',
    );
  });

  it('rejects an unknown state, a negative time left and a temperature that is not a number', () => {
    expect(shapeErrorOf({ ...busyStatus(), state: 'sleeping' }).path).toBe('state');
    expect(shapeErrorOf({ ...busyStatus(), etaSeconds: -5 }).path).toBe('etaSeconds');
    expect(shapeErrorOf({ ...busyStatus(), cpuTemperature: '67' }).path).toBe('cpuTemperature');
  });

  it('rejects a missing section', () => {
    const data: Record<string, unknown> = busyStatus();
    delete data.cache;
    expect(shapeErrorOf(data).message).toBe('cache: expected an object, got nothing');
  });

  it('rejects counts that are negative or fractional', () => {
    const body = busyStatus();
    expect(shapeErrorOf({ ...body, queue: { queued: -1, building: 0 } }).path).toBe(
      'queue.queued',
    );
    expect(shapeErrorOf({ ...body, cache: { entries: 1.5, bytes: 10 } }).path).toBe(
      'cache.entries',
    );
  });
});

describe('isQueueBusy', () => {
  it('is true while anything is queued, building or running', () => {
    expect(isQueueBusy(parseServerStatus(busyStatus()))).toBe(true);
    expect(isQueueBusy(parseServerStatus(idleStatus()))).toBe(false);

    const idle = idleStatus();
    expect(isQueueBusy(parseServerStatus({ ...idle, queue: { queued: 1, building: 0 } }))).toBe(
      true,
    );
    expect(isQueueBusy(parseServerStatus({ ...idle, queue: { queued: 0, building: 1 } }))).toBe(
      true,
    );
  });
});
