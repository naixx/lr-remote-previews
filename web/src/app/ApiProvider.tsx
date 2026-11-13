import { useMemo, useState, type ReactNode } from 'react';
import { createApiClient } from '../api/client';
import { clearToken, loadToken, saveToken } from '../api/token';
import { ApiContext, type ApiContextValue } from './ApiContext';

interface ApiProviderProps {
  children: ReactNode;
  /** fetch implementation for the client; tests pass a mock. */
  fetch?: typeof globalThis.fetch;
}

interface TokenState {
  token: string | null;
  persisted: boolean;
}

/** Owns the access token and the API client that every page uses. */
export function ApiProvider({ children, fetch }: ApiProviderProps) {
  const [auth, setAuth] = useState<TokenState>(() => ({ token: loadToken(), persisted: true }));

  const client = useMemo(() => createApiClient({ token: auth.token, fetch }), [auth.token, fetch]);

  const value = useMemo<ApiContextValue>(
    () => ({
      client,
      token: auth.token,
      tokenPersisted: auth.persisted,
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
    [client, auth],
  );

  return <ApiContext value={value}>{children}</ApiContext>;
}
