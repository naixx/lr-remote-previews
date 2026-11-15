import { useLayoutEffect, useMemo } from 'react';
import type { ApiError } from '../../api/errors';
import type { ServerInfo } from '../../api/info';
import { finishedCount, jobTitle, type Job } from '../../api/jobs';
import { isQueueBusy, serverState, type ServerStatus } from '../../api/status';
import { useApi } from '../../app/ApiContext';
import { links, type ColorScheme } from '../../app/router';
import { BrandMark } from '../../components/BrandMark';
import { JobProgressBar } from '../../components/JobList';
import { TokenForm } from '../../components/TokenForm';
import { usePageTitle } from '../../hooks/usePageTitle';
import { usePolling } from '../../hooks/usePolling';
import {
  byteParts,
  formatCount,
  formatQuantity,
  formatTimeLeft,
  formatTimeOfDay,
  plural,
  rateParts,
} from '../../lib/format';
import { AutoScanSummary, QueueBadge } from '../overview/QueueCard';
import {
  createWidgetLoader,
  jobsToShow,
  RETRY_DELAYS_MS,
  widgetInterval,
  type WidgetData,
} from './live';
import './widget.css';

/**
 * A compact status page for other dashboards to show in a frame (a TrueNAS tile, Homepage,
 * Homarr, Home Assistant) or to keep as a small pinned tab. It only reads: its controls are two
 * links into the dashboard, which open in a new tab, and «Check again».
 */
export function WidgetPage({
  theme,
  background = null,
}: {
  theme: ColorScheme | null;
  /** `'none'`: transparent, for a frame that sits in a card of another dashboard. */
  background?: 'none' | null;
}) {
  useWidgetDocument(theme, background);
  usePageTitle('Widget');
  const { authRequired } = useApi();

  // A frame often has its own storage, apart from the dashboard's (browsers partition it by
  // the embedding site), so the widget may have to ask for the token once in there.
  return authRequired ? (
    <main className="widget">
      <TokenForm detail={authRequired.detail} compact />
    </main>
  ) : (
    <LiveWidget />
  );
}

/**
 * Marks the document for the widget's styles (no room kept for a scroll bar, the card colour as
 * the background, or none) and sets a colour scheme given in the address, before the first paint.
 */
function useWidgetDocument(theme: ColorScheme | null, background: 'none' | null) {
  useLayoutEffect(() => {
    const root = document.documentElement;
    root.setAttribute('data-view', 'widget');
    if (theme) root.setAttribute('data-theme', theme);
    if (background) root.setAttribute('data-background', background);
    return () => {
      root.removeAttribute('data-view');
      root.removeAttribute('data-theme');
      root.removeAttribute('data-background');
    };
  }, [theme, background]);
}

function LiveWidget() {
  const { client } = useApi();
  // One loader per client: it keeps the info between refreshes, to ask for it once a minute.
  const load = useMemo(() => createWidgetLoader(client), [client]);
  // Polls like the overview while the server answers. When it stops answering, the polling gives
  // up after the retries of RETRY_DELAYS_MS, so that an open widget does not keep a sleeping NAS
  // awake or wake it again (live.ts explains); only «Check again» asks once more.
  const live = usePolling(load, { interval: widgetInterval, retryDelays: RETRY_DELAYS_MS });
  const { data, error } = live;
  const unreachable = error?.kind === 'network';

  return (
    <main className={unreachable && data ? 'widget widget--stale' : 'widget'}>
      <TitleRow data={data} />
      <ProblemLine
        data={data}
        error={error}
        gaveUp={live.gaveUp}
        updatedAt={live.updatedAt}
        onCheckAgain={live.refresh}
      />
      {data ? (
        <Figures data={data} now={live.checkedAt ?? 0} />
      ) : (
        !error && <p className="widget-now muted">Connecting…</p>
      )}
    </main>
  );
}

/** The brand, which opens the dashboard, and the state badge of the overview. */
function TitleRow({ data }: { data: WidgetData | null }) {
  return (
    <header className="widget-title">
      <h1 className="widget-title__name">
        <a className="widget-brand" href="./" target="_blank" rel="noopener">
          <BrandMark className="widget-brand__mark" />
          LR Remote Previews
        </a>
      </h1>
      {data && (
        <QueueBadge status={data.status} converterInstalled={data.info.converter.installed} />
      )}
    </header>
  );
}

interface ProblemLineProps {
  data: WidgetData | null;
  error: ApiError | null;
  gaveUp: boolean;
  /** When the last answer arrived. */
  updatedAt: number | null;
  onCheckAgain: () => void;
}

/** Only when something is wrong: the server cannot be reached, cannot build, or lacks a root. */
function ProblemLine({ data, error, gaveUp, updatedAt, onCheckAgain }: ProblemLineProps) {
  if (error?.kind === 'network') {
    return (
      <div className="widget-problem widget-problem--bad" role="status">
        <p className="widget-problem__text">
          <strong>Server not reachable.</strong>{' '}
          {gaveUp
            ? updatedAt !== null && `Last answer at ${formatTimeOfDay(updatedAt)}.`
            : 'Trying again…'}
        </p>
        {gaveUp && (
          <button type="button" className="button button--quiet" onClick={onCheckAgain}>
            Check again
          </button>
        )}
      </div>
    );
  }

  // Any other failure is an answer: the server is awake, and the polling goes on as usual.
  const problems = [
    error ? error.message : null,
    ...(data ? infoProblems(data.info) : []),
  ].filter((problem): problem is string => problem !== null);
  if (problems.length === 0) return null;
  const tone = error ? 'widget-problem widget-problem--bad' : 'widget-problem';
  return (
    <div className={tone} role="status">
      <div className="widget-problem__text">
        {problems.map((problem) => (
          <p key={problem}>{problem}</p>
        ))}
      </div>
    </div>
  );
}

function infoProblems(info: ServerInfo): string[] {
  const unavailable = info.roots.filter((root) => !root.available).map((root) => root.label);
  const roots = unavailable.length === 1 ? 'Library root' : 'Library roots';
  return [
    info.converter.installed ? null : 'Adobe DNG Converter is not installed.',
    unavailable.length > 0 ? `${roots} unavailable: ${unavailable.join(', ')}.` : null,
  ].filter((problem): problem is string => problem !== null);
}

/**
 * Everything below the problem line, in order of importance; each block is a child of the
 * widget, so the least important ones are the first to give way in a small frame (widget.css).
 */
function Figures({ data, now }: { data: WidgetData; now: number }) {
  const { status } = data;
  const { today, cache, workers } = status;
  return (
    <>
      <NowBlock status={status} jobs={jobsToShow(data.activeJobs)} />
      <dl className="widget-figure">
        <dt>Today</dt>
        <dd>
          {formatCount(today.built)} built ·{' '}
          {today.failed > 0 ? (
            <a
              className="text-bad widget-failed"
              href={links.jobs()}
              target="_blank"
              rel="noopener"
            >
              {formatCount(today.failed)} failed
            </a>
          ) : (
            <span className="muted">none failed</span>
          )}
        </dd>
      </dl>
      <dl className="widget-figure">
        <dt>Cache</dt>
        <dd>
          {plural(cache.entries, 'file', 'files')} · {formatQuantity(byteParts(cache.bytes))}
        </dd>
      </dl>
      <dl className="widget-figure widget-large">
        <dt>Processes</dt>
        <dd>
          {formatCount(workers.busy)} of {formatCount(workers.configured)} busy
        </dd>
      </dl>
      {status.autoScan && (
        <dl className="widget-figure widget-large">
          <dt>Automatic scan</dt>
          <dd>
            <AutoScanSummary scan={status.autoScan} now={now} />
          </dd>
        </dl>
      )}
    </>
  );
}

/** What the server does now: one calm line when idle, else the queue, the pace and the jobs. */
function NowBlock({ status, jobs }: { status: ServerStatus; jobs: Job[] }) {
  if (!isQueueBusy(status)) return <p className="widget-now">Nothing is queued.</p>;

  const { queued, building } = status.queue;
  const headline = [
    queued > 0 || building === 0 ? `${formatCount(queued)} queued` : null,
    building > 0 ? `${formatCount(building)} building` : null,
  ].filter((part): part is string => part !== null);

  return (
    <div className="widget-now">
      <p className="widget-now__headline">{headline.join(' · ')}</p>
      <p className="widget-now__detail">{nowDetail(status)}</p>
      {jobs.length > 0 && (
        <ul className="widget-jobs" aria-label="Active jobs">
          {jobs.map((job) => (
            <JobLine key={job.id} job={job} />
          ))}
        </ul>
      )}
    </div>
  );
}

function nowDetail(status: ServerStatus): string {
  switch (serverState(status)) {
    case 'paused':
      return 'Paused: no new conversions start.';
    case 'waiting':
      return 'Building starts when the working hours begin.';
    case 'running':
    case 'idle': {
      const { perMinute } = status.rate;
      const parts = [
        perMinute > 0 ? formatQuantity(rateParts(perMinute)) : null,
        status.etaSeconds === null ? null : formatTimeLeft(status.etaSeconds),
      ].filter((part): part is string => part !== null);
      return parts.length > 0 ? parts.join(' · ') : 'The time left is not known yet.';
    }
  }
}

/** One active job: its label, finished of total, and the progress bar of the job list. */
function JobLine({ job }: { job: Job }) {
  const title = jobTitle(job);
  const { counts } = job;
  return (
    <li className="widget-job">
      <div className="widget-job__head">
        <span className="widget-job__title" title={title}>
          {title}
        </span>
        <span className="widget-job__fraction">
          {formatCount(finishedCount(counts))} / {formatCount(counts.total)}
        </span>
      </div>
      <JobProgressBar counts={counts} label={`Progress of ${title}`} />
    </li>
  );
}
