import type { ApiClient } from '../../api/client';
import { isMissingEndpoint, toApiError } from '../../api/errors';
import type { Job } from '../../api/jobs';
import type { ServerSettings } from '../../api/settings';
import { isQueueBusy, type ServerStatus } from '../../api/status';
import { loadTogether } from '../../api/together';

/** How many jobs the overview lists. */
export const RECENT_JOBS_LIMIT = 10;
/** Refresh interval while anything is queued or building. */
export const BUSY_REFRESH_MS = 2_000;
/** Refresh interval when the server is idle, and before the first answer. */
export const IDLE_REFRESH_MS = 10_000;

/** What the overview refreshes together. */
export interface LiveOverview {
  status: ServerStatus;
  /** Newest first. */
  jobs: Job[];
  /** For the pause button; null from a server older than 0.4, which has no settings. */
  settings: ServerSettings | null;
}

/**
 * Loads status, jobs and settings side by side. If one request fails the others are cancelled,
 * so a failed refresh leaves nothing in flight behind it.
 */
export function loadLiveOverview(client: ApiClient, signal: AbortSignal): Promise<LiveOverview> {
  return loadTogether(signal, async (shared) => {
    const [status, list, settings] = await Promise.all([
      client.getStatus(shared),
      client.getJobs({ limit: RECENT_JOBS_LIMIT }, shared),
      client.getSettings(shared).catch((error: unknown) => {
        if (isMissingEndpoint(toApiError(error))) return null;
        throw error;
      }),
    ]);
    return { status, jobs: list.jobs, settings };
  });
}

export function refreshInterval(data: LiveOverview | null): number {
  return data !== null && isQueueBusy(data.status) ? BUSY_REFRESH_MS : IDLE_REFRESH_MS;
}
