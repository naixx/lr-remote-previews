import { useCallback, useState } from 'react';
import type { JobState } from '../../api/jobs';
import { useApi } from '../../app/ApiContext';
import { links } from '../../app/router';
import { Card } from '../../components/Card';
import { ConnectionNote } from '../../components/ConnectionNote';
import { ErrorPanel } from '../../components/ErrorPanel';
import { JobList } from '../../components/JobList';
import { PageHeader } from '../../components/PageHeader';
import { StatePanel } from '../../components/StatePanel';
import { usePolling } from '../../hooks/usePolling';
import { formatCount } from '../../lib/format';
import { JOBS_MAX, JOBS_PAGE, listInterval } from './live';
import './jobs-page.css';

const FILTERS: { state: JobState | null; label: string }[] = [
  { state: null, label: 'All' },
  { state: 'active', label: 'Active' },
  { state: 'done', label: 'Done' },
  { state: 'cancelled', label: 'Cancelled' },
];

export function JobsPage({ state }: { state: JobState | null }) {
  const { client } = useApi();
  // How many jobs to ask for; back to one page when the filter changes.
  const [shown, setShown] = useState({ state, limit: JOBS_PAGE });
  const limit = shown.state === state ? shown.limit : JOBS_PAGE;

  const load = useCallback(
    (signal: AbortSignal) => client.getJobs({ limit, state: state ?? undefined }, signal),
    [client, limit, state],
  );
  const list = usePolling(load, { interval: listInterval, keepPrevious: true });
  const jobs = list.data?.jobs ?? null;
  // The previous, shorter list stays on screen while the longer one loads.
  const loadingMore = list.stale && limit > JOBS_PAGE;
  const canLoadMore = jobs !== null && (loadingMore || (jobs.length >= limit && limit < JOBS_MAX));

  return (
    <div className="page">
      <PageHeader
        title="Jobs"
        lead="Every job the server keeps, newest first: those sent by the Lightroom plug-in and the folders queued here."
      />
      <div className="page-stack">
        <nav aria-label="Filter jobs by state">
          <ul className="filters">
            {FILTERS.map((filter) => (
              <li key={filter.label}>
                <a
                  className="filter"
                  href={links.jobs(filter.state)}
                  aria-current={filter.state === state ? 'true' : undefined}
                >
                  {filter.label}
                </a>
              </li>
            ))}
          </ul>
        </nav>

        {list.data && list.error && <ConnectionNote error={list.error} updatedAt={list.updatedAt} />}

        {jobs === null ? (
          list.error ? (
            <ErrorPanel error={list.error} title="Jobs could not be loaded" onRetry={list.refresh} />
          ) : (
            <StatePanel tone="neutral" busy title="Loading jobs…" />
          )
        ) : (
          <Card
            title={`${FILTERS.find((filter) => filter.state === state)?.label ?? 'All'} jobs`}
            wide
            aside={<JobsCount count={jobs.length} />}
          >
            {jobs.length === 0 ? (
              <p className="muted">{emptyText(state)}</p>
            ) : (
              <div className={list.stale ? 'is-stale' : undefined} aria-busy={list.stale}>
                <JobList jobs={jobs} now={list.checkedAt ?? 0} label="Jobs" />
              </div>
            )}
            {canLoadMore && (
              <div className="actions">
                <button
                  type="button"
                  className="button button--secondary"
                  disabled={list.stale}
                  onClick={() => setShown({ state, limit: Math.min(limit + JOBS_PAGE, JOBS_MAX) })}
                >
                  {loadingMore ? 'Loading…' : 'Load more'}
                </button>
              </div>
            )}
            {jobs.length >= JOBS_MAX && (
              <p className="hint">
                These are the newest {formatCount(JOBS_MAX)} jobs; the server lists no older ones.
                Narrow the list with a filter to see others.
              </p>
            )}
          </Card>
        )}
      </div>
    </div>
  );
}

function JobsCount({ count }: { count: number }) {
  return <span className="card__meta tabular">{count === 1 ? '1 job' : `${formatCount(count)} jobs`}</span>;
}

function emptyText(state: JobState | null): string {
  switch (state) {
    case null:
      return 'No jobs yet. A job appears here when the Lightroom plug-in sends photos to the server, or when you queue a folder.';
    case 'active':
      return 'No job is active.';
    case 'done':
      return 'No job has finished yet, or the finished ones have expired.';
    case 'cancelled':
      return 'No job was cancelled.';
  }
}
