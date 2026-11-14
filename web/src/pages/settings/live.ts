import type { ServerStatus } from '../../api/status';

/** How often the Settings page reads the status (scan state, cache size) while no scan runs. */
export const STATUS_REFRESH_MS = 30_000;
/** How often it reads the status while a scan runs. */
export const SCAN_REFRESH_MS = 2_000;
/**
 * After Scan now, how long it reads the status as often as during a scan even before the status
 * says one runs, so a short scan is not missed.
 */
export const SCAN_WATCH_MS = 10_000;

/** The wait before the next status request, given the latest one and the end of a watch. */
export function statusInterval(data: ServerStatus | null, watchUntil: number): number {
  return data?.autoScan?.running || Date.now() < watchUntil ? SCAN_REFRESH_MS : STATUS_REFRESH_MS;
}
