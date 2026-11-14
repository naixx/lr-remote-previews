import { createContext, useContext } from 'react';
import type { ApiClient } from '../api/client';

export interface ApiContextValue {
  /** Client bound to the current token; replaced whenever the token is set or forgotten. */
  client: ApiClient;
  /** The token in use, or null when none is set. */
  token: string | null;
  /** False when the browser refused to store the token; it then lasts until the page closes. */
  tokenPersisted: boolean;
  /**
   * Set once any request with the current token was answered with 401: the layout then asks for
   * the token instead of showing the page. `detail` is the server's explanation, if any.
   */
  authRequired: { detail: string | null } | null;
  setToken: (token: string) => void;
  forgetToken: () => void;
}

export const ApiContext = createContext<ApiContextValue | null>(null);

export function useApi(): ApiContextValue {
  const value = useContext(ApiContext);
  if (!value) throw new Error('useApi() must be called inside <ApiProvider>.');
  return value;
}
