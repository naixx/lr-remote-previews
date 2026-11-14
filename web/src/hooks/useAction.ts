import { useCallback, useEffect, useRef, useState } from 'react';
import { toApiError, type ApiError } from '../api/errors';

export interface Action<A extends unknown[], T> {
  /**
   * Runs the request unless one is already running. Resolves with its result, or with
   * undefined when it failed (the error is then in `error`) or was skipped.
   */
  run: (...args: A) => Promise<T | undefined>;
  /** True while the request runs: the button that started it is disabled meanwhile. */
  pending: boolean;
  /** The error of the latest run, or null. */
  error: ApiError | null;
  /** Clears `error`. */
  reset: () => void;
}

/**
 * One request a button starts: a change on the server such as cancelling a job. Unlike data
 * loading it is never retried by itself. A result that arrives after the component is gone is
 * dropped.
 */
export function useAction<A extends unknown[], T>(
  perform: (...args: A) => Promise<T>,
): Action<A, T> {
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<ApiError | null>(null);
  const running = useRef(false);
  const mounted = useRef(true);

  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);

  const run = useCallback(
    async (...args: A): Promise<T | undefined> => {
      if (running.current) return undefined;
      running.current = true;
      setPending(true);
      setError(null);
      try {
        return await perform(...args);
      } catch (reason) {
        if (mounted.current) setError(toApiError(reason));
        return undefined;
      } finally {
        running.current = false;
        if (mounted.current) setPending(false);
      }
    },
    [perform],
  );

  const reset = useCallback(() => setError(null), []);

  return { run, pending, error, reset };
}
