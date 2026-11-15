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
  /**
   * When `load` changes (another page of a list, another filter), keep showing the data of the
   * previous `load` until the new one has answered, instead of starting from nothing. `stale`
   * is true meanwhile. Defaults to false.
   */
  keepPrevious?: boolean;
  /**
   * For a page that must not keep asking a server that has gone away: after a network failure
   * (no answer at all) the next tries wait these milliseconds, one entry per failure in a row,
   * and when they are used up polling gives up. It then requests nothing by itself, neither on a
   * timer nor when the page is shown again, until `refresh()`. Any answer, even an HTTP error,
   * starts the count again. Must be stable (a module-level constant). Without it a failed
   * refresh is retried at `interval`, however often it fails.
   */
  retryDelays?: readonly number[];
}

export interface Polled<T> {
  /** The latest data that arrived; kept when a later refresh fails. */
  data: T | null;
  /** True while `data` came from a previous `load` (only with `keepPrevious`). */
  stale: boolean;
  /** The error of the latest refresh, or null when it succeeded or none has settled yet. */
  error: ApiError | null;
  /** `Date.now()` when `data` arrived. */
  updatedAt: number | null;
  /** `Date.now()` when the latest refresh settled, successful or not. */
  checkedAt: number | null;
  /** True once the tries of `retryDelays` are used up; only `refresh()` starts again. */
  gaveUp: boolean;
  /** Starts a refresh now, cancelling one in flight; after giving up, the tries start afresh. */
  refresh: () => void;
}

type Loader<T> = (signal: AbortSignal) => Promise<T>;

interface Snapshot<T> {
  /** The loader whose latest refresh this describes. */
  load: Loader<T>;
  data: T | null;
  /** The loader `data` came from; another one only with `keepPrevious`. */
  dataLoad: Loader<T> | null;
  error: ApiError | null;
  updatedAt: number | null;
  checkedAt: number | null;
  gaveUp: boolean;
}

const isHidden = () => document.visibilityState === 'hidden';

/**
 * Calls `load` again and again. The next request starts `interval(data)` ms after the previous
 * one settled, so two never overlap. Polling pauses while the page is hidden and refreshes at
 * once when it becomes visible. A 401 stops it: retrying cannot succeed until the token changes,
 * and a new token means a new `load`. With `retryDelays`, network failures in a row stop it too.
 *
 * `load` must be stable between renders (wrap it in useCallback); a new function starts over
 * without the old data, as useApiResource does, unless `keepPrevious` is set.
 */
export function usePolling<T>(load: Loader<T>, options: PollingOptions<T>): Polled<T> {
  const { enabled = true, interval, keepPrevious = false, retryDelays } = options;
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
    /** Network failures in a row, for `retryDelays`. */
    let failures = 0;

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
          failures = 0;
          latest.current = { load, data };
          const now = Date.now();
          setSnapshot({
            load,
            data,
            dataLoad: load,
            error: null,
            updatedAt: now,
            checkedAt: now,
            gaveUp: false,
          });
          schedule(interval(data));
        },
        (reason: unknown) => {
          if (disposed) return;
          inFlight = null;
          const error = toApiError(reason);
          failures = error.kind === 'network' ? failures + 1 : 0;
          const retryDelay = failures > 0 ? retryDelays?.[failures - 1] : undefined;
          const gaveUp = retryDelays !== undefined && failures > 0 && retryDelay === undefined;
          const now = Date.now();
          setSnapshot((previous) => {
            if (previous?.load === load) return { ...previous, error, checkedAt: now, gaveUp };
            if (keepPrevious && previous) {
              return { ...previous, load, error, checkedAt: now, gaveUp };
            }
            return {
              load,
              data: null,
              dataLoad: null,
              error,
              updatedAt: null,
              checkedAt: now,
              gaveUp,
            };
          });
          if (error.kind === 'unauthorized' || gaveUp) {
            stopped = true;
            return;
          }
          schedule(retryDelay ?? interval(latestData()));
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
  }, [load, enabled, interval, keepPrevious, retryDelays, restarts]);

  const refresh = useCallback(() => {
    setRestarts((n) => n + 1);
    // Trying again: no longer given up, also while the first new request is in flight.
    setSnapshot((previous) => (previous?.gaveUp ? { ...previous, gaveUp: false } : previous));
  }, []);

  if (snapshot?.load === load) {
    return {
      data: snapshot.data,
      stale: snapshot.dataLoad !== null && snapshot.dataLoad !== load,
      error: snapshot.error,
      updatedAt: snapshot.updatedAt,
      checkedAt: snapshot.checkedAt,
      gaveUp: snapshot.gaveUp,
      refresh,
    };
  }
  // A new loader that has not answered yet.
  const previous = keepPrevious ? snapshot : null;
  return {
    data: previous?.data ?? null,
    stale: previous?.data != null,
    error: null,
    updatedAt: previous?.updatedAt ?? null,
    checkedAt: previous?.checkedAt ?? null,
    gaveUp: false,
    refresh,
  };
}
