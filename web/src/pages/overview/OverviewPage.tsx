import { useCallback } from 'react';
import type { ApiError } from '../../api/errors';
import { CLIENT_API_VERSION, type ServerInfo } from '../../api/info';
import { useApi } from '../../app/ApiContext';
import { Card } from '../../components/Card';
import { StatePanel } from '../../components/StatePanel';
import { StatusBadge } from '../../components/StatusBadge';
import { TokenForm } from '../../components/TokenForm';
import { useApiResource } from '../../hooks/useApiResource';
import { usePolling, type Polled } from '../../hooks/usePolling';
import { formatCount, formatTimeOfDay } from '../../lib/format';
import { JobsCard } from './JobsCard';
import { loadLiveOverview, refreshInterval, type LiveOverview } from './live';
import { QueueCard } from './QueueCard';
import './overview.css';

export function OverviewPage() {
  const { client } = useApi();
  const loadInfo = useCallback((signal: AbortSignal) => client.getInfo(signal), [client]);
  const info = useApiResource(loadInfo);

  // Queue and jobs are polled once the info has arrived: until then the page has nothing to put
  // them next to, and an info error (or a token prompt) already says what is wrong.
  const loadLive = useCallback((signal: AbortSignal) => loadLiveOverview(client, signal), [client]);
  const live = usePolling(loadLive, {
    enabled: info.status === 'ready',
    interval: refreshInterval,
  });

  // A token rejected while polling (revoked on the server) asks for the token, as at start.
  const tokenError =
    info.status === 'error' && info.error.kind === 'unauthorized'
      ? info.error
      : live.error?.kind === 'unauthorized'
        ? live.error
        : null;

  return (
    <div className="page">
      <header className="page-header">
        <h1 className="page-title">Overview</h1>
        <p className="page-lead">The preview server this dashboard is connected to.</p>
      </header>

      {tokenError ? (
        <TokenForm detail={tokenError.detail} />
      ) : info.status === 'loading' ? (
        <StatePanel tone="neutral" busy title="Connecting to the server…" />
      ) : info.status === 'error' ? (
        <InfoError error={info.error} onRetry={info.reload} />
      ) : (
        <OverviewGrid info={info.data} live={live} />
      )}
    </div>
  );
}

function OverviewGrid({ info, live }: { info: ServerInfo; live: Polled<LiveOverview> }) {
  const { data, error } = live;
  return (
    <div className="overview-grid">
      {data && error && <ConnectionNote error={error} updatedAt={live.updatedAt} />}
      <QueueCard
        status={data?.status ?? null}
        error={error}
        converterInstalled={info.converter.installed}
        onRetry={live.refresh}
      />
      {/* Without any data, the Queue card alone reports the error. */}
      {(data || !error) && <JobsCard jobs={data?.jobs ?? null} now={live.checkedAt ?? 0} />}
      <InfoDetails info={info} />
    </div>
  );
}

/** Shown over data that is still on screen while refreshing it fails. */
function ConnectionNote({ error, updatedAt }: { error: ApiError; updatedAt: number | null }) {
  return (
    <p className="connection-note" role="status">
      <span className="connection-note__dot" aria-hidden="true" />
      <span>
        {error.kind === 'network'
          ? 'Connection lost, retrying…'
          : `Could not refresh: ${error.message} Retrying…`}
        {updatedAt !== null && (
          <span className="connection-note__since">
            {' '}
            Showing data from {formatTimeOfDay(updatedAt)}.
          </span>
        )}
      </span>
    </p>
  );
}

function InfoError({ error, onRetry }: { error: ApiError; onRetry: () => void }) {
  if (error.kind === 'unauthorized') return <TokenForm detail={error.detail} />;

  const retry = (
    <button type="button" className="button" onClick={onRetry}>
      Retry
    </button>
  );

  if (error.kind === 'network') {
    return (
      <StatePanel tone="bad" title="Server unreachable" actions={retry}>
        <p>
          The dashboard got no answer from the LR Remote Previews server. Check that the server is
          running and that this browser can reach it.
        </p>
      </StatePanel>
    );
  }

  const isShape = error.kind === 'bad-response';
  return (
    <StatePanel tone="bad" title={isShape ? 'Unexpected response' : 'Server error'} actions={retry}>
      <p>
        {error.message}
        {isShape && ' The server and this dashboard may be different versions.'}
      </p>
      {error.detail && <pre className="error-detail">{error.detail}</pre>}
    </StatePanel>
  );
}

function InfoDetails({ info }: { info: ServerInfo }) {
  return (
    <>
      <ServerCard info={info} />
      <ConverterCard converter={info.converter} />
      <RootsCard roots={info.roots} />
      <FormatsCard capabilities={info.capabilities} />
    </>
  );
}

function ServerCard({ info }: { info: ServerInfo }) {
  return (
    <Card title="Server" wide>
      <dl className="facts">
        <div className="facts__item">
          <dt>Name</dt>
          <dd>{info.name}</dd>
        </div>
        <div className="facts__item">
          <dt>Version</dt>
          <dd>{info.version}</dd>
        </div>
        <div className="facts__item">
          <dt>API version</dt>
          <dd>
            {info.api}
            {info.api !== CLIENT_API_VERSION && (
              <span className="facts__note">
                This dashboard was built for API {CLIENT_API_VERSION}.
              </span>
            )}
          </dd>
        </div>
        <div className="facts__item">
          <dt>Access</dt>
          <dd>{info.auth === 'token' ? 'Token required' : 'Open, no token'}</dd>
        </div>
      </dl>
    </Card>
  );
}

function ConverterCard({ converter }: { converter: ServerInfo['converter'] }) {
  return (
    <Card
      title="DNG converter"
      aside={
        converter.installed ? (
          <StatusBadge tone="ok">Installed</StatusBadge>
        ) : (
          <StatusBadge tone="warn">Not installed</StatusBadge>
        )
      }
    >
      <dl className="stack">
        <div>
          <dt className="stack__label">{converter.installed ? 'Path' : 'Expected path'}</dt>
          <dd>
            <code className="path">{converter.path}</code>
          </dd>
        </div>
        {converter.installed && (
          <div>
            <dt className="stack__label">Version</dt>
            <dd>{converter.version ?? 'Unknown'}</dd>
          </div>
        )}
      </dl>
      {!converter.installed && (
        <p className="hint">
          Adobe DNG Converter is not part of LR Remote Previews and does not come with it. Install
          it on the server yourself; <code>docs/converter.md</code> explains how.
        </p>
      )}
    </Card>
  );
}

function RootsCard({ roots }: { roots: ServerInfo['roots'] }) {
  const available = roots.filter((root) => root.available).length;
  return (
    <Card
      title="Library roots"
      aside={
        roots.length > 0 && (
          <span className="card__meta">
            {available} of {roots.length} available
          </span>
        )
      }
    >
      {roots.length === 0 ? (
        <p className="muted">No library roots are configured on the server.</p>
      ) : (
        <ul className="roots">
          {roots.map((root) => (
            <li className="roots__item" key={root.id}>
              <span className="roots__name">
                <span className="roots__label">{root.label}</span>
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
      )}
    </Card>
  );
}

function FormatsCard({ capabilities }: { capabilities: ServerInfo['capabilities'] }) {
  return (
    <Card title="Raw formats">
      {capabilities.extensions.length === 0 ? (
        <p className="muted">The server lists no supported raw formats.</p>
      ) : (
        <ul className="chips" aria-label="Supported raw file extensions">
          {capabilities.extensions.map((extension) => (
            <li className="chip" key={extension}>
              {extension}
            </li>
          ))}
        </ul>
      )}
      <p className="hint">
        Smart previews are built at {capabilities.previewLongEdge} px on the long edge.
        {capabilities.maxItemsPerJob !== null &&
          ` One job can hold up to ${formatCount(capabilities.maxItemsPerJob)} photos.`}
      </p>
    </Card>
  );
}
