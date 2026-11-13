import { useCallback, useEffect, useState } from 'react';
import { toApiError, type ApiError } from '../api/errors';

export type ResourceState<T> =
  | { status: 'loading' }
  | { status: 'ready'; data: T }
  | { status: 'error'; error: ApiError };

export type Resource<T> = ResourceState<T> & {
  /** Runs the request again; the state goes back to loading until it settles. */
  reload: () => void;
};

interface Settled<T> {
  load: (signal: AbortSignal) => Promise<T>;
  attempt: number;
  state: ResourceState<T>;
}

const LOADING = { status: 'loading' } as const;

/**
 * Runs `load` and tracks its outcome. `load` must be stable between renders (wrap it in
 * useCallback); a new function, for example after the token changed, starts a new request.
 * The previous request is aborted and its late result ignored.
 */
export function useApiResource<T>(load: (signal: AbortSignal) => Promise<T>): Resource<T> {
  const [attempt, setAttempt] = useState(0);
  const [settled, setSettled] = useState<Settled<T> | null>(null);

  useEffect(() => {
    const controller = new AbortController();
    load(controller.signal).then(
      (data) => {
        if (!controller.signal.aborted) {
          setSettled({ load, attempt, state: { status: 'ready', data } });
        }
      },
      (error: unknown) => {
        if (!controller.signal.aborted) {
          setSettled({ load, attempt, state: { status: 'error', error: toApiError(error) } });
        }
      },
    );
    return () => controller.abort();
  }, [load, attempt]);

  const reload = useCallback(() => setAttempt((n) => n + 1), []);

  // A result belongs to one (load, attempt) pair; anything else means a request is in flight.
  const current = settled?.load === load && settled.attempt === attempt ? settled.state : LOADING;
  return { ...current, reload };
}
