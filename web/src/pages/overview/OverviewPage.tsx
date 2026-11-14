import { useCallback, useState } from 'react';
import { CLIENT_API_VERSION, type ServerInfo } from '../../api/info';
import type { ServerSettings } from '../../api/settings';
import { useApi } from '../../app/ApiContext';
import { links } from '../../app/router';
import { Card } from '../../components/Card';
import { ConnectionNote } from '../../components/ConnectionNote';
import { ErrorPanel } from '../../components/ErrorPanel';
import { PageHeader } from '../../components/PageHeader';
import { StatePanel } from '../../components/StatePanel';
import { StatusBadge } from '../../components/StatusBadge';
import { useApiResource } from '../../hooks/useApiResource';
import { usePolling, type Polled } from '../../hooks/usePolling';
import { formatCount } from '../../lib/format';
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

  return (
    <div className="page">
      <PageHeader title="Overview" lead="The preview server this dashboard is connected to." />
      {info.status === 'loading' ? (
        <StatePanel tone="neutral" busy title="Connecting to the server…" />
      ) : info.status === 'error' ? (
        <ErrorPanel error={info.error} onRetry={info.reload} />
      ) : (
        <OverviewGrid info={info.data} live={live} />
      )}
    </div>
  );
}

interface PausedOverride {
  /** The refresh the override was made on; a later one replaces it. */
  basis: LiveOverview;
  paused: boolean;
}

function OverviewGrid({ info, live }: { info: ServerInfo; live: Polled<LiveOverview> }) {
  const { data, error, refresh } = live;
  // What the server answered to Pause or Resume, shown until the refresh it starts has landed.
  const [override, setOverride] = useState<PausedOverride | null>(null);

  const onSettingsChanged = useCallback(
    (settings: ServerSettings) => {
      if (data) setOverride({ basis: data, paused: settings.paused });
      refresh();
    },
    [data, refresh],
  );

  const paused =
    data === null
      ? undefined
      : data.settings === null
        ? null
        : override?.basis === data
          ? override.paused
          : data.settings.paused;

  return (
    <div className="overview-grid">
      {data && error && <ConnectionNote error={error} updatedAt={live.updatedAt} />}
      <QueueCard
        status={data?.status ?? null}
        paused={paused}
        error={error}
        converterInstalled={info.converter.installed}
        onRetry={refresh}
        onSettingsChanged={onSettingsChanged}
      />
      {/* Without any data, the Queue card alone reports the error. */}
      {(data || !error) && <JobsCard jobs={data?.jobs ?? null} now={live.checkedAt ?? 0} />}
      <InfoDetails info={info} />
    </div>
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
              <span className="facts__note facts__note--warn">
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
      <p className="hint">
        <a href={links.converter()}>Run a self-test</a> to check that it works.
      </p>
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
