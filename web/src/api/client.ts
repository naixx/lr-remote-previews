import {
  parseBrowse,
  parseFolderQueued,
  type BrowseResult,
  type FolderQueued,
  type FolderRequest,
} from './browse';
import { parseSelfTest, type SelfTestFile, type SelfTestResult } from './converter';
import { ApiError } from './errors';
import { parseServerInfo, type ServerInfo } from './info';
import {
  parseItemPage,
  parseJobList,
  parseJobResponse,
  type ItemPage,
  type ItemState,
  type Job,
  type JobList,
  type JobState,
} from './jobs';
import { parseLog, type ServerLog } from './log';
import { parseSettings, type ServerSettings, type SettingsChange } from './settings';
import { parseServerStatus, type ServerStatus } from './status';
import { ShapeError } from './validate';

/**
 * Request paths are relative (no leading slash) so they resolve against the page URL. The
 * server serves the dashboard at its root, and a reverse proxy may mount it under a sub-path.
 */
export const API_PATHS = {
  info: 'api/v1/info',
  status: 'api/v1/status',
  jobs: 'api/v1/jobs',
  job: (id: number) => `api/v1/jobs/${id}`,
  jobItems: (id: number) => `api/v1/jobs/${id}/items`,
  jobRetry: (id: number) => `api/v1/jobs/${id}/retry`,
  settings: 'api/v1/settings',
  browse: 'api/v1/browse',
  folders: 'api/v1/folders',
  selfTest: 'api/v1/converter/selftest',
  log: 'api/v1/log',
} as const;

export interface JobsQuery {
  /** How many jobs to return, 1 to 200; the server's default is 50. */
  limit?: number;
  /** Only jobs in this state; all states when omitted. */
  state?: JobState;
}

export interface ItemsQuery {
  /** Only items whose seq is above this; the server's default is 0 (every item). */
  since?: number;
  /** 1 to 1000; the server's default is 500. */
  limit?: number;
  /** Only items in this state; all states when omitted. */
  state?: ItemState;
}

export interface ApiClientOptions {
  /** Access token sent as `Authorization: Bearer <token>`; omitted when empty or null. */
  token?: string | null;
  /** fetch implementation; defaults to the global one. Tests pass a mock. */
  fetch?: typeof globalThis.fetch;
  /** Called with the server's `detail` whenever a request is answered with 401. */
  onUnauthorized?: (detail: string | null) => void;
}

export interface ApiClient {
  /** `GET /api/v1/info`: server name, version, converter state, roots, capabilities. */
  getInfo: (signal?: AbortSignal) => Promise<ServerInfo>;
  /** `GET /api/v1/status`: state, queue, converter processes, rate, time left, cache. */
  getStatus: (signal?: AbortSignal) => Promise<ServerStatus>;
  /** `GET /api/v1/jobs`: jobs, newest first. */
  getJobs: (query?: JobsQuery, signal?: AbortSignal) => Promise<JobList>;
  /** `GET /api/v1/jobs/{id}`. */
  getJob: (id: number, signal?: AbortSignal) => Promise<Job>;
  /** `GET /api/v1/jobs/{id}/items`: the job and its items with seq above `since`. */
  getJobItems: (id: number, query?: ItemsQuery, signal?: AbortSignal) => Promise<ItemPage>;
  /** `DELETE /api/v1/jobs/{id}`: cancels the job; returns it as it is afterwards. */
  cancelJob: (id: number, signal?: AbortSignal) => Promise<Job>;
  /** `POST /api/v1/jobs/{id}/retry`: queues the failed items again. */
  retryJob: (id: number, signal?: AbortSignal) => Promise<Job>;
  /** `GET /api/v1/settings`. */
  getSettings: (signal?: AbortSignal) => Promise<ServerSettings>;
  /** `PATCH /api/v1/settings`: returns the settings after the change. */
  updateSettings: (change: SettingsChange, signal?: AbortSignal) => Promise<ServerSettings>;
  /** `GET /api/v1/browse`: one folder of a root; `path` empty for the root itself. */
  browse: (root: string, path: string, signal?: AbortSignal) => Promise<BrowseResult>;
  /** `POST /api/v1/folders`: queues the raw files of a folder. */
  queueFolder: (request: FolderRequest, signal?: AbortSignal) => Promise<FolderQueued>;
  /** `POST /api/v1/converter/selftest`, optionally converting one raw file. */
  runSelfTest: (file: SelfTestFile | null, signal?: AbortSignal) => Promise<SelfTestResult>;
  /** `GET /api/v1/log`: the newest `limit` lines, oldest first. */
  getLog: (limit?: number, signal?: AbortSignal) => Promise<ServerLog>;
}

type Method = 'GET' | 'POST' | 'PATCH' | 'DELETE';

interface RequestOptions {
  method?: Method;
  /** Sent as JSON. */
  body?: unknown;
  signal?: AbortSignal;
}

/**
 * Creates a client bound to one token. When the token changes, create a new client.
 *
 * Every method either resolves with checked data or rejects with an ApiError. The one exception
 * is a request cancelled through its AbortSignal, which rejects with the original abort error.
 */
export function createApiClient(options: ApiClientOptions = {}): ApiClient {
  const token = options.token?.trim() ?? '';
  const { onUnauthorized } = options;
  // Look the global up per call, so stubs installed after the client was created still apply.
  const doFetch: typeof globalThis.fetch =
    options.fetch ?? ((input, init) => globalThis.fetch(input, init));

  async function request<T>(
    path: string,
    parse: (data: unknown) => T,
    { method = 'GET', body, signal }: RequestOptions = {},
  ): Promise<T> {
    const headers: Record<string, string> = { Accept: 'application/json' };
    if (token) headers.Authorization = `Bearer ${token}`;
    const init: RequestInit = { method, headers, signal };
    if (body !== undefined) {
      headers['Content-Type'] = 'application/json';
      init.body = JSON.stringify(body);
    }

    let response: Response;
    try {
      response = await doFetch(path, init);
    } catch (error) {
      if (signal?.aborted) throw error;
      throw new ApiError('network', 'The server could not be reached.', { cause: error });
    }

    if (!response.ok) {
      const { detail, code } = await readErrorBody(response);
      if (response.status === 401) {
        onUnauthorized?.(detail);
        throw new ApiError('unauthorized', 'The server needs a valid access token.', {
          status: 401,
          detail,
          code,
        });
      }
      throw new ApiError('http', `The server answered with HTTP ${response.status}.`, {
        status: response.status,
        detail,
        code,
      });
    }

    let data: unknown;
    try {
      data = await response.json();
    } catch (error) {
      if (signal?.aborted) throw error;
      throw new ApiError('bad-response', 'The server response is not valid JSON.', {
        status: response.status,
        cause: error,
      });
    }

    try {
      return parse(data);
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
    getInfo: (signal) => request(API_PATHS.info, parseServerInfo, { signal }),
    getStatus: (signal) => request(API_PATHS.status, parseServerStatus, { signal }),
    getJobs: (query = {}, signal) =>
      request(withQuery(API_PATHS.jobs, { limit: query.limit, state: query.state }), parseJobList, {
        signal,
      }),
    getJob: (id, signal) => request(API_PATHS.job(id), parseJobResponse, { signal }),
    getJobItems: (id, query = {}, signal) =>
      request(
        withQuery(API_PATHS.jobItems(id), {
          since: query.since,
          limit: query.limit,
          state: query.state,
        }),
        parseItemPage,
        { signal },
      ),
    cancelJob: (id, signal) =>
      request(API_PATHS.job(id), parseJobResponse, { method: 'DELETE', signal }),
    retryJob: (id, signal) =>
      request(API_PATHS.jobRetry(id), parseJobResponse, { method: 'POST', signal }),
    getSettings: (signal) => request(API_PATHS.settings, parseSettings, { signal }),
    updateSettings: (change, signal) =>
      request(API_PATHS.settings, parseSettings, { method: 'PATCH', body: change, signal }),
    browse: (root, path, signal) =>
      request(withQuery(API_PATHS.browse, { root, path: path || undefined }), parseBrowse, {
        signal,
      }),
    queueFolder: (folder, signal) =>
      request(API_PATHS.folders, parseFolderQueued, { method: 'POST', body: folder, signal }),
    runSelfTest: (file, signal) =>
      request(API_PATHS.selfTest, parseSelfTest, {
        method: 'POST',
        body: file ?? undefined,
        signal,
      }),
    getLog: (limit, signal) =>
      request(withQuery(API_PATHS.log, { limit }), parseLog, { signal }),
  };
}

/** Appends the parameters that are set; keeps the path relative. */
function withQuery(path: string, params: Record<string, string | number | undefined>): string {
  const search = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value !== undefined) search.set(key, String(value));
  }
  const query = search.toString();
  return query ? `${path}?${query}` : path;
}

/**
 * Reads `{"detail": "...", "code": "..."}` from an error response; each is null when the body
 * does not have it.
 */
async function readErrorBody(
  response: Response,
): Promise<{ detail: string | null; code: string | null }> {
  try {
    const body: unknown = await response.json();
    if (typeof body === 'object' && body !== null) {
      const { detail, code } = body as Record<string, unknown>;
      return {
        detail: typeof detail === 'string' && detail.trim() ? detail : null,
        code: typeof code === 'string' && code ? code : null,
      };
    }
  } catch {
    // Not JSON: fall through.
  }
  return { detail: null, code: null };
}
