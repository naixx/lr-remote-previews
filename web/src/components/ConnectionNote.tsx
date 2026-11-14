import type { ApiError } from '../api/errors';
import { formatTimeOfDay } from '../lib/format';

/** Shown over data that is still on screen while refreshing it fails. */
export function ConnectionNote({
  error,
  updatedAt,
}: {
  error: ApiError;
  updatedAt: number | null;
}) {
  return (
    <p className="connection-note" role="status">
      <span className="connection-note__dot" aria-hidden="true" />
      <span>
        {error.kind === 'network'
          ? 'Connection lost, retrying…'
          : `Could not refresh: ${error.message} Retrying…`}
        {updatedAt !== null && (
          <span className="connection-note__since">
            {' '}
            Showing data from {formatTimeOfDay(updatedAt)}.
          </span>
        )}
      </span>
    </p>
  );
}
