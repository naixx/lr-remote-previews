/**
 * Formatting of numbers, sizes and times for display.
 *
 * Numbers follow the page language (English, as `<html lang="en">` says), so they read the same
 * as the text around them. Clock times follow the browser's locale and time zone, because a
 * person reads a time in their own format.
 */

const NUMBER_LOCALE = 'en';

const wholeNumber = new Intl.NumberFormat(NUMBER_LOCALE, { maximumFractionDigits: 0 });
const oneDecimal = new Intl.NumberFormat(NUMBER_LOCALE, { maximumFractionDigits: 1 });
const fixedDecimal = new Intl.NumberFormat(NUMBER_LOCALE, {
  minimumFractionDigits: 1,
  maximumFractionDigits: 1,
});

/** `1234` → `1,234`. */
export function formatCount(value: number): string {
  return wholeNumber.format(value);
}

/** A number and its unit, kept apart so the number can be set larger. */
export interface Quantity {
  value: string;
  unit: string;
}

/** `172.5` → `173 photos/min`; below 10 one decimal is kept (`0.5 photos/min`). */
export function rateParts(perMinute: number): Quantity {
  const value = (perMinute < 10 ? oneDecimal : wholeNumber).format(perMinute);
  return { value, unit: value === '1' ? 'photo/min' : 'photos/min' };
}

const BYTE_UNITS = ['B', 'kB', 'MB', 'GB', 'TB', 'PB'] as const;

/**
 * Decimal (SI) units, as storage is sold: `2890000000` → `2.9 GB`. Below 100 of a unit one
 * decimal is always shown (`3.0 GB`), so a growing size does not change its length every step.
 */
export function byteParts(bytes: number): Quantity {
  let unit = 0;
  let amount = bytes;
  while (amount >= 1000 && unit < BYTE_UNITS.length - 1) {
    amount /= 1000;
    unit += 1;
  }
  let value = (unit === 0 || amount >= 100 ? wholeNumber : fixedDecimal).format(amount);
  // 999.96 kB rounds to "1,000 kB"; say "1.0 MB" instead.
  if (value === '1,000' && unit > 0 && unit < BYTE_UNITS.length - 1) {
    value = fixedDecimal.format(1);
    unit += 1;
  }
  return { value, unit: BYTE_UNITS[unit] ?? 'B' };
}

export function formatQuantity({ value, unit }: Quantity): string {
  return `${value} ${unit}`;
}

const timeOfDay = new Intl.DateTimeFormat(undefined, { hour: '2-digit', minute: '2-digit' });
const dayAndTime = new Intl.DateTimeFormat(undefined, {
  day: 'numeric',
  month: 'short',
  hour: '2-digit',
  minute: '2-digit',
});
const fullDateAndTime = new Intl.DateTimeFormat(undefined, {
  day: 'numeric',
  month: 'short',
  year: 'numeric',
  hour: '2-digit',
  minute: '2-digit',
});
const fullWithSeconds = new Intl.DateTimeFormat(undefined, {
  dateStyle: 'medium',
  timeStyle: 'medium',
});
const timeWithSeconds = new Intl.DateTimeFormat(undefined, {
  hour: '2-digit',
  minute: '2-digit',
  second: '2-digit',
});

/**
 * A time in the browser's zone, as short as is unambiguous next to `now`: only the time today,
 * day and time this year, the full date otherwise.
 */
export function formatLocalTime(iso: string, now: number): string {
  const date = new Date(iso);
  const today = new Date(now);
  if (date.getFullYear() !== today.getFullYear()) return fullDateAndTime.format(date);
  if (date.getMonth() !== today.getMonth() || date.getDate() !== today.getDate()) {
    return dayAndTime.format(date);
  }
  return timeOfDay.format(date);
}

/** The full local date and time with seconds, for tooltips. */
export function formatFullTime(value: string | number): string {
  return fullWithSeconds.format(new Date(value));
}

/** The local time of day with seconds (`09:31:05`). */
export function formatTimeOfDay(value: number): string {
  return timeWithSeconds.format(new Date(value));
}

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

/** `3 min ago`, `5 h ago`, `2 days ago`; anything under a minute (or in the future) is `just now`. */
export function formatRelative(iso: string, now: number): string {
  const elapsed = now - Date.parse(iso);
  if (elapsed < MINUTE) return 'just now';
  if (elapsed < HOUR) return `${Math.floor(elapsed / MINUTE)} min ago`;
  if (elapsed < DAY) return `${Math.floor(elapsed / HOUR)} h ago`;
  const days = Math.floor(elapsed / DAY);
  return days === 1 ? '1 day ago' : `${days} days ago`;
}

/**
 * How long until a time in the future, in the largest whole unit: `in 27 min`, `in 3 h`,
 * `in 2 days`; `in less than a minute`, and `due now` for a time that has passed.
 */
export function formatUntil(iso: string, now: number): string {
  const left = Date.parse(iso) - now;
  if (left <= 0) return 'due now';
  if (left < MINUTE) return 'in less than a minute';
  if (left < HOUR) return `in ${Math.floor(left / MINUTE)} min`;
  if (left < DAY) return `in ${Math.floor(left / HOUR)} h`;
  const days = Math.floor(left / DAY);
  return days === 1 ? 'in 1 day' : `in ${days} days`;
}

/**
 * An estimate of time left, deliberately rough: `less than a minute left`, `about 4 min left`,
 * `about 2 h 15 min left`, `about 3 days left`.
 */
export function formatTimeLeft(seconds: number): string {
  const minutes = Math.round(seconds / 60);
  if (minutes < 1) return 'less than a minute left';
  if (minutes < 60) return `about ${minutes} min left`;
  const hours = Math.floor(minutes / 60);
  if (hours < 48) {
    const rest = minutes % 60;
    return rest === 0 ? `about ${hours} h left` : `about ${hours} h ${rest} min left`;
  }
  return `about ${Math.round(hours / 24)} days left`;
}

/** `67.5` → `68 °C`. */
export function formatTemperature(celsius: number): string {
  return `${wholeNumber.format(celsius)} °C`;
}

const logTime = new Intl.DateTimeFormat(undefined, {
  hour: '2-digit',
  minute: '2-digit',
  second: '2-digit',
  hourCycle: 'h23',
});

/** Local time of day with seconds for a log line, always on the 24-hour clock (`21:31:05`). */
export function formatLogTime(iso: string): string {
  return logTime.format(new Date(iso));
}

/** `1` → `1 file`, `3` → `3 files`, with grouped digits. */
export function plural(count: number, one: string, many: string): string {
  return `${formatCount(count)} ${count === 1 ? one : many}`;
}
