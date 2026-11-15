import type { ApiClient } from '../../api/client';
import type { ServerInfo } from '../../api/info';
import type { Job } from '../../api/jobs';
import { isQueueBusy, type ServerStatus } from '../../api/status';
import { loadTogether } from '../../api/together';
import { BUSY_REFRESH_MS, IDLE_REFRESH_MS } from '../overview/live';

/**
 * The waits before the tries that follow a failure to reach the server; after the last one the
 * widget stops asking until «Check again» is pressed.
 *
 * The server often runs on a NAS that goes to sleep when idle and is woken by requests to it. A
 * widget stays open for days in another dashboard or a pinned tab, so it must neither keep such
 * a NAS awake nor wake it: while the server answers, the widget asks only while it is visible,
 * as every page does; once the server stops answering (most likely the NAS went to sleep), it
 * tries three more times, in case it was a short break in the network, and then gives up.
 * Nothing starts it again by itself, not even showing the tab again, because a request to a
 * sleeping NAS can wake it.
 */
export const RETRY_DELAYS_MS: readonly number[] = [5_000, 15_000, 60_000];
/** The converter and the roots change rarely: `GET /api/v1/info` at most once a minute. */
export const INFO_REFRESH_MS = 60_000;
/** Active jobs the widget asks for, enough to find the one being built among them. */
export const ACTIVE_JOBS_LIMIT = 10;
/** Active jobs the widget shows at its largest size. */
export const SHOWN_JOBS = 3;

/** What the widget refreshes together. */
export interface WidgetData {
  status: ServerStatus;
  /** Newest first. */
  activeJobs: Job[];
  /** As of the last minute or so. */
  info: ServerInfo;
}

/**
 * A loader for the widget's polling: status and active jobs on every call, the info only when
 * the one it keeps is a minute old. One loader per API client, so a new token asks afresh.
 */
export function createWidgetLoader(
  client: ApiClient,
): (signal: AbortSignal) => Promise<WidgetData> {
  let kept: { info: ServerInfo; at: number } | null = null;

  return (signal) =>
    loadTogether(signal, async (shared) => {
      const known = kept && Date.now() - kept.at < INFO_REFRESH_MS ? kept.info : null;
      const [status, list, info] = await Promise.all([
        client.getStatus(shared),
        client.getJobs({ state: 'active', limit: ACTIVE_JOBS_LIMIT }, shared),
        known ?? client.getInfo(shared),
      ]);
      if (info !== known) kept = { info, at: Date.now() };
      return { status, activeJobs: list.jobs, info };
    });
}

/** As often as the overview: every 2 s while anything is queued or building, else every 10 s. */
export function widgetInterval(data: WidgetData | null): number {
  return data !== null && isQueueBusy(data.status) ? BUSY_REFRESH_MS : IDLE_REFRESH_MS;
}

/**
 * The active jobs to show, at most three: first the one being built (an active job with items
 * given to a converter process), else the newest; then the others, newest first. A job without
 * items has no progress to draw and is left out.
 */
export function jobsToShow(jobs: Job[]): Job[] {
  const withItems = jobs.filter((job) => job.counts.total > 0);
  const current = withItems.find((job) => job.counts.building > 0) ?? withItems[0];
  if (!current) return [];
  return [current, ...withItems.filter((job) => job !== current)].slice(0, SHOWN_JOBS);
}
