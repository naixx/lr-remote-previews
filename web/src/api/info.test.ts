import { describe, expect, it } from 'vitest';
import { sampleInfo } from '../test/fixtures';
import { parseServerInfo } from './info';
import { ShapeError } from './validate';

function shapeErrorOf(data: unknown): ShapeError {
  try {
    parseServerInfo(data);
  } catch (error) {
    if (error instanceof ShapeError) return error;
    throw error;
  }
  throw new Error('Expected a ShapeError.');
}

describe('parseServerInfo', () => {
  it('accepts the contract example and keeps only known fields', () => {
    const info = parseServerInfo({ ...sampleInfo(), extra: 'ignored' });
    expect(info).toEqual(sampleInfo());
  });

  it('accepts an installed converter with a version', () => {
    const body = sampleInfo();
    const data = { ...body, converter: { ...body.converter, installed: true, version: '17.5' } };
    expect(parseServerInfo(data).converter).toMatchObject({ installed: true, version: '17.5' });
  });

  it('rejects a non-object body', () => {
    expect(shapeErrorOf([]).message).toBe('response: expected an object, got an array');
  });

  it('rejects an unknown auth mode', () => {
    const error = shapeErrorOf({ ...sampleInfo(), auth: 'basic' });
    expect(error.path).toBe('auth');
    expect(error.message).toContain('"token", "none"');
  });

  it('names nested fields in the error', () => {
    const data = sampleInfo();
    expect(shapeErrorOf({ ...data, converter: { ...data.converter, path: null } }).path).toBe(
      'converter.path',
    );
    expect(
      shapeErrorOf({ ...data, capabilities: { extensions: ['.arw', 3], previewLongEdge: 2560 } })
        .path,
    ).toBe('capabilities.extensions[1]');
    expect(shapeErrorOf({ ...data, api: '1' }).path).toBe('api');
  });

  it('accepts an older server that does not send maxItemsPerJob', () => {
    const data = sampleInfo();
    const capabilities: Record<string, unknown> = { ...data.capabilities };
    delete capabilities.maxItemsPerJob;
    expect(parseServerInfo({ ...data, capabilities }).capabilities.maxItemsPerJob).toBeNull();
  });

  it('rejects a maxItemsPerJob that is not a count', () => {
    const data = sampleInfo();
    const capabilities = { ...data.capabilities, maxItemsPerJob: '5000' };
    expect(shapeErrorOf({ ...data, capabilities }).path).toBe('capabilities.maxItemsPerJob');
  });

  it('rejects a missing section', () => {
    const withoutRoots: Record<string, unknown> = sampleInfo();
    delete withoutRoots.roots;
    expect(shapeErrorOf(withoutRoots).message).toBe('roots: expected an array, got nothing');
  });
});
