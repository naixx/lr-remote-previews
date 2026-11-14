import { asArray, asObject, asString, asTimestamp, fieldPath } from './validate';

export interface LogLine {
  /** ISO 8601 time, UTC. */
  time: string;
  /** Python logging level name: `DEBUG`, `INFO`, `WARNING`, `ERROR`, `CRITICAL`. */
  level: string;
  logger: string;
  message: string;
}

/** Response of `GET /api/v1/log`. */
export interface ServerLog {
  /** Oldest first. */
  lines: LogLine[];
}

function parseLine(value: unknown, path: string): LogLine {
  const obj = asObject(value, path);
  return {
    time: asTimestamp(obj.time, fieldPath(path, 'time')),
    level: asString(obj.level, fieldPath(path, 'level')),
    logger: asString(obj.logger, fieldPath(path, 'logger')),
    message: asString(obj.message, fieldPath(path, 'message')),
  };
}

/** Checks the shape of a log response; throws a ShapeError naming the first bad field. */
export function parseLog(data: unknown): ServerLog {
  const obj = asObject(data, '');
  return { lines: asArray(obj.lines, 'lines', parseLine) };
}
