import { asBoolean, asObject } from './validate';

/** Response of `POST /api/v1/autoscan/run` (`202`). */
export interface AutoScanStarted {
  started: boolean;
}

/** Checks the answer to starting a scan; throws a ShapeError naming the first bad field. */
export function parseAutoScanStarted(data: unknown): AutoScanStarted {
  const obj = asObject(data, '');
  return { started: asBoolean(obj.started, 'started') };
}
