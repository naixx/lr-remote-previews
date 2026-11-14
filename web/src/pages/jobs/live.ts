import type { ItemPage, JobList } from '../../api/jobs';

/** Refresh interval of a job list or a job while anything in it is active. */
export const ACTIVE_REFRESH_MS = 2_000;
/** Refresh interval when nothing shown is active (a retry from elsewhere still shows up). */
export const IDLE_REFRESH_MS = 15_000;

/** Jobs asked for at first, and added by each «Load more». */
export const JOBS_PAGE = 50;
/** The most `GET /api/v1/jobs` returns. */
export const JOBS_MAX = 200;

/** Items per page on a job's page: few enough to keep the table light. */
export const ITEMS_PAGE = 100;

export function listInterval(data: JobList | null): number {
  return data?.jobs.some((job) => job.state === 'active') ? ACTIVE_REFRESH_MS : IDLE_REFRESH_MS;
}

export function jobInterval(data: { page: ItemPage } | null): number {
  return data?.page.job.state === 'active' ? ACTIVE_REFRESH_MS : IDLE_REFRESH_MS;
}
