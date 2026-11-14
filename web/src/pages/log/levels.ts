/** Lines asked for: half of what the server keeps, plenty to read and light to render. */
export const LOG_LIMIT = 500;
/** How often the log is read again while updates are on. */
export const LOG_REFRESH_MS = 3_000;

export type LevelClass = 'debug' | 'info' | 'warning' | 'error';

/** The style group of a logging level name; unknown names read as info. */
export function levelOf(level: string): LevelClass {
  switch (level.toUpperCase()) {
    case 'DEBUG':
      return 'debug';
    case 'WARNING':
    case 'WARN':
      return 'warning';
    case 'ERROR':
    case 'CRITICAL':
    case 'FATAL':
      return 'error';
    default:
      return 'info';
  }
}
