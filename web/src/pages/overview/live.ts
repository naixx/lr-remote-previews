import type { ApiClient } from '../../api/client';
import type { Job } from '../../api/jobs';
import { isQueueBusy, type ServerStatus } from '../../api/status';

/** How many jobs the overview lists. */
export const RECENT_JOBS_LIMIT = 10;
/** Refresh interval while anything is queued or building. */
export const BUSY_REFRESH_MS = 2_000;
/** Refresh interval when the server is idle, and before the first answer. */
export const IDLE_REFRESH_MS = 10_000;

/** What the overview refreshes together: the server's status and its most recent jobs. */
export interface LiveOverview {
  status: ServerStatus;
  /** Newest first. */
  jobs: Job[];
}

/**
 * Loads status and jobs side by side. If one request fails the other is cancelled, so a failed
 * refresh leaves nothing in flight behind it.
 */
export async function loadLiveOverview(
  client: ApiClient,
  signal: AbortSignal,
): Promise<LiveOverview> {
  const controller = new AbortController();
  const forwardAbort = () => controller.abort(signal.reason);
  if (signal.aborted) forwardAbort();
  else signal.addEventListener('abort', forwardAbort, { once: true });

  try {
    const [status, list] = await Promise.all([
      client.getStatus(controller.signal),
      client.getJobs({ limit: RECENT_JOBS_LIMIT }, controller.signal),
    ]);
    return { status, jobs: list.jobs };
  } catch (error) {
    controller.abort();
    throw error;
  } finally {
    signal.removeEventListener('abort', forwardAbort);
  }
}

export function refreshInterval(data: LiveOverview | null): number {
  return data !== null && isQueueBusy(data.status) ? BUSY_REFRESH_MS : IDLE_REFRESH_MS;
}
