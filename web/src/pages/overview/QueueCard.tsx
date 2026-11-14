import type { ReactNode } from 'react';
import type { ApiError } from '../../api/errors';
import type { ServerSettings } from '../../api/settings';
import { isQueueBusy, type ServerState, type ServerStatus } from '../../api/status';
import { links } from '../../app/router';
import { Card } from '../../components/Card';
import { PauseButton } from '../../components/PauseButton';
import { StatusBadge, type Tone } from '../../components/StatusBadge';
import {
  byteParts,
  formatCount,
  formatTemperature,
  formatTimeLeft,
  rateParts,
} from '../../lib/format';
import { IDLE_REFRESH_MS } from './live';

interface QueueCardProps {
  /** Null until the first status arrives. */
  status: ServerStatus | null;
  /**
   * The `paused` setting for the pause button; null when the server has no settings (older
   * than 0.4), undefined until the first answer.
   */
  paused: boolean | null | undefined;
  /** Set when no status has arrived because the requests fail. */
  error: ApiError | null;
  converterInstalled: boolean;
  onRetry: () => void;
  onSettingsChanged: (settings: ServerSettings) => void;
}

export function QueueCard({
  status,
  paused,
  error,
  converterInstalled,
  onRetry,
  onSettingsChanged,
}: QueueCardProps) {
  const badge = <QueueBadge status={status} converterInstalled={converterInstalled} />;
  return (
    <Card title="Queue" wide aside={badge}>
      {!converterInstalled && (
        <p className="callout callout--warn">
          Jobs cannot be built until Adobe DNG Converter is installed on the server. The{' '}
          <a href={links.converter()}>Converter page</a> shows where the server looks for it.
        </p>
      )}
      {status ? (
        <>
          <QueueState status={status} paused={paused} onSettingsChanged={onSettingsChanged} />
          <QueueStats status={status} />
        </>
      ) : error ? (
        <LiveError error={error} onRetry={onRetry} />
      ) : (
        <p className="muted">Loading…</p>
      )}
    </Card>
  );
}

const STATE_WORDS: Record<ServerState, { label: string; tone: Tone }> = {
  running: { label: 'Running', tone: 'info' },
  idle: { label: 'Idle', tone: 'neutral' },
  paused: { label: 'Paused', tone: 'warn' },
  waiting: { label: 'Waiting for working hours', tone: 'neutral' },
};

/** The state as the server reports it; an older server without `state` gets it from the queue. */
function stateOf(status: ServerStatus): ServerState {
  return status.state ?? (isQueueBusy(status) ? 'running' : 'idle');
}

function QueueBadge({
  status,
  converterInstalled,
}: {
  status: ServerStatus | null;
  converterInstalled: boolean;
}) {
  if (!converterInstalled) return <StatusBadge tone="warn">Converter missing</StatusBadge>;
  if (!status) return null;
  const { label, tone } = STATE_WORDS[stateOf(status)];
  return <StatusBadge tone={tone}>{label}</StatusBadge>;
}

function stateSentence(state: ServerState, status: ServerStatus): string {
  switch (state) {
    case 'running':
      return status.etaSeconds === null
        ? 'Building. The time left is not known yet.'
        : `Building, ${formatTimeLeft(status.etaSeconds)}.`;
    case 'idle':
      return 'Nothing is queued.';
    case 'paused':
      return 'Paused: no new wave of conversions starts until you resume.';
    case 'waiting':
      return 'Work is queued; building starts when the working hours begin.';
  }
}

function QueueState({
  status,
  paused,
  onSettingsChanged,
}: {
  status: ServerStatus;
  paused: boolean | null | undefined;
  onSettingsChanged: (settings: ServerSettings) => void;
}) {
  const state = stateOf(status);
  const details = [
    state !== 'idle' ? `${formatCount(status.queue.queued + status.queue.building)} left` : null,
    status.cpuTemperature !== null ? `CPU ${formatTemperature(status.cpuTemperature)}` : null,
  ].filter((part): part is string => part !== null);

  return (
    <div className="queue-state">
      <div className="queue-state__text">
        <p className="queue-state__headline">{stateSentence(state, status)}</p>
        {details.length > 0 && <p className="queue-state__detail">{details.join(' · ')}</p>}
      </div>
      <div className="queue-state__control">
        {paused === null ? (
          <p className="hint">
            This server is older than the dashboard and cannot be paused from here.
          </p>
        ) : paused === undefined ? null : (
          <PauseButton paused={paused} onChanged={onSettingsChanged} />
        )}
      </div>
    </div>
  );
}

function QueueStats({ status }: { status: ServerStatus }) {
  const { queue, workers, rate, today, cache } = status;
  const speed = rate.perMinute > 0 ? rateParts(rate.perMinute) : null;
  const size = byteParts(cache.bytes);

  return (
    <dl className="stats">
      <Stat label="Queued" value={formatCount(queue.queued)} />
      <Stat label="Building" value={formatCount(queue.building)} />
      <Stat
        label="Processes busy"
        value={formatCount(workers.busy)}
        unit={`of ${formatCount(workers.configured)}`}
      />
      <Stat
        label="Rate"
        value={speed ? speed.value : 'Idle'}
        unit={speed?.unit}
        note={`over the last ${formatCount(rate.windowSeconds)} s`}
      />
      <Stat
        label="Today"
        value={formatCount(today.built)}
        unit="built"
        note={
          today.failed > 0 ? (
            <span className="text-bad">{formatCount(today.failed)} failed</span>
          ) : (
            'none failed'
          )
        }
      />
      <Stat
        label="Cache"
        value={size.value}
        unit={size.unit}
        note={`${formatCount(cache.entries)} ${cache.entries === 1 ? 'file' : 'files'}`}
      />
    </dl>
  );
}

interface StatProps {
  label: string;
  value: string;
  unit?: string;
  note?: ReactNode;
}

function Stat({ label, value, unit, note }: StatProps) {
  return (
    <div className="stat">
      <dt className="stat__label">{label}</dt>
      <dd className="stat__figure">
        <span className="stat__value">{value}</span>
        {unit && <span className="stat__unit"> {unit}</span>}
      </dd>
      {note && <dd className="stat__note">{note}</dd>}
    </div>
  );
}

function LiveError({ error, onRetry }: { error: ApiError; onRetry: () => void }) {
  const hint =
    error.kind === 'bad-response'
      ? ' The server and this dashboard may be different versions.'
      : error.kind === 'http' && error.status === 404
        ? ' The server may be older than this dashboard.'
        : '';
  return (
    <div className="inline-error" role="alert">
      <p className="inline-error__title">Queue and jobs could not be loaded</p>
      <p>
        {error.message}
        {hint} The dashboard tries again every {IDLE_REFRESH_MS / 1000} s.
      </p>
      {error.detail && <pre className="error-detail">{error.detail}</pre>}
      <div>
        <button type="button" className="button button--quiet" onClick={onRetry}>
          Retry now
        </button>
      </div>
    </div>
  );
}
