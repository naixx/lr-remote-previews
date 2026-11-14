import { useMemo, useState, type ReactNode } from 'react';
import { createApiClient } from '../api/client';
import { clearToken, loadToken, saveToken } from '../api/token';
import { ApiContext, type ApiContextValue } from './ApiContext';

interface ApiProviderProps {
  children: ReactNode;
  /** fetch implementation for the client; tests pass a mock. */
  fetch?: typeof globalThis.fetch;
}

/** One token as entered or loaded. A new object per entry, even for the same text. */
interface TokenState {
  token: string | null;
  persisted: boolean;
}

interface AuthFailure {
  /** The token entry the 401 answered. */
  entry: TokenState;
  detail: string | null;
}

/** Owns the access token and the API client that every page uses. */
export function ApiProvider({ children, fetch }: ApiProviderProps) {
  const [auth, setAuth] = useState<TokenState>(() => ({ token: loadToken(), persisted: true }));
  const [failure, setFailure] = useState<AuthFailure | null>(null);

  // A new client for every token entry, so entering the same token again retries everything.
  const client = useMemo(
    () =>
      createApiClient({
        token: auth.token,
        fetch,
        onUnauthorized: (detail) => setFailure({ entry: auth, detail }),
      }),
    [auth, fetch],
  );

  const value = useMemo<ApiContextValue>(
    () => ({
      client,
      token: auth.token,
      tokenPersisted: auth.persisted,
      authRequired: failure?.entry === auth ? { detail: failure.detail } : null,
      setToken: (token) => {
        const trimmed = token.trim();
        if (!trimmed) return;
        setAuth({ token: trimmed, persisted: saveToken(trimmed) });
      },
      forgetToken: () => {
        clearToken();
        setAuth({ token: null, persisted: true });
      },
    }),
    [client, auth, failure],
  );

  return <ApiContext value={value}>{children}</ApiContext>;
}
