import type { Job } from '../../api/jobs';
import { links } from '../../app/router';
import { Card } from '../../components/Card';
import { JobList } from '../../components/JobList';

interface JobsCardProps {
  /** Newest first; null until the first list arrives. */
  jobs: Job[] | null;
  /** The time the list was fetched, for "3 min ago". */
  now: number;
}

export function JobsCard({ jobs, now }: JobsCardProps) {
  const aside =
    jobs && jobs.length > 0 ? (
      <span className="card__meta">
        Newest first · <a href={links.jobs()}>All jobs</a>
      </span>
    ) : null;
  return (
    <Card title="Jobs" wide aside={aside}>
      {jobs === null ? (
        <p className="muted">Loading…</p>
      ) : jobs.length === 0 ? (
        <p className="muted">
          No jobs yet. A job appears here when the Lightroom plug-in sends photos to the server, or
          when you queue a folder on the <a href={links.folder(null)}>Folders</a> page.
        </p>
      ) : (
        <JobList jobs={jobs} now={now} label="Recent jobs" />
      )}
    </Card>
  );
}
