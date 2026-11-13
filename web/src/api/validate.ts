/**
 * Runtime checks for JSON received from the server.
 *
 * Every helper returns the value with a narrowed type or throws a ShapeError that names the
 * offending field (for example `roots[0].available`), so a mismatch between the dashboard and
 * the server is reported precisely instead of surfacing later as `undefined` in the UI.
 * Unknown extra fields are ignored, which keeps older dashboards working with newer servers.
 */

export class ShapeError extends Error {
  /** Dotted path of the field that failed, or an empty string for the top-level value. */
  readonly path: string;
  /** What the field should have been, in words. */
  readonly expected: string;

  constructor(path: string, expected: string, actual: unknown) {
    super(`${path || 'response'}: expected ${expected}, got ${describe(actual)}`);
    this.name = 'ShapeError';
    this.path = path;
    this.expected = expected;
  }
}

function describe(value: unknown): string {
  if (value === null) return 'null';
  if (value === undefined) return 'nothing';
  if (Array.isArray(value)) return 'an array';
  if (typeof value === 'object') return 'an object';
  const text = JSON.stringify(value);
  return `${typeof value} ${text.length > 40 ? `${text.slice(0, 37)}...` : text}`;
}

/** Path of a named field inside the value at `path`. */
export function fieldPath(path: string, key: string): string {
  return path ? `${path}.${key}` : key;
}

export function asObject(value: unknown, path: string): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new ShapeError(path, 'an object', value);
  }
  return value as Record<string, unknown>;
}

export function asString(value: unknown, path: string): string {
  if (typeof value !== 'string') throw new ShapeError(path, 'a string', value);
  return value;
}

export function asNullableString(value: unknown, path: string): string | null {
  if (value === null) return null;
  if (typeof value !== 'string') throw new ShapeError(path, 'a string or null', value);
  return value;
}

export function asBoolean(value: unknown, path: string): boolean {
  if (typeof value !== 'boolean') throw new ShapeError(path, 'true or false', value);
  return value;
}

export function asInteger(value: unknown, path: string): number {
  if (typeof value !== 'number' || !Number.isInteger(value)) {
    throw new ShapeError(path, 'an integer', value);
  }
  return value;
}

export function asOneOf<const T extends readonly string[]>(
  value: unknown,
  path: string,
  options: T,
): T[number] {
  const match = options.find((option) => option === value);
  if (match === undefined) {
    throw new ShapeError(path, `one of ${options.map((o) => JSON.stringify(o)).join(', ')}`, value);
  }
  return match;
}

export function asArray<T>(
  value: unknown,
  path: string,
  item: (value: unknown, path: string) => T,
): T[] {
  if (!Array.isArray(value)) throw new ShapeError(path, 'an array', value);
  return value.map((entry: unknown, index) => item(entry, `${path}[${index}]`));
}
