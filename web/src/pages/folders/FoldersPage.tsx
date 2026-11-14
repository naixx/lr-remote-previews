import { useCallback, useId, useState } from 'react';
import {
  MAX_FILES_PER_FOLDER_REQUEST,
  MAX_LISTED_FOLDERS,
  type BrowseResult,
  type FolderQueued,
} from '../../api/browse';
import { isMissingEndpoint, type ApiError } from '../../api/errors';
import type { ServerInfo } from '../../api/info';
import type { JobPriority } from '../../api/jobs';
import { useApi } from '../../app/ApiContext';
import { links } from '../../app/router';
import { ActionError } from '../../components/ActionError';
import { Card } from '../../components/Card';
import { ConfirmPanel } from '../../components/ConfirmPanel';
import { ConnectionNote } from '../../components/ConnectionNote';
import { ErrorPanel, OlderServerNote } from '../../components/ErrorPanel';
import { PageHeader } from '../../components/PageHeader';
import { StatePanel } from '../../components/StatePanel';
import { StatusBadge } from '../../components/StatusBadge';
import { useAction } from '../../hooks/useAction';
import { useApiResource } from '../../hooks/useApiResource';
import { usePolling } from '../../hooks/usePolling';
import { explainFolderError } from '../../lib/codes';
import { formatCount, plural } from '../../lib/format';
import { BROWSE_REFRESH_MS, FOLDERS_STEP } from './limits';
import './folders.css';

interface FoldersPageProps {
  /** null lists the roots. */
  root: string | null;
  /** Relative to the root; `""` for the root itself. */
  path: string;
}

const FEATURE = 'a folder browser';

export function FoldersPage({ root, path }: FoldersPageProps) {
  const { client } = useApi();
  const loadInfo = useCallback((signal: AbortSignal) => client.getInfo(signal), [client]);
  const info = useApiResource(loadInfo);
  const rootInfo =
    info.status === 'ready' && root !== null
      ? (info.data.roots.find((entry) => entry.id === root) ?? null)
      : null;
  const folderName = root === null ? null : path ? path.slice(path.lastIndexOf('/') + 1) : (rootInfo?.label ?? root);

  return (
    <div className="page">
      <PageHeader
        title="Folders"
        documentTitle={folderName ? `${folderName} · Folders` : 'Folders'}
        lead="Browse the folders of originals on the server and queue a folder for smart previews."
      />
      {info.status === 'loading' ? (
        <StatePanel tone="neutral" busy title="Connecting to the server…" />
      ) : info.status === 'error' ? (
        <ErrorPanel error={info.error} onRetry={info.reload} />
      ) : root === null ? (
        <RootList info={info.data} />
      ) : (
        <FolderView info={info.data} root={root} rootLabel={rootInfo?.label ?? root} path={path} />
      )}
    </div>
  );
}

function RootList({ info }: { info: ServerInfo }) {
  if (info.roots.length === 0) {
    return (
      <StatePanel tone="neutral" title="No roots configured">
        <p>
          The server has no folders of originals to browse. Roots are set in the server&apos;s
          configuration; the project&apos;s README describes how.
        </p>
      </StatePanel>
    );
  }
  return (
    <Card title="Roots" wide>
      <ul className="roots folder-roots" aria-label="Roots">
        {info.roots.map((root) => (
          <li className="roots__item" key={root.id}>
            <span className="roots__name">
              {root.available ? (
                <a className="roots__label folder-link" href={links.folder(root.id)}>
                  {root.label}
                </a>
              ) : (
                <span className="roots__label">{root.label}</span>
              )}
              <code className="roots__id">{root.id}</code>
            </span>
            {root.available ? (
              <StatusBadge tone="ok">Available</StatusBadge>
            ) : (
              <StatusBadge tone="bad">Unavailable</StatusBadge>
            )}
          </li>
        ))}
      </ul>
      {info.roots.some((root) => !root.available) && (
        <p className="hint">
          An unavailable root is missing on the server right now, for example an unmounted volume.
          It can be browsed again once it is back.
        </p>
      )}
    </Card>
  );
}

interface FolderViewProps {
  info: ServerInfo;
  root: string;
  rootLabel: string;
  path: string;
}

function browseInterval(): number {
  return BROWSE_REFRESH_MS;
}

function FolderView({ info, root, rootLabel, path }: FolderViewProps) {
  const { client } = useApi();
  const load = useCallback(
    (signal: AbortSignal) => client.browse(root, path, signal),
    [client, root, path],
  );
  const browse = usePolling(load, { interval: browseInterval });

  return (
    <div className="page-stack">
      <Breadcrumb root={root} rootLabel={rootLabel} path={path} />
      {browse.data ? (
        <>
          {browse.error && <ConnectionNote error={browse.error} updatedAt={browse.updatedAt} />}
          {!info.converter.installed && (
            <p className="callout callout--warn">
              Adobe DNG Converter is not installed on the server, so only files whose DNG is
              already in the cache can be queued. See the <a href={links.converter()}>Converter</a>{' '}
              page.
            </p>
          )}
          <FolderCard
            folder={browse.data}
            name={path ? path.slice(path.lastIndexOf('/') + 1) : rootLabel}
            maxItemsPerJob={info.capabilities.maxItemsPerJob}
            onQueued={browse.refresh}
          />
          <SubfoldersCard folder={browse.data} />
        </>
      ) : browse.error ? (
        <BrowseError error={browse.error} root={root} path={path} onRetry={browse.refresh} />
      ) : (
        <StatePanel tone="neutral" busy title="Reading the folder…" />
      )}
    </div>
  );
}

function Breadcrumb({ root, rootLabel, path }: { root: string; rootLabel: string; path: string }) {
  const segments = path.split('/').filter(Boolean);
  const crumbs = [
    { label: rootLabel, href: links.folder(root) },
    ...segments.map((segment, index) => ({
      label: segment,
      href: links.folder(root, segments.slice(0, index + 1).join('/')),
    })),
  ];
  return (
    <nav aria-label="Breadcrumb" className="breadcrumb">
      <ol className="breadcrumb__list">
        <li className="breadcrumb__item">
          <a href={links.folder(null)}>Roots</a>
        </li>
        {crumbs.map((crumb, index) => (
          <li className="breadcrumb__item" key={crumb.href}>
            {index === crumbs.length - 1 ? (
              <span aria-current="page">{crumb.label}</span>
            ) : (
              <a href={crumb.href}>{crumb.label}</a>
            )}
          </li>
        ))}
      </ol>
    </nav>
  );
}

function BrowseError({
  error,
  root,
  path,
  onRetry,
}: {
  error: ApiError;
  root: string;
  path: string;
  onRetry: () => void;
}) {
  if (isMissingEndpoint(error)) return <OlderServerNote feature={FEATURE} />;
  const known = error.kind === 'http' ? explainFolderError(error.code) : null;
  if (!known) {
    return <ErrorPanel error={error} title="The folder could not be read" onRetry={onRetry} />;
  }
  const parent = path.includes('/') ? path.slice(0, path.lastIndexOf('/')) : '';
  const back =
    path && error.code !== 'unknown_root' && error.code !== 'root_unavailable' ? (
      <a className="button button--secondary" href={links.folder(root, parent)}>
        Up one level
      </a>
    ) : (
      <a className="button button--secondary" href={links.folder(null)}>
        Back to the roots
      </a>
    );
  return (
    <StatePanel
      tone="bad"
      title={known.title}
      actions={
        <>
          <button type="button" className="button" onClick={onRetry}>
            Try again
          </button>
          {back}
        </>
      }
    >
      <p>{known.text}</p>
      {error.detail && <p className="muted">Server message: {error.detail}</p>}
    </StatePanel>
  );
}

interface FolderCardProps {
  folder: BrowseResult;
  name: string;
  maxItemsPerJob: number | null;
  onQueued: () => void;
}

function FolderCard({ folder, name, maxItemsPerJob, onQueued }: FolderCardProps) {
  const empty = folder.rawFiles === 0 && folder.otherFiles === 0 && folder.dirs.length === 0;
  return (
    <Card title="This folder" wide>
      {empty ? (
        <p className="muted">This folder is empty: no sub-folders and no files.</p>
      ) : (
        <dl className="facts facts--small folder-facts">
          <div className="facts__item">
            <dt>Raw files</dt>
            <dd className="tabular">{formatCount(folder.rawFiles)}</dd>
          </div>
          <div className="facts__item">
            <dt>Already built</dt>
            <dd className="tabular">
              {formatCount(folder.builtFiles)}
              {folder.rawFiles > 0 && (
                <span className="facts__note">
                  {folder.builtFiles === folder.rawFiles
                    ? 'all of them'
                    : `${formatCount(folder.rawFiles - folder.builtFiles)} still to build`}
                </span>
              )}
            </dd>
          </div>
          <div className="facts__item">
            <dt>Other files</dt>
            <dd className="tabular">{formatCount(folder.otherFiles)}</dd>
          </div>
          <div className="facts__item">
            <dt>Sub-folders</dt>
            <dd className="tabular">
              {formatCount(folder.dirs.length)}
              {folder.truncated && '+'}
            </dd>
          </div>
        </dl>
      )}
      <p className="hint">Counted directly in this folder; sub-folders are not included.</p>
      <QueueFolder folder={folder} name={name} maxItemsPerJob={maxItemsPerJob} onQueued={onQueued} />
    </Card>
  );
}

interface QueuedResult {
  queued: FolderQueued;
  recursive: boolean;
  priority: JobPriority;
}

const PRIORITY_CHOICES: { value: JobPriority; label: string }[] = [
  { value: 'normal', label: 'Normal' },
  { value: 'background', label: 'Background' },
];

function QueueFolder({ folder, name, maxItemsPerJob, onQueued }: FolderCardProps) {
  const { client } = useApi();
  const checkboxId = useId();
  const priorityName = useId();
  const priorityLabelId = useId();
  const priorityHintId = useId();
  const [recursive, setRecursive] = useState(false);
  const [priority, setPriority] = useState<JobPriority>('normal');
  const [confirming, setConfirming] = useState(false);
  const [result, setResult] = useState<QueuedResult | null>(null);
  const queue = useAction(
    useCallback(
      (withSubfolders: boolean, chosen: JobPriority) =>
        client.queueFolder({
          root: folder.root,
          path: folder.path,
          recursive: withSubfolders,
          // Normal is the default; leaving it out keeps the request what older servers know.
          ...(chosen === 'background' ? { priority: chosen } : {}),
        }),
      [client, folder.root, folder.path],
    ),
  );

  const nothingHere = folder.rawFiles === 0 && !recursive;
  const hasSubfolders = folder.dirs.length > 0;

  async function confirm() {
    const queued = await queue.run(recursive, priority);
    if (!queued) return;
    setConfirming(false);
    setResult({ queued, recursive, priority });
    onQueued();
  }

  return (
    <div className="queue-folder">
      <div className="queue-folder__controls">
        <label className="check" htmlFor={checkboxId}>
          <input
            id={checkboxId}
            type="checkbox"
            checked={recursive}
            disabled={confirming}
            onChange={(event) => {
              setRecursive(event.target.checked);
              queue.reset();
            }}
          />
          <span>Include sub-folders</span>
        </label>
        <div
          className="queue-priority"
          role="radiogroup"
          aria-labelledby={priorityLabelId}
          aria-describedby={priorityHintId}
        >
          <span className="queue-priority__label" id={priorityLabelId}>
            Priority
          </span>
          {PRIORITY_CHOICES.map((choice) => (
            <label className="check" key={choice.value}>
              <input
                type="radio"
                name={priorityName}
                value={choice.value}
                checked={priority === choice.value}
                disabled={confirming}
                onChange={() => {
                  setPriority(choice.value);
                  queue.reset();
                }}
              />
              <span>{choice.label}</span>
            </label>
          ))}
        </div>
        {!confirming && (
          <button
            type="button"
            className="button"
            disabled={nothingHere}
            onClick={() => {
              setResult(null);
              queue.reset();
              setConfirming(true);
            }}
          >
            Queue this folder…
          </button>
        )}
      </div>
      <p className="hint" id={priorityHintId}>
        Background jobs are built only when no normal job is waiting, so photos sent from
        Lightroom go first.
      </p>
      {nothingHere && (
        <p className="hint">
          No raw files directly in this folder.
          {hasSubfolders && ' Tick «Include sub-folders» to queue the files below it.'}
        </p>
      )}
      {confirming && (
        <ConfirmPanel
          title={`Queue «${name}»?`}
          confirmLabel="Queue"
          cancelLabel="Back"
          pending={queue.pending}
          onConfirm={() => void confirm()}
          onCancel={() => {
            queue.reset();
            setConfirming(false);
          }}
        >
          <QueueSummary folder={folder} recursive={recursive} maxItemsPerJob={maxItemsPerJob} />
          <p>
            {priority === 'background'
              ? 'At background priority: built only when no normal job is waiting.'
              : 'At normal priority: built in turn with the other normal jobs, oldest first, so jobs sent later wait for it.'}
          </p>
        </ConfirmPanel>
      )}
      <ActionError
        error={queue.error}
        action="The folder was not queued"
        explain={(error) => explainFolderError(error.code)?.text ?? null}
      />
      {result && <QueueResult {...result} />}
    </div>
  );
}

function QueueSummary({
  folder,
  recursive,
  maxItemsPerJob,
}: {
  folder: BrowseResult;
  recursive: boolean;
  maxItemsPerJob: number | null;
}) {
  const toBuild = folder.rawFiles - folder.builtFiles;
  if (recursive) {
    return (
      <>
        <p>
          The server queues every raw file in this folder and in all its sub-folders, however deep.
          It counts them while it queues: {plural(folder.rawFiles, 'raw file is', 'raw files are')}{' '}
          directly here, the sub-folders may hold many more.
        </p>
        <p>
          Files whose DNG is already in the cache are ready at once; the converter builds the
          others, which can keep the server busy for a long time.
          {maxItemsPerJob !== null &&
            ` More than ${formatCount(maxItemsPerJob)} files are split into several jobs.`}{' '}
          More than 50,000 files are refused.
        </p>
      </>
    );
  }
  const jobs = maxItemsPerJob ? Math.ceil(folder.rawFiles / maxItemsPerJob) : 1;
  if (folder.rawFiles > MAX_FILES_PER_FOLDER_REQUEST) {
    return (
      <p>
        This folder holds {plural(folder.rawFiles, 'raw file', 'raw files')}, more than the{' '}
        {formatCount(MAX_FILES_PER_FOLDER_REQUEST)} the server takes at once, so it will most
        likely refuse.
      </p>
    );
  }
  return (
    <>
      <p>
        The server queues the {plural(folder.rawFiles, 'raw file', 'raw files')} directly in this
        folder, not those in sub-folders.
      </p>
      <p>
        {folder.builtFiles > 0 && `${formatCount(folder.builtFiles)} already have their DNG and are ready at once. `}
        {toBuild > 0
          ? `The converter builds ${toBuild === folder.rawFiles ? 'all' : 'the other'} ${plural(toBuild, 'file', 'files')}.`
          : 'Nothing needs to be built.'}
        {jobs > 1 && ` They go into ${formatCount(jobs)} jobs of up to ${formatCount(maxItemsPerJob ?? 0)} files.`}
      </p>
    </>
  );
}

function QueueResult({ queued: result, recursive, priority }: QueuedResult) {
  // A server older than 0.5 ignores the priority and sends none back.
  const priorityIgnored =
    priority === 'background' &&
    result.jobs.length > 0 &&
    result.jobs.every((job) => job.priority === null);
  if (result.files === 0) {
    return (
      <p className="callout" role="status">
        No raw files were found{recursive ? ' in this folder or its sub-folders' : ' in this folder'}
        ; nothing was queued.
      </p>
    );
  }
  return (
    <div className="callout callout--ok" role="status">
      <p>
        Queued {plural(result.files, 'raw file', 'raw files')}
        {result.alreadyBuilt > 0 && `, ${formatCount(result.alreadyBuilt)} of them already built`}
        {priority === 'background' && !priorityIgnored && ', at background priority'}.
      </p>
      {result.jobs.length > 0 && (
        <p>
          {result.jobs.length === 1 ? 'Job: ' : 'Jobs: '}
          {result.jobs.map((job, index) => (
            <span key={job.id}>
              {index > 0 && ', '}
              <a href={links.job(job.id)}>Job {job.id}</a>
              {result.jobs.length > 1 && ` (${plural(job.counts.total, 'file', 'files')})`}
            </span>
          ))}
        </p>
      )}
      {priorityIgnored && (
        <p>
          This server is older than the dashboard and has no priorities, so the files are queued
          at normal priority.
        </p>
      )}
    </div>
  );
}

function SubfoldersCard({ folder }: { folder: BrowseResult }) {
  const filterId = useId();
  const [filter, setFilter] = useState('');
  const [limit, setLimit] = useState(FOLDERS_STEP);
  const needle = filter.trim().toLowerCase();
  const matching = needle
    ? folder.dirs.filter((dir) => dir.name.toLowerCase().includes(needle))
    : folder.dirs;
  const shown = matching.slice(0, limit);

  return (
    <Card
      title="Sub-folders"
      wide
      aside={
        folder.dirs.length > 0 && (
          <span className="card__meta tabular">
            {plural(folder.dirs.length, 'folder', 'folders')}
            {folder.truncated && ' (list cut)'}
          </span>
        )
      }
    >
      {folder.parent !== null && (
        <a className="folder-up" href={links.folder(folder.root, folder.parent)}>
          Up one level
        </a>
      )}
      {folder.truncated && (
        <p className="callout callout--warn">
          This folder has more than {formatCount(MAX_LISTED_FOLDERS)} sub-folders; the server
          listed only the first {formatCount(MAX_LISTED_FOLDERS)}.
        </p>
      )}
      {folder.dirs.length === 0 ? (
        <p className="muted">No sub-folders.</p>
      ) : (
        <>
          {folder.dirs.length > 20 && (
            <div className="folder-filter">
              <label className="field-label" htmlFor={filterId}>
                Filter by name
              </label>
              <input
                id={filterId}
                className="input"
                type="search"
                value={filter}
                onChange={(event) => {
                  setFilter(event.target.value);
                  setLimit(FOLDERS_STEP);
                }}
              />
            </div>
          )}
          {matching.length === 0 ? (
            <p className="muted">No sub-folder name contains «{filter.trim()}».</p>
          ) : (
            <ul className="folder-list" aria-label="Sub-folders">
              {shown.map((dir) => (
                <li key={dir.path}>
                  <a className="folder-link" href={links.folder(folder.root, dir.path)}>
                    <span className="folder-icon" aria-hidden="true" />
                    {dir.name}
                  </a>
                </li>
              ))}
            </ul>
          )}
          {matching.length > shown.length && (
            <div className="actions">
              <button
                type="button"
                className="button button--secondary"
                onClick={() => setLimit((value) => value + FOLDERS_STEP)}
              >
                Show {formatCount(Math.min(FOLDERS_STEP, matching.length - shown.length))} more
              </button>
              <span className="hint tabular">
                {formatCount(shown.length)} of {formatCount(matching.length)} shown
              </span>
            </div>
          )}
        </>
      )}
    </Card>
  );
}
