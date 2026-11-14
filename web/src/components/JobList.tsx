import { finishedCount, jobTitle, type Job, type JobCounts } from '../api/jobs';
import { links } from '../app/router';
import { formatCount, formatFullTime, formatLocalTime, formatRelative } from '../lib/format';
import { StatusBadge } from './StatusBadge';
import './jobs.css';

/** Items that will not change any more, in the order the progress bar draws them. */
const FINISHED_PARTS = [
  { key: 'ready', label: 'ready' },
  { key: 'failed', label: 'failed' },
  { key: 'rejected', label: 'rejected' },
  { key: 'cancelled', label: 'cancelled' },
] as const satisfies readonly { key: keyof JobCounts; label: string }[];

const PENDING_PARTS = [
  { key: 'building', label: 'building' },
  { key: 'queued', label: 'queued' },
] as const satisfies readonly { key: keyof JobCounts; label: string }[];

/**
 * Room for "total / total" of the largest job in the list, so every bar has the same length and
 * keeps it while the counts grow.
 */
function fractionWidthFor(jobs: Job[]): string {
  const widest = Math.max(1, ...jobs.map((job) => formatCount(job.counts.total).length));
  return `${widest * 2 + 3}ch`;
}

interface JobListProps {
  /** In the order to show them. */
  jobs: Job[];
  /** The time the list was fetched, for "3 min ago". */
  now: number;
  /** Accessible name of the list. */
  label: string;
}

/** Jobs with their state, time and progress; each title links to the job's page. */
export function JobList({ jobs, now, label }: JobListProps) {
  const width = fractionWidthFor(jobs);
  return (
    <ul className="jobs" aria-label={label}>
      {jobs.map((job) => (
        <JobRow key={job.id} job={job} now={now} fractionWidth={width} />
      ))}
    </ul>
  );
}

interface JobRowProps {
  job: Job;
  now: number;
  /** CSS width reserved for the "finished / total" figure. */
  fractionWidth: string;
}

function JobRow({ job, now, fractionWidth }: JobRowProps) {
  const title = jobTitle(job);
  const hasLabel = Boolean(job.label?.trim());
  const meta = [hasLabel ? `Job ${job.id}` : null, job.client?.trim() || null].filter(Boolean);
  const { counts } = job;

  return (
    <li className="job">
      <div className="job__head">
        <h3 className="job__title">
          <a className="job__link" href={links.job(job.id)}>
            {title}
          </a>
        </h3>
        <JobStateBadge job={job} />
        <span className="job__time">
          <time dateTime={job.created} title={formatFullTime(job.created)}>
            {formatLocalTime(job.created, now)}
          </time>
          <span aria-hidden="true">·</span>
          <span className="job__ago">{formatRelative(job.created, now)}</span>
        </span>
      </div>
      {meta.length > 0 && <p className="job__meta">{meta.join(' · ')}</p>}
      <div className="job__progress">
        <JobProgressBar counts={counts} label={`Progress of ${title}`} />
        <span className="job__fraction" style={{ minWidth: fractionWidth }}>
          {formatCount(finishedCount(counts))} / {formatCount(counts.total)}
        </span>
      </div>
      <ul className="job__counts" aria-label={`Items of ${title}`}>
        {FINISHED_PARTS.map(({ key, label: text }) =>
          key === 'ready' || counts[key] > 0 ? (
            <li key={key} className={`job__count job__count--${key}`}>
              <span className="swatch" aria-hidden="true" />
              {formatCount(counts[key])} {text}
            </li>
          ) : null,
        )}
        {PENDING_PARTS.map(({ key, label: text }) =>
          counts[key] > 0 ? (
            <li key={key} className="job__count">
              {formatCount(counts[key])} {text}
            </li>
          ) : null,
        )}
      </ul>
    </li>
  );
}

/** The job's state in words; a finished job with failed or rejected items says so. */
export function JobStateBadge({ job }: { job: Job }) {
  switch (job.state) {
    case 'active':
      return <StatusBadge tone="info">Active</StatusBadge>;
    case 'done':
      return job.counts.failed + job.counts.rejected > 0 ? (
        <StatusBadge tone="warn">Done with problems</StatusBadge>
      ) : (
        <StatusBadge tone="ok">Done</StatusBadge>
      );
    case 'cancelled':
      return <StatusBadge tone="neutral">Cancelled</StatusBadge>;
  }
}

/** Finished items as a bar, with failed, rejected and cancelled drawn apart from ready ones. */
export function JobProgressBar({
  counts,
  label,
  large = false,
}: {
  counts: JobCounts;
  label: string;
  large?: boolean;
}) {
  const finished = finishedCount(counts);
  const share = (count: number) => (counts.total > 0 ? (count / counts.total) * 100 : 0);
  const summary = FINISHED_PARTS.filter(({ key }) => key === 'ready' || counts[key] > 0)
    .map(({ key, label: text }) => `${counts[key]} ${text}`)
    .join(', ');

  return (
    <div
      className={large ? 'progress progress--large' : 'progress'}
      role="progressbar"
      aria-label={label}
      aria-valuemin={0}
      aria-valuemax={counts.total}
      aria-valuenow={finished}
      aria-valuetext={`${finished} of ${counts.total} finished: ${summary}`}
    >
      {FINISHED_PARTS.map(({ key }) =>
        counts[key] > 0 ? (
          <span
            key={key}
            className={`progress__part progress__part--${key}`}
            style={{ width: `${share(counts[key])}%` }}
          />
        ) : null,
      )}
    </div>
  );
}
