import {
  SCAN_FILES_MAX,
  SCAN_FILES_MIN,
  SCAN_INTERVAL_MAX,
  SCAN_INTERVAL_MIN,
  SCAN_SETTLE_MAX,
  SCAN_SETTLE_MIN,
  type AutoScanSettings,
} from '../../api/settings';
import { formatCount } from '../../lib/format';
import { wholeNumber } from './form';

/** The automatic scan form as typed: numbers stay text until they are checked. */
export interface ScanValues {
  enabled: boolean;
  /** Root ids, in the order they were ticked. */
  roots: string[];
  interval: string;
  settle: string;
  maxFiles: string;
}

export interface ScanErrors {
  roots?: string;
  interval?: string;
  settle?: string;
  maxFiles?: string;
}

export function scanValuesOf(settings: AutoScanSettings): ScanValues {
  return {
    enabled: settings.enabled,
    roots: [...settings.roots],
    interval: String(settings.intervalMinutes),
    settle: String(settings.settleMinutes),
    maxFiles: String(settings.maxFilesPerRun),
  };
}

function inRange(text: string, min: number, max: number): number | null {
  const value = wholeNumber(text, String(max).length);
  return value !== null && value >= min && value <= max ? value : null;
}

/** The server's rules, so most mistakes are caught before sending. */
export function validateScan(values: ScanValues): ScanErrors {
  const errors: ScanErrors = {};
  // The protocol does not refuse a scan that is on without roots, but it would queue nothing.
  if (values.enabled && values.roots.length === 0) {
    errors.roots = 'Tick at least one root, or turn the automatic scan off.';
  }
  if (inRange(values.interval, SCAN_INTERVAL_MIN, SCAN_INTERVAL_MAX) === null) {
    errors.interval = `Enter a whole number of minutes from ${SCAN_INTERVAL_MIN} to ${formatCount(SCAN_INTERVAL_MAX)}.`;
  }
  if (inRange(values.settle, SCAN_SETTLE_MIN, SCAN_SETTLE_MAX) === null) {
    errors.settle = `Enter a whole number of minutes from ${SCAN_SETTLE_MIN} to ${formatCount(SCAN_SETTLE_MAX)}.`;
  }
  if (inRange(values.maxFiles, SCAN_FILES_MIN, SCAN_FILES_MAX) === null) {
    errors.maxFiles = `Enter a whole number from ${SCAN_FILES_MIN} to ${formatCount(SCAN_FILES_MAX)}.`;
  }
  return errors;
}

/**
 * The whole `autoScan` object to send when the form differs from the saved settings, or null
 * when nothing changed. Call only when `validateScan` found nothing.
 */
export function scanChange(initial: AutoScanSettings, values: ScanValues): AutoScanSettings | null {
  const next: AutoScanSettings = {
    enabled: values.enabled,
    roots: [...values.roots],
    intervalMinutes: wholeNumber(values.interval, 4) ?? initial.intervalMinutes,
    settleMinutes: wholeNumber(values.settle, 4) ?? initial.settleMinutes,
    maxFilesPerRun: wholeNumber(values.maxFiles, 5) ?? initial.maxFilesPerRun,
  };
  const sameRoots =
    next.roots.length === initial.roots.length &&
    next.roots.every((root) => initial.roots.includes(root));
  const unchanged =
    sameRoots &&
    next.enabled === initial.enabled &&
    next.intervalMinutes === initial.intervalMinutes &&
    next.settleMinutes === initial.settleMinutes &&
    next.maxFilesPerRun === initial.maxFilesPerRun;
  return unchanged ? null : next;
}
