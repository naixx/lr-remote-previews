import { ApiError } from './errors';
import { parseServerInfo, type ServerInfo } from './info';
import { ShapeError } from './validate';

/**
 * Request paths are relative (no leading slash) so they resolve against the page URL. The
 * server serves the dashboard at its root, and a reverse proxy may mount it under a sub-path.
 */
export const API_PATHS = {
  info: 'api/v1/info',
} as const;

export interface ApiClientOptions {
  /** Access token sent as `Authorization: Bearer <token>`; omitted when empty or null. */
  token?: string | null;
  /** fetch implementation; defaults to the global one. Tests pass a mock. */
  fetch?: typeof globalThis.fetch;
}

export interface ApiClient {
  /** `GET /api/v1/info`: server name, version, converter state, roots, capabilities. */
  getInfo: (signal?: AbortSignal) => Promise<ServerInfo>;
}

/**
 * Creates a client bound to one token. When the token changes, create a new client.
 *
 * Every method either resolves with checked data or rejects with an ApiError. The one exception
 * is a request cancelled through its AbortSignal, which rejects with the original abort error.
 */
export function createApiClient(options: ApiClientOptions = {}): ApiClient {
  const token = options.token?.trim() ?? '';
  // Look the global up per call, so stubs installed after the client was created still apply.
  const doFetch: typeof globalThis.fetch =
    options.fetch ?? ((input, init) => globalThis.fetch(input, init));

  async function getJson<T>(
    path: string,
    parse: (data: unknown) => T,
    signal: AbortSignal | undefined,
  ): Promise<T> {
    const headers: Record<string, string> = { Accept: 'application/json' };
    if (token) headers.Authorization = `Bearer ${token}`;

    let response: Response;
    try {
      response = await doFetch(path, { headers, signal });
    } catch (error) {
      if (signal?.aborted) throw error;
      throw new ApiError('network', 'The server could not be reached.', { cause: error });
    }

    if (!response.ok) {
      const detail = await readDetail(response);
      if (response.status === 401) {
        throw new ApiError('unauthorized', 'The server needs a valid access token.', {
          status: 401,
          detail,
        });
      }
      throw new ApiError('http', `The server answered with HTTP ${response.status}.`, {
        status: response.status,
        detail,
      });
    }

    let body: unknown;
    try {
      body = await response.json();
    } catch (error) {
      if (signal?.aborted) throw error;
      throw new ApiError('bad-response', 'The server response is not valid JSON.', {
        status: response.status,
        cause: error,
      });
    }

    try {
      return parse(body);
    } catch (error) {
      if (!(error instanceof ShapeError)) throw error;
      throw new ApiError('bad-response', 'The server response has an unexpected shape.', {
        status: response.status,
        detail: error.message,
        cause: error,
      });
    }
  }

  return {
    getInfo: (signal) => getJson(API_PATHS.info, parseServerInfo, signal),
  };
}

/** Reads `{"detail": "..."}` from an error response; null when the body has no such text. */
async function readDetail(response: Response): Promise<string | null> {
  try {
    const body: unknown = await response.json();
    if (typeof body === 'object' && body !== null && 'detail' in body) {
      const { detail } = body;
      if (typeof detail === 'string' && detail.trim()) return detail;
    }
  } catch {
    // Not JSON: fall through.
  }
  return null;
}
