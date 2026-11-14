import { useCallback, useLayoutEffect, useRef, useState } from 'react';
import { isMissingEndpoint } from '../../api/errors';
import type { LogLine } from '../../api/log';
import { useApi } from '../../app/ApiContext';
import { ConnectionNote } from '../../components/ConnectionNote';
import { ErrorPanel, OlderServerNote } from '../../components/ErrorPanel';
import { PageHeader } from '../../components/PageHeader';
import { StatePanel } from '../../components/StatePanel';
import { usePolling } from '../../hooks/usePolling';
import { formatCount, formatFullTime, formatLogTime, formatTimeOfDay } from '../../lib/format';
import { LOG_LIMIT, LOG_REFRESH_MS, levelOf } from './levels';
import './log.css';

function logInterval(): number {
  return LOG_REFRESH_MS;
}

/** How close to the end counts as «at the newest line», in pixels. */
const STICK_SLACK = 24;

export function LogPage() {
  const { client } = useApi();
  const [paused, setPaused] = useState(false);
  const load = useCallback((signal: AbortSignal) => client.getLog(LOG_LIMIT, signal), [client]);
  const log = usePolling(load, { enabled: !paused, interval: logInterval });

  return (
    <div className="page">
      <PageHeader
        title="Log"
        lead="The server's recent log lines, newest at the bottom. Requests to the server itself are not logged here."
      />
      {log.data ? (
        <div className="page-stack">
          {log.error && <ConnectionNote error={log.error} updatedAt={log.updatedAt} />}
          <div className="log-toolbar">
            <button
              type="button"
              className="button button--secondary"
              aria-pressed={paused}
              onClick={() => setPaused((value) => !value)}
            >
              {paused ? 'Resume updates' : 'Pause updates'}
            </button>
            <p className="log-toolbar__state" aria-live="polite">
              {paused
                ? 'Updates paused.'
                : `Updates every ${LOG_REFRESH_MS / 1000} s.`}
              {log.updatedAt !== null && (
                <span className="tabular"> Last read {formatTimeOfDay(log.updatedAt)}.</span>
              )}
            </p>
            <p className="log-toolbar__count tabular">
              {log.data.lines.length === 1 ? '1 line' : `${formatCount(log.data.lines.length)} lines`}
            </p>
          </div>
          <LogView lines={log.data.lines} />
        </div>
      ) : log.error ? (
        isMissingEndpoint(log.error) ? (
          <OlderServerNote feature="its log to the dashboard" />
        ) : (
          <ErrorPanel error={log.error} title="The log could not be loaded" onRetry={log.refresh} />
        )
      ) : (
        <StatePanel tone="neutral" busy title="Loading the log…" />
      )}
    </div>
  );
}

function LogView({ lines }: { lines: LogLine[] }) {
  const box = useRef<HTMLDivElement>(null);
  // Follow the newest line unless the person scrolled up to read something.
  const [following, setFollowing] = useState(true);

  useLayoutEffect(() => {
    const element = box.current;
    if (element && following) element.scrollTop = element.scrollHeight;
  }, [lines, following]);

  function handleScroll() {
    const element = box.current;
    if (!element) return;
    const atEnd = element.scrollHeight - element.scrollTop - element.clientHeight <= STICK_SLACK;
    if (atEnd !== following) setFollowing(atEnd);
  }

  return (
    <div className="log-frame">
      <div
        ref={box}
        className="log"
        role="region"
        aria-label="Server log"
        tabIndex={0}
        onScroll={handleScroll}
      >
        {lines.length === 0 ? (
          <p className="log__empty">The server has logged nothing since it started.</p>
        ) : (
          <ol className="log__lines">
            {lines.map((line, index) => (
              <LogRow key={`${index}-${line.time}`} line={line} />
            ))}
          </ol>
        )}
      </div>
      {!following && (
        <button
          type="button"
          className="button log-frame__jump"
          onClick={() => setFollowing(true)}
        >
          Jump to the newest line
        </button>
      )}
    </div>
  );
}

function LogRow({ line }: { line: LogLine }) {
  const level = levelOf(line.level);
  return (
    <li className={`log__line log__line--${level}`}>
      <time className="log__time" dateTime={line.time} title={formatFullTime(line.time)}>
        {formatLogTime(line.time)}
      </time>
      <span className="log__level">{line.level}</span>
      <span className="log__logger">{line.logger}</span>
      <span className="log__message">{line.message}</span>
    </li>
  );
}
