import type { ReactNode } from 'react';
import type { ApiError } from '../../api/errors';
import { isQueueBusy, type ServerStatus } from '../../api/status';
import { Card } from '../../components/Card';
import { StatusBadge } from '../../components/StatusBadge';
import { byteParts, formatCount, rateParts } from '../../lib/format';
import { IDLE_REFRESH_MS } from './live';

interface QueueCardProps {
  /** Null until the first status arrives. */
  status: ServerStatus | null;
  /** Set when no status has arrived because the requests fail. */
  error: ApiError | null;
  converterInstalled: boolean;
  onRetry: () => void;
}

export function QueueCard({ status, error, converterInstalled, onRetry }: QueueCardProps) {
  const badge = <QueueBadge status={status} converterInstalled={converterInstalled} />;
  return (
    <Card title="Queue" wide aside={badge}>
      {!converterInstalled && (
        <p className="callout callout--warn">
          Jobs cannot be built until Adobe DNG Converter is installed on the server. The DNG
          converter card below shows where the server looks for it.
        </p>
      )}
      {status ? (
        <QueueStats status={status} />
      ) : error ? (
        <LiveError error={error} onRetry={onRetry} />
      ) : (
        <p className="muted">Loading…</p>
      )}
    </Card>
  );
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
  return isQueueBusy(status) ? (
    <StatusBadge tone="info">Working</StatusBadge>
  ) : (
    <StatusBadge tone="neutral">Idle</StatusBadge>
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
