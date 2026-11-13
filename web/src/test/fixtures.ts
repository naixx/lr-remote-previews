import { vi } from 'vitest';
import { API_PATHS } from '../api/client';

/** A valid `GET /api/v1/info` body, matching the server contract. */
export function sampleInfo() {
  return {
    name: 'LR Remote Previews',
    version: '0.2.0',
    api: 1,
    auth: 'token',
    converter: {
      installed: false,
      path: 'C:\\Program Files\\Adobe\\Adobe DNG Converter\\Adobe DNG Converter.exe',
      version: null,
    },
    roots: [
      { id: 'archive', label: 'Archive', available: true },
      { id: 'offsite', label: 'Offsite copy', available: false },
    ],
    capabilities: { extensions: ['.arw', '.cr2'], previewLongEdge: 2560, maxItemsPerJob: 5000 },
  };
}

/** An info body with the converter installed, as a server that can build has. */
export function installedInfo() {
  const info = sampleInfo();
  return { ...info, converter: { ...info.converter, installed: true, version: '17.5' } };
}

/** A valid `GET /api/v1/status` body while a job is being built (the contract example). */
export function busyStatus() {
  return {
    queue: { queued: 300, building: 8 },
    workers: { configured: 4, busy: 4 },
    rate: { perMinute: 172.5, windowSeconds: 60 },
    today: { built: 1234, failed: 2 },
    cache: { entries: 5321, bytes: 2890000000 },
    jobs: { active: 1 },
  };
}

/** A valid status body with nothing to do. */
export function idleStatus() {
  return {
    queue: { queued: 0, building: 0 },
    workers: { configured: 4, busy: 0 },
    rate: { perMinute: 0, windowSeconds: 60 },
    today: { built: 1542, failed: 0 },
    cache: { entries: 5629, bytes: 3021000000 },
    jobs: { active: 0 },
  };
}

type JobOverrides = Partial<Omit<ReturnType<typeof baseJob>, 'counts'>> & {
  counts?: Partial<ReturnType<typeof baseJob>['counts']>;
};

function baseJob() {
  return {
    id: 7,
    label: 'Lightroom selection' as string | null,
    client: 'lr-plugin/0.2.0' as string | null,
    state: 'active',
    created: '2026-11-14T09:30:00Z',
    finished: null as string | null,
    seq: 58,
    counts: { total: 500, queued: 300, building: 8, ready: 190, failed: 2, rejected: 0, cancelled: 0 },
  };
}

/** A valid job object (the contract example), with fields replaced as given. */
export function sampleJob(overrides: JobOverrides = {}) {
  const job = baseJob();
  return { ...job, ...overrides, counts: { ...job.counts, ...overrides.counts } };
}

/** A valid `GET /api/v1/jobs` body: one active job, one finished, one cancelled. */
export function sampleJobs() {
  return {
    jobs: [
      sampleJob(),
      sampleJob({
        id: 6,
        label: null,
        client: 'lr-plugin/0.2.0',
        state: 'done',
        created: '2026-11-14T08:05:00Z',
        finished: '2026-11-14T08:20:00Z',
        seq: 120,
        counts: { total: 120, queued: 0, building: 0, ready: 117, failed: 1, rejected: 2 },
      }),
      sampleJob({
        id: 5,
        label: 'Shoot 2026-06-20',
        client: null,
        state: 'cancelled',
        created: '2026-11-13T18:00:00Z',
        finished: '2026-11-13T18:02:00Z',
        seq: 40,
        counts: { total: 80, queued: 0, building: 0, ready: 40, failed: 0, cancelled: 40 },
      }),
    ],
  };
}

export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

export function mockFetch() {
  return vi.fn<typeof globalThis.fetch>();
}

/** The Authorization header of the n-th call to a fetch mock, or null. */
export function authHeaderOf(fetchMock: ReturnType<typeof mockFetch>, call = 0): string | null {
  const init = fetchMock.mock.calls[call]?.[1];
  return new Headers(init?.headers).get('Authorization');
}

export type Endpoint = keyof typeof API_PATHS;

type Reply =
  | { kind: 'json'; body: unknown; status: number }
  | { kind: 'network' }
  /** Never answers; rejects when the request is aborted, as fetch does. */
  | { kind: 'hang' };

function urlString(input: RequestInfo | URL): string {
  return typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
}

function endpointOf(input: RequestInfo | URL): Endpoint | null {
  const path = urlString(input).split('?')[0];
  const match = Object.entries(API_PATHS).find(([, value]) => value === path);
  return match ? (match[0] as Endpoint) : null;
}

/**
 * A fetch mock that answers each endpoint with what the test last set for it. Every answer is
 * a fresh Response, so the same reply can be served any number of times.
 */
export function fakeServer(bodies: Partial<Record<Endpoint, unknown>>) {
  const replies = new Map<Endpoint, Reply>();
  for (const [endpoint, body] of Object.entries(bodies)) {
    replies.set(endpoint as Endpoint, { kind: 'json', body, status: 200 });
  }

  const fetch = mockFetch().mockImplementation((input, init) => {
    const endpoint = endpointOf(input);
    const reply = endpoint ? replies.get(endpoint) : undefined;
    if (!reply) return Promise.resolve(jsonResponse({ detail: 'Not Found' }, 404));
    if (reply.kind === 'network') return Promise.reject(new TypeError('Failed to fetch'));
    if (reply.kind === 'hang') {
      return new Promise<Response>((_, reject) => {
        init?.signal?.addEventListener('abort', () => {
          reject(new DOMException('The operation was aborted.', 'AbortError'));
        });
      });
    }
    return Promise.resolve(jsonResponse(reply.body, reply.status));
  });

  const callsOf = (endpoint: Endpoint) =>
    fetch.mock.calls.filter(([input]) => endpointOf(input) === endpoint);

  return {
    fetch,
    /** Answer `endpoint` with this JSON body and status from now on. */
    reply(endpoint: Endpoint, body: unknown, status = 200) {
      replies.set(endpoint, { kind: 'json', body, status });
    },
    /** Make requests to `endpoint` fail as an unreachable server does. */
    failNetwork(endpoint: Endpoint) {
      replies.set(endpoint, { kind: 'network' });
    },
    /** Leave requests to `endpoint` unanswered. */
    hang(endpoint: Endpoint) {
      replies.set(endpoint, { kind: 'hang' });
    },
    /** How many requests went to `endpoint`. */
    calls(endpoint: Endpoint): number {
      return callsOf(endpoint).length;
    },
    /** The URL of the n-th request to `endpoint`. */
    urlOf(endpoint: Endpoint, call = 0): string | undefined {
      const input = callsOf(endpoint)[call]?.[0];
      return input === undefined ? undefined : urlString(input);
    },
    /** The Authorization header of the n-th request to `endpoint` (negative counts from the end). */
    authOf(endpoint: Endpoint, call = 0): string | null {
      const init = callsOf(endpoint).at(call)?.[1];
      return new Headers(init?.headers).get('Authorization');
    },
  };
}

export type FakeServer = ReturnType<typeof fakeServer>;
