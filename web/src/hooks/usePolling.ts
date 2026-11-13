import { useCallback, useEffect, useRef, useState } from 'react';
import { toApiError, type ApiError } from '../api/errors';

export interface PollingOptions<T> {
  /** Nothing is requested while false. Defaults to true. */
  enabled?: boolean;
  /**
   * Milliseconds to wait after a refresh settles before the next one starts, given the latest
   * data that arrived (null before the first). Must be stable: a module-level function or one
   * wrapped in useCallback.
   */
  interval: (data: T | null) => number;
}

export interface Polled<T> {
  /** The latest data that arrived; kept when a later refresh fails. */
  data: T | null;
  /** The error of the latest refresh, or null when it succeeded or none has settled yet. */
  error: ApiError | null;
  /** `Date.now()` when `data` arrived. */
  updatedAt: number | null;
  /** `Date.now()` when the latest refresh settled, successful or not. */
  checkedAt: number | null;
  /** Starts a refresh now, cancelling one in flight. */
  refresh: () => void;
}

type Loader<T> = (signal: AbortSignal) => Promise<T>;

interface Snapshot<T> {
  load: Loader<T>;
  data: T | null;
  error: ApiError | null;
  updatedAt: number | null;
  checkedAt: number | null;
}

const isHidden = () => document.visibilityState === 'hidden';

/**
 * Calls `load` again and again. The next request starts `interval(data)` ms after the previous
 * one settled, so two never overlap. Polling pauses while the page is hidden and refreshes at
 * once when it becomes visible. A 401 stops it: retrying cannot succeed until the token changes,
 * and a new token means a new `load`.
 *
 * `load` must be stable between renders (wrap it in useCallback); a new function starts over
 * without the old data, as useApiResource does.
 */
export function usePolling<T>(load: Loader<T>, options: PollingOptions<T>): Polled<T> {
  const { enabled = true, interval } = options;
  const [restarts, setRestarts] = useState(0);
  const [snapshot, setSnapshot] = useState<Snapshot<T> | null>(null);
  // The latest data, readable by a restarted effect so its first interval is the right one.
  const latest = useRef<{ load: Loader<T>; data: T } | null>(null);

  useEffect(() => {
    if (!enabled) return;

    let disposed = false;
    let stopped = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let inFlight: AbortController | null = null;

    const latestData = () => (latest.current?.load === load ? latest.current.data : null);

    const cancelTimer = () => {
      clearTimeout(timer);
      timer = undefined;
    };

    const schedule = (delay: number) => {
      cancelTimer();
      if (disposed || stopped || isHidden()) return;
      timer = setTimeout(refresh, delay);
    };

    function refresh() {
      cancelTimer();
      if (disposed || stopped || inFlight || isHidden()) return;
      const controller = new AbortController();
      inFlight = controller;

      load(controller.signal).then(
        (data) => {
          if (disposed) return;
          inFlight = null;
          latest.current = { load, data };
          const now = Date.now();
          setSnapshot({ load, data, error: null, updatedAt: now, checkedAt: now });
          schedule(interval(data));
        },
        (reason: unknown) => {
          if (disposed) return;
          inFlight = null;
          const error = toApiError(reason);
          const now = Date.now();
          setSnapshot((previous) =>
            previous?.load === load
              ? { ...previous, error, checkedAt: now }
              : { load, data: null, error, updatedAt: null, checkedAt: now },
          );
          if (error.kind === 'unauthorized') {
            stopped = true;
            return;
          }
          schedule(interval(latestData()));
        },
      );
    }

    const onVisibilityChange = () => {
      if (isHidden()) cancelTimer();
      else refresh();
    };

    document.addEventListener('visibilitychange', onVisibilityChange);
    refresh();

    return () => {
      disposed = true;
      cancelTimer();
      inFlight?.abort();
      document.removeEventListener('visibilitychange', onVisibilityChange);
    };
  }, [load, enabled, interval, restarts]);

  const refresh = useCallback(() => setRestarts((n) => n + 1), []);

  const current = snapshot?.load === load ? snapshot : null;
  return {
    data: current?.data ?? null,
    error: current?.error ?? null,
    updatedAt: current?.updatedAt ?? null,
    checkedAt: current?.checkedAt ?? null,
    refresh,
  };
}
