import { useCallback, useState } from 'react';
import {
  clientName,
  finishedCount,
  ITEM_STATES,
  jobTitle,
  type ItemPage,
  type ItemState,
  type Job,
  type JobItem,
} from '../../api/jobs';
import { useApi } from '../../app/ApiContext';
import { links } from '../../app/router';
import { ActionError } from '../../components/ActionError';
import { Card } from '../../components/Card';
import { ConfirmPanel } from '../../components/ConfirmPanel';
import { ConnectionNote } from '../../components/ConnectionNote';
import { ErrorPanel } from '../../components/ErrorPanel';
import { Fact } from '../../components/Fact';
import { JobProgressBar, JobStateBadge, PriorityBadge } from '../../components/JobList';
import { PageHeader } from '../../components/PageHeader';
import { StatePanel } from '../../components/StatePanel';
import { StatusBadge, type Tone } from '../../components/StatusBadge';
import { useAction } from '../../hooks/useAction';
import { usePolling } from '../../hooks/usePolling';
import { explainItemError } from '../../lib/codes';
import {
  byteParts,
  formatCount,
  formatFullTime,
  formatLocalTime,
  formatQuantity,
  formatRelative,
  plural,
} from '../../lib/format';
import { ITEMS_PAGE, jobInterval } from './live';
import './jobs-page.css';

interface JobPageProps {
  id: number;
  /** Only items in this state; all when null. */
  itemState: ItemState | null;
}

/** One loaded page of items, with the query it answers. */
interface LoadedPage {
  since: number;
  filter: ItemState | null;
  page: ItemPage;
}

interface Paging {
  filter: ItemState | null;
  /** The `since` of every page from the first to the one shown. */
  cursors: number[];
}

export function JobPage({ id, itemState }: JobPageProps) {
  const { client } = useApi();
  const [paging, setPaging] = useState<Paging>({ filter: itemState, cursors: [0] });
  // A new filter starts on the first page again.
  const cursors = paging.filter === itemState ? paging.cursors : [0];
  const since = cursors[cursors.length - 1] ?? 0;

  const load = useCallback(
    async (signal: AbortSignal): Promise<LoadedPage> => {
      const page = await client.getJobItems(
        id,
        { since, limit: ITEMS_PAGE, state: itemState ?? undefined },
        signal,
      );
      return { since, filter: itemState, page };
    },
    [client, id, since, itemState],
  );
  const polled = usePolling(load, { interval: jobInterval, keepPrevious: true });
  const loaded = polled.data;
  const job = loaded?.page.job ?? null;
  const title = job ? jobTitle(job) : `Job ${id}`;

  return (
    <div className="page">
      <PageHeader
        title={title}
        lead={
          <a href={links.jobs()} className="back-link">
            All jobs
          </a>
        }
      />
      {loaded === null || job === null ? (
        polled.error ? (
          polled.error.kind === 'http' && polled.error.status === 404 ? (
            <JobNotFound id={id} />
          ) : (
            <ErrorPanel error={polled.error} title="The job could not be loaded" onRetry={polled.refresh} />
          )
        ) : (
          <StatePanel tone="neutral" busy title="Loading the job…" />
        )
      ) : (
        <div className="page-stack">
          {polled.error && <ConnectionNote error={polled.error} updatedAt={polled.updatedAt} />}
          <JobCard job={job} now={polled.checkedAt ?? 0} onChanged={polled.refresh} />
          <ItemsCard
            job={job}
            filter={itemState}
            loaded={loaded}
            stale={polled.stale}
            pageIndex={cursors.length - 1}
            onNext={(lastSeq) =>
              setPaging({ filter: itemState, cursors: [...cursors, lastSeq] })
            }
            onPrevious={() => setPaging({ filter: itemState, cursors: cursors.slice(0, -1) })}
          />
        </div>
      )}
    </div>
  );
}

function JobNotFound({ id }: { id: number }) {
  return (
    <StatePanel
      tone="neutral"
      title={`Job ${id} was not found`}
      actions={
        <a className="button" href={links.jobs()}>
          All jobs
        </a>
      }
    >
      <p>
        The server has no job with this number. Finished jobs are deleted some days after they
        finish (their DNGs stay in the cache), so it may have expired.
      </p>
    </StatePanel>
  );
}

interface JobCardProps {
  job: Job;
  now: number;
  /** After a cancel or retry: refresh at once. */
  onChanged: () => void;
}

function JobCard({ job, now, onChanged }: JobCardProps) {
  const { client } = useApi();
  const [confirming, setConfirming] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const cancel = useAction(useCallback(() => client.cancelJob(job.id), [client, job.id]));
  const retry = useAction(useCallback(() => client.retryJob(job.id), [client, job.id]));
  const { counts } = job;
  const canCancel = job.state === 'active';
  const canRetry = counts.failed > 0 && job.state !== 'cancelled';

  async function confirmCancel() {
    const result = await cancel.run();
    if (!result) return;
    setConfirming(false);
    setNotice('The job was cancelled.');
    onChanged();
  }

  async function startRetry() {
    setNotice(null);
    cancel.reset();
    const result = await retry.run();
    if (!result) return;
    setNotice(`${plural(counts.failed, 'failed item is', 'failed items are')} queued again.`);
    onChanged();
  }

  return (
    <Card
      title="Job"
      wide
      aside={
        <span className="job-badges">
          <JobStateBadge job={job} />
          <PriorityBadge job={job} />
        </span>
      }
    >
      <dl className="facts facts--small">
        <Fact label="Number">{job.id}</Fact>
        <Fact label="Created">
          <time dateTime={job.created} title={formatFullTime(job.created)}>
            {formatLocalTime(job.created, now)}
          </time>
          <span className="facts__note">{formatRelative(job.created, now)}</span>
        </Fact>
        <Fact label="Finished">
          {job.finished ? (
            <time dateTime={job.finished} title={formatFullTime(job.finished)}>
              {formatLocalTime(job.finished, now)}
            </time>
          ) : (
            'Not yet'
          )}
        </Fact>
        <Fact label="Sent by">{clientName(job.client) ?? 'Not named'}</Fact>
        {job.priority !== null && (
          <Fact label="Priority">
            {job.priority === 'background' ? 'Background' : 'Normal'}
            <span className="facts__note">
              {job.priority === 'background'
                ? 'Built when no normal job is waiting'
                : 'Built in turn, oldest job first'}
            </span>
          </Fact>
        )}
        {job.clientId && (
          <Fact label="Client id">
            <code className="client-id">{job.clientId}</code>
          </Fact>
        )}
      </dl>

      <div className="job-progress">
        <div className="job__progress">
          <JobProgressBar counts={counts} label={`Progress of ${jobTitle(job)}`} large />
          <span
            className="job-progress__fraction"
            // Room for "total / total", so the bar keeps its length while the count grows.
            style={{ minWidth: `${formatCount(counts.total).length * 2 + 3}ch` }}
          >
            {formatCount(finishedCount(counts))} / {formatCount(counts.total)}
          </span>
        </div>
        <p className="hint">
          {counts.total === 0
            ? 'The job has no items.'
            : `${formatCount(finishedCount(counts))} of ${plural(counts.total, 'item', 'items')} finished.`}
        </p>
      </div>

      {(canCancel || canRetry) && (
        <div className="actions">
          {canRetry && (
            <button
              type="button"
              className="button"
              disabled={retry.pending}
              onClick={() => void startRetry()}
            >
              {retry.pending && <span className="spinner spinner--small" aria-hidden="true" />}
              Retry {plural(counts.failed, 'failed item', 'failed items')}
            </button>
          )}
          {canCancel && !confirming && (
            <button
              type="button"
              className="button button--secondary"
              onClick={() => {
                setNotice(null);
                retry.reset();
                cancel.reset();
                setConfirming(true);
              }}
            >
              Cancel job…
            </button>
          )}
        </div>
      )}
      {confirming && canCancel && (
        <ConfirmPanel
          title="Cancel this job?"
          tone="danger"
          confirmLabel="Cancel job"
          cancelLabel="Keep the job"
          pending={cancel.pending}
          onConfirm={() => void confirmCancel()}
          onCancel={() => {
            cancel.reset();
            setConfirming(false);
          }}
        >
          <p>
            {counts.queued > 0
              ? `${plural(counts.queued, 'queued item', 'queued items')} will not be built.`
              : 'No item is waiting.'}{' '}
            {counts.building > 0 &&
              `${plural(counts.building, 'item that is', 'items that are')} being built now finish, and their DNGs stay in the cache.`}
          </p>
          <p>This cannot be undone; queue the files again to build them later.</p>
        </ConfirmPanel>
      )}
      <ActionError error={cancel.error} action="Could not cancel the job" />
      <ActionError
        error={retry.error}
        action="Could not retry the failed items"
        explain={(error) =>
          error.code === 'job_cancelled' ? 'A cancelled job cannot be retried.' : null
        }
      />
      {notice && (
        <p className="callout callout--ok" role="status">
          {notice}
        </p>
      )}
    </Card>
  );
}

const STATE_LABELS: Record<ItemState, { label: string; tone: Tone }> = {
  queued: { label: 'Queued', tone: 'neutral' },
  building: { label: 'Building', tone: 'info' },
  ready: { label: 'Ready', tone: 'ok' },
  failed: { label: 'Failed', tone: 'bad' },
  rejected: { label: 'Rejected', tone: 'warn' },
  cancelled: { label: 'Cancelled', tone: 'neutral' },
};

interface ItemsCardProps {
  job: Job;
  filter: ItemState | null;
  loaded: LoadedPage;
  /** True while the page shown belongs to a previous filter or page. */
  stale: boolean;
  /** The page being shown or loaded, from 0. */
  pageIndex: number;
  onNext: (lastSeq: number) => void;
  onPrevious: () => void;
}

function ItemsCard({ job, filter, loaded, stale, pageIndex, onNext, onPrevious }: ItemsCardProps) {
  const { counts } = job;
  const { items, more } = loaded.page;
  const matching = filter ? counts[filter] : counts.total;
  const first = pageIndex * ITEMS_PAGE + 1;
  const last = pageIndex * ITEMS_PAGE + items.length;
  const lastItem = items[items.length - 1];

  return (
    <Card title="Items" wide>
      <nav aria-label="Filter items by state">
        <ul className="filters">
          <FilterLink job={job} state={null} current={filter} count={counts.total} label="All" />
          {ITEM_STATES.map((state) => (
            <FilterLink
              key={state}
              job={job}
              state={state}
              current={filter}
              count={counts[state]}
              label={STATE_LABELS[state].label}
            />
          ))}
        </ul>
      </nav>

      {items.length === 0 && !stale ? (
        <p className="muted">
          {filter
            ? `No ${STATE_LABELS[filter].label.toLowerCase()} items.`
            : pageIndex > 0
              ? 'No more items.'
              : 'The job has no items.'}
        </p>
      ) : (
        <div className={stale ? 'table-wrap is-stale' : 'table-wrap'} aria-busy={stale}>
          <table className="table table--stack items-table">
            <caption className="visually-hidden">
              {filter ? `${STATE_LABELS[filter].label} items` : 'Items'} of {jobTitle(job)}
            </caption>
            <thead>
              <tr>
                <th scope="col">File</th>
                <th scope="col">State</th>
                <th scope="col">Details</th>
              </tr>
            </thead>
            <tbody>
              {items.map((item) => (
                <ItemRow key={item.id} item={item} />
              ))}
            </tbody>
          </table>
        </div>
      )}

      <div className="pager">
        <p className="pager__range" aria-live="polite">
          {items.length > 0
            ? `Items ${formatCount(first)}–${formatCount(last)} of ${formatCount(Math.max(matching, last))}`
            : ' '}
          {stale && ' · Loading…'}
        </p>
        <div className="pager__buttons">
          <button
            type="button"
            className="button button--quiet"
            disabled={pageIndex === 0 || stale}
            onClick={onPrevious}
          >
            Previous
          </button>
          <button
            type="button"
            className="button button--quiet"
            disabled={!more || stale || lastItem === undefined}
            onClick={() => {
              if (lastItem) onNext(lastItem.seq);
            }}
          >
            Next
          </button>
        </div>
      </div>
      <p className="hint">
        Items are listed in the order of their last change
        {job.state === 'active' ? '; while the job runs they move as they are built.' : '.'}
      </p>
    </Card>
  );
}

function FilterLink({
  job,
  state,
  current,
  count,
  label,
}: {
  job: Job;
  state: ItemState | null;
  current: ItemState | null;
  count: number;
  label: string;
}) {
  return (
    <li>
      <a
        className="filter"
        href={links.job(job.id, state)}
        aria-current={state === current ? 'true' : undefined}
      >
        {state && <span className={`swatch swatch--${state}`} aria-hidden="true" />}
        {label}
        <span className="filter__count">{formatCount(count)}</span>
      </a>
    </li>
  );
}

function splitPath(path: string): { name: string; folder: string } {
  const at = path.lastIndexOf('/');
  return at === -1 ? { name: path, folder: '' } : { name: path.slice(at + 1), folder: path.slice(0, at) };
}

function ItemRow({ item }: { item: JobItem }) {
  const { name, folder } = splitPath(item.path);
  const { label, tone } = STATE_LABELS[item.state];
  return (
    <tr>
      <td data-label="File">
        <span className="item-name">{name || item.path}</span>
        <span className="item-where">
          {item.root}
          {folder && ` · ${folder}`}
        </span>
      </td>
      <td data-label="State">
        <StatusBadge tone={tone}>{label}</StatusBadge>
      </td>
      <td data-label="Details">
        <ItemDetails item={item} />
      </td>
    </tr>
  );
}

function ItemDetails({ item }: { item: JobItem }) {
  if (item.error) {
    const explanation = explainItemError(item.error.code);
    return (
      <span className="item-error">
        <code className="item-error__code">{item.error.code}</code>{' '}
        {item.error.message || explanation}
        {item.error.message && explanation && item.error.message !== explanation && (
          <span className="item-error__hint">{explanation}</span>
        )}
      </span>
    );
  }
  if (item.result) {
    const { size, originalWidth, originalHeight } = item.result;
    return (
      <span className="tabular">
        DNG {formatQuantity(byteParts(size))}
        {originalWidth !== null && originalHeight !== null && (
          <span className="muted">
            {' '}
            · original {originalWidth} × {originalHeight}
          </span>
        )}
      </span>
    );
  }
  return <span className="muted">—</span>;
}
