import {
  BATCH_MAX,
  BATCH_MIN,
  WORKERS_FORBIDDEN,
  WORKERS_MAX,
  WORKERS_MIN,
  type ServerSettings,
  type SettingsChange,
} from '../../api/settings';

/** The settings form as typed: numbers stay text until they are checked. */
export interface FormValues {
  workersMode: 'auto' | 'fixed';
  workersCount: string;
  batchSize: string;
  hoursEnabled: boolean;
  from: string;
  to: string;
}

export interface FormErrors {
  workers?: string;
  batchSize?: string;
  hours?: string;
}

export function formValuesOf(settings: ServerSettings): FormValues {
  return {
    workersMode: settings.workers === 'auto' ? 'auto' : 'fixed',
    workersCount: String(settings.workers === 'auto' ? settings.effectiveWorkers : settings.workers),
    batchSize: String(settings.batchSize),
    hoursEnabled: settings.workingHours.enabled,
    from: settings.workingHours.from,
    to: settings.workingHours.to,
  };
}

/** A whole number written in decimal digits only, or null. */
function wholeNumber(text: string): number | null {
  const trimmed = text.trim();
  return /^\d{1,4}$/.test(trimmed) ? Number(trimmed) : null;
}

const CLOCK_TIME = /^(?:[01]\d|2[0-3]):[0-5]\d$/;

/** The same rules the server applies, so most mistakes are caught before sending. */
export function validate(values: FormValues): FormErrors {
  const errors: FormErrors = {};
  if (values.workersMode === 'fixed') {
    const count = wholeNumber(values.workersCount);
    if (count === null || count < WORKERS_MIN || count > WORKERS_MAX) {
      errors.workers = `Enter a whole number from ${WORKERS_MIN} to ${WORKERS_MAX}.`;
    } else if (count === WORKERS_FORBIDDEN) {
      errors.workers = 'Two processes are not allowed: they waste CPU time. Use 1, or 3 or more.';
    }
  }
  const batch = wholeNumber(values.batchSize);
  if (batch === null || batch < BATCH_MIN || batch > BATCH_MAX) {
    errors.batchSize = `Enter a whole number from ${BATCH_MIN} to ${BATCH_MAX}.`;
  }
  if (!CLOCK_TIME.test(values.from) || !CLOCK_TIME.test(values.to)) {
    errors.hours = 'Enter both times as hours and minutes, such as 22:00.';
  } else if (values.hoursEnabled && values.from === values.to) {
    errors.hours = 'The start and the end must differ.';
  }
  return errors;
}

/**
 * What the form changes compared with the settings it started from: only these fields are
 * sent, so a change made elsewhere meanwhile (such as Pause) is not overwritten. Call only
 * when `validate` found nothing.
 */
export function changesOf(initial: ServerSettings, values: FormValues): SettingsChange {
  const change: SettingsChange = {};
  const workers = values.workersMode === 'auto' ? 'auto' : wholeNumber(values.workersCount);
  if (workers !== null && workers !== initial.workers) change.workers = workers;
  const batch = wholeNumber(values.batchSize);
  if (batch !== null && batch !== initial.batchSize) change.batchSize = batch;
  const hours = initial.workingHours;
  if (
    values.hoursEnabled !== hours.enabled ||
    values.from !== hours.from ||
    values.to !== hours.to
  ) {
    change.workingHours = { enabled: values.hoursEnabled, from: values.from, to: values.to };
  }
  return change;
}
