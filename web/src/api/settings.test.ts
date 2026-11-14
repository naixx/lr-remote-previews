import { describe, expect, it } from 'vitest';
import { sampleBrowse, sampleFolderQueued, sampleSettings } from '../test/fixtures';
import { parseBrowse, parseFolderQueued } from './browse';
import { parseSettings } from './settings';
import { ShapeError } from './validate';

function shapeErrorOf(parse: (data: unknown) => unknown, data: unknown): ShapeError {
  try {
    parse(data);
  } catch (error) {
    if (error instanceof ShapeError) return error;
    throw error;
  }
  throw new Error('Expected a ShapeError.');
}

describe('parseSettings', () => {
  it('accepts the contract example and keeps only known fields', () => {
    expect(parseSettings({ ...sampleSettings(), theme: 'dark' })).toEqual(sampleSettings());
  });

  it('accepts a fixed number of processes', () => {
    expect(parseSettings(sampleSettings({ workers: 6 })).workers).toBe(6);
  });

  it('names the field that is wrong', () => {
    expect(shapeErrorOf(parseSettings, sampleSettings({ workers: 0 })).path).toBe('workers');
    expect(shapeErrorOf(parseSettings, { ...sampleSettings(), paused: 'no' }).path).toBe('paused');
    const hours = { enabled: true, from: '7:00', to: '22:00' };
    expect(shapeErrorOf(parseSettings, sampleSettings({ workingHours: hours })).path).toBe(
      'workingHours.from',
    );
    const late = { enabled: true, from: '22:00', to: '24:00' };
    expect(shapeErrorOf(parseSettings, sampleSettings({ workingHours: late })).path).toBe(
      'workingHours.to',
    );
  });
});

describe('parseBrowse and parseFolderQueued', () => {
  it('accepts the contract examples', () => {
    expect(parseBrowse(sampleBrowse())).toEqual(sampleBrowse());
    expect(parseBrowse(sampleBrowse({ path: '', parent: null })).parent).toBeNull();
    expect(parseFolderQueued(sampleFolderQueued()).jobs[0]?.client).toBe('dashboard');
    expect(parseFolderQueued({ files: 0, alreadyBuilt: 0, jobs: [] }).jobs).toEqual([]);
  });

  it('names the field that is wrong', () => {
    expect(shapeErrorOf(parseBrowse, sampleBrowse({ dirs: [{ name: 'a' }] as never })).path).toBe(
      'dirs[0].path',
    );
    expect(shapeErrorOf(parseBrowse, { ...sampleBrowse(), truncated: 1 }).path).toBe('truncated');
    expect(
      shapeErrorOf(parseFolderQueued, { ...sampleFolderQueued(), alreadyBuilt: null }).path,
    ).toBe('alreadyBuilt');
  });
});
