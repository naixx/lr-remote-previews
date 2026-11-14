import { vi } from 'vitest';

/** A valid `GET /api/v1/info` body, matching the server contract. */
export function sampleInfo() {
  return {
    name: 'LR Remote Previews',
    version: '0.4.0',
    api: 1,
    auth: 'token',
    converter: {
      installed: false,
      path: 'C:\\Program Files\\Adobe\\Adobe DNG Converter\\Adobe DNG Converter.exe',
      version: null as string | null,
    },
    roots: [
      { id: 'archive', label: 'Archive', available: true },
      { id: 'offsite', label: 'Offsite copy', available: false },
    ],
    capabilities: {
      extensions: ['.arw', '.cr2'],
      previewLongEdge: 2560,
      maxItemsPerJob: 5000,
      jobRetentionDays: 30,
    },
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
    state: 'running',
    queue: { queued: 300, building: 8 },
    workers: { configured: 4, busy: 4 },
    rate: { perMinute: 172.5, windowSeconds: 60 },
    etaSeconds: 104 as number | null,
    today: { built: 1234, failed: 2 },
    cache: { entries: 5321, bytes: 2890000000 },
    jobs: { active: 1 },
    cpuTemperature: 67.5 as number | null,
  };
}

/** A valid status body with nothing to do. */
export function idleStatus() {
  return {
    state: 'idle',
    queue: { queued: 0, building: 0 },
    workers: { configured: 4, busy: 0 },
    rate: { perMinute: 0, windowSeconds: 60 },
    etaSeconds: null as number | null,
    today: { built: 1542, failed: 0 },
    cache: { entries: 5629, bytes: 3021000000 },
    jobs: { active: 0 },
    cpuTemperature: null as number | null,
  };
}

/** A status body as a server before 0.4 sends it: no state, time left or temperature. */
export function legacyStatus() {
  const { state, etaSeconds, cpuTemperature, ...rest } = busyStatus();
  void state;
  void etaSeconds;
  void cpuTemperature;
  return rest;
}

type JobOverrides = Partial<Omit<ReturnType<typeof baseJob>, 'counts'>> & {
  counts?: Partial<ReturnType<typeof baseJob>['counts']>;
};

function baseJob() {
  return {
    id: 7,
    label: 'Lightroom selection' as string | null,
    client: 'lr-plugin/0.2.0' as string | null,
    clientId: 'c1f0a6e2-7d0b-4c55-9d0e-3f6a1b2c4d5e' as string | null,
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
        clientId: null,
        state: 'cancelled',
        created: '2026-11-13T18:00:00Z',
        finished: '2026-11-13T18:02:00Z',
        seq: 40,
        counts: { total: 80, queued: 0, building: 0, ready: 40, failed: 0, cancelled: 40 },
      }),
    ],
  };
}

interface ResultBody {
  key: string;
  size: number;
  sha256: string;
  originalName: string | null;
  originalWidth: number | null;
  originalHeight: number | null;
}

/** The `result` of a ready item (the contract example), with fields replaced as given. */
export function sampleResult(overrides: Partial<ResultBody> = {}): ResultBody {
  return {
    key: '5d41402abc4b2a76b9719d911017c5925d41402abc4b2a76b9719d911017c592',
    size: 359310,
    sha256: '9f2c9f2c9f2c9f2c9f2c9f2c9f2c9f2c9f2c9f2c9f2c9f2c9f2c9f2c9f2c9f2c',
    originalName: 'IMG_0001.ARW',
    originalWidth: 6000,
    originalHeight: 4000,
    ...overrides,
  };
}

type ItemOverrides = Partial<ReturnType<typeof baseItem>>;

function baseItem() {
  return {
    id: 4211,
    ref: '17',
    root: 'archive',
    path: '2026/2026.06.20 - shoot/IMG_0001.ARW',
    state: 'ready',
    seq: 5,
    error: null as { code: string; message: string } | null,
    result: sampleResult() as ResultBody | null,
  };
}

/** A valid item object (the contract example), with fields replaced as given. */
export function sampleItem(overrides: ItemOverrides = {}) {
  return { ...baseItem(), ...overrides };
}

/** A failed item of job 7. */
export function failedItem(overrides: ItemOverrides = {}) {
  return sampleItem({
    id: 4212,
    ref: '18',
    path: '2026/2026.06.20 - shoot/IMG_0002.ARW',
    state: 'failed',
    seq: 9,
    error: { code: 'converter_failed', message: 'The converter exited with code 1.' },
    result: null,
    ...overrides,
  });
}

/** A rejected item of job 7. */
export function rejectedItem(overrides: ItemOverrides = {}) {
  return sampleItem({
    id: 4213,
    ref: '19',
    path: '2026/2026.06.20 - shoot/notes.txt',
    state: 'rejected',
    seq: 3,
    error: { code: 'unsupported_format', message: 'Not a camera raw file.' },
    result: null,
    ...overrides,
  });
}

/** `n` items with ids and seqs counting up from `firstSeq`, for paging. */
export function itemRun(n: number, firstSeq: number, state = 'queued') {
  return Array.from({ length: n }, (_, index) =>
    sampleItem({
      id: 5000 + firstSeq + index,
      ref: String(firstSeq + index),
      path: `2026/batch/IMG_${String(firstSeq + index).padStart(4, '0')}.ARW`,
      state,
      seq: firstSeq + index,
      result: null,
    }),
  );
}

/** A valid `GET /api/v1/jobs/7/items` body. */
export function sampleItemPage(
  items: unknown[] = [rejectedItem(), sampleItem(), failedItem()],
  more = false,
  job: unknown = sampleJob(),
) {
  return { job, items, more };
}

type SettingsOverrides = Partial<ReturnType<typeof baseSettings>>;

function baseSettings() {
  return {
    workers: 'auto' as 'auto' | number,
    effectiveWorkers: 4,
    batchSize: 8,
    paused: false,
    workingHours: { enabled: false, from: '22:00', to: '07:00' },
  };
}

/** A valid `GET /api/v1/settings` body (the contract example). */
export function sampleSettings(overrides: SettingsOverrides = {}) {
  return { ...baseSettings(), ...overrides };
}

type BrowseOverrides = Partial<ReturnType<typeof baseBrowse>>;

function baseBrowse() {
  return {
    root: 'archive',
    path: '2026',
    parent: '' as string | null,
    dirs: [
      { name: '2026.06.20 - shoot', path: '2026/2026.06.20 - shoot' },
      { name: '2026.07.04 - trip', path: '2026/2026.07.04 - trip' },
    ],
    rawFiles: 0,
    builtFiles: 0,
    otherFiles: 12,
    truncated: false,
  };
}

/** A valid `GET /api/v1/browse?root=archive&path=2026` body (the contract example). */
export function sampleBrowse(overrides: BrowseOverrides = {}) {
  return { ...baseBrowse(), ...overrides };
}

/** The browse body of a folder with raw files and no sub-folders. */
export function shootBrowse(overrides: BrowseOverrides = {}) {
  return sampleBrowse({
    path: '2026/2026.06.20 - shoot',
    parent: '2026',
    dirs: [],
    rawFiles: 384,
    builtFiles: 120,
    otherFiles: 2,
    ...overrides,
  });
}

/** A valid answer to `POST /api/v1/folders`. */
export function sampleFolderQueued() {
  return {
    files: 384,
    alreadyBuilt: 120,
    jobs: [
      sampleJob({
        id: 12,
        label: '2026/2026.06.20 - shoot',
        client: 'dashboard',
        clientId: null,
        seq: 384,
        counts: { total: 384, queued: 264, building: 0, ready: 120, failed: 0 },
      }),
    ],
  };
}

/** A passed self-test with a conversion (the contract example). */
export function passedSelfTest() {
  return {
    ok: true,
    steps: [
      {
        name: 'installed',
        ok: true,
        detail:
          'C:\\Program Files\\Adobe\\Adobe DNG Converter\\Adobe DNG Converter.exe, version 17.2',
      },
      { name: 'display', ok: true, detail: 'Xvfb on :99' },
      { name: 'warm-up', ok: true, detail: 'not needed' },
      {
        name: 'conversion',
        ok: true,
        detail: 'IMG_0001.ARW → 359310 bytes in 2.1 s, original name and size recorded',
      },
    ],
  };
}

/** A self-test that failed at the warm-up. */
export function failedSelfTest() {
  return {
    ok: false,
    steps: [
      { name: 'installed', ok: true, detail: 'C:\\...\\Adobe DNG Converter.exe, version 17.2' },
      { name: 'display', ok: true, detail: 'Xvfb on :99' },
      {
        name: 'warm-up',
        ok: false,
        detail: 'The converter exited with code 3.\nwine: could not load kernel32.dll',
      },
    ],
  };
}

/** A valid `GET /api/v1/log` body. */
export function sampleLog() {
  return {
    lines: [
      {
        time: '2026-11-14T09:30:00Z',
        level: 'INFO',
        logger: 'lrrp.scheduler',
        message: 'wave: 32 file(s) in 4 process(es)',
      },
      {
        time: '2026-11-14T09:30:05Z',
        level: 'WARNING',
        logger: 'lrrp.runner',
        message: 'batch 3 failed, retrying file by file',
      },
      {
        time: '2026-11-14T09:30:09Z',
        level: 'ERROR',
        logger: 'lrrp.runner',
        message: 'IMG_0002.ARW: converter exited with code 1',
      },
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

/** The endpoints of the protocol, by method and path, as the fake server tells them apart. */
const ROUTES = [
  { endpoint: 'info', method: 'GET', path: /^api\/v1\/info$/ },
  { endpoint: 'status', method: 'GET', path: /^api\/v1\/status$/ },
  { endpoint: 'jobs', method: 'GET', path: /^api\/v1\/jobs$/ },
  { endpoint: 'job', method: 'GET', path: /^api\/v1\/jobs\/\d+$/ },
  { endpoint: 'cancelJob', method: 'DELETE', path: /^api\/v1\/jobs\/\d+$/ },
  { endpoint: 'jobItems', method: 'GET', path: /^api\/v1\/jobs\/\d+\/items$/ },
  { endpoint: 'retryJob', method: 'POST', path: /^api\/v1\/jobs\/\d+\/retry$/ },
  { endpoint: 'settings', method: 'GET', path: /^api\/v1\/settings$/ },
  { endpoint: 'updateSettings', method: 'PATCH', path: /^api\/v1\/settings$/ },
  { endpoint: 'browse', method: 'GET', path: /^api\/v1\/browse$/ },
  { endpoint: 'queueFolder', method: 'POST', path: /^api\/v1\/folders$/ },
  { endpoint: 'selfTest', method: 'POST', path: /^api\/v1\/converter\/selftest$/ },
  { endpoint: 'log', method: 'GET', path: /^api\/v1\/log$/ },
] as const;

export type Endpoint = (typeof ROUTES)[number]['endpoint'];

/** A request as a handler sees it. */
export interface FakeRequest {
  url: string;
  method: string;
  query: URLSearchParams;
  /** The JSON body, parsed; undefined without one. */
  body: unknown;
}

type Reply =
  | { kind: 'json'; body: unknown; status: number }
  | { kind: 'network' }
  /** Never answers; rejects when the request is aborted, as fetch does. */
  | { kind: 'hang' }
  /** Answers each request from what it asked. */
  | { kind: 'handler'; handle: (request: FakeRequest) => { body: unknown; status?: number } };

function urlString(input: RequestInfo | URL): string {
  return typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
}

function methodOf(init: RequestInit | undefined): string {
  return (init?.method ?? 'GET').toUpperCase();
}

function endpointOf(input: RequestInfo | URL, init: RequestInit | undefined): Endpoint | null {
  const path = urlString(input).split('?')[0] ?? '';
  const method = methodOf(init);
  return ROUTES.find((route) => route.method === method && route.path.test(path))?.endpoint ?? null;
}

function bodyOf(init: RequestInit | undefined): unknown {
  return typeof init?.body === 'string' ? (JSON.parse(init.body) as unknown) : undefined;
}

function abortable(signal: AbortSignal | null | undefined): Promise<never> {
  return new Promise<never>((_, reject) => {
    signal?.addEventListener('abort', () => {
      reject(new DOMException('The operation was aborted.', 'AbortError'));
    });
  });
}

/**
 * A fetch mock that answers each endpoint with what the test last set for it; an endpoint
 * without an answer gets the 404 an older server gives for an unknown path. Every answer is a
 * fresh Response, so the same reply can be served any number of times.
 */
export function fakeServer(bodies: Partial<Record<Endpoint, unknown>>) {
  const replies = new Map<Endpoint, Reply>();
  const gates = new Map<Endpoint, Promise<void>>();
  for (const [endpoint, body] of Object.entries(bodies)) {
    replies.set(endpoint as Endpoint, { kind: 'json', body, status: 200 });
  }

  function answer(endpoint: Endpoint | null, request: FakeRequest, signal?: AbortSignal | null) {
    const reply = endpoint ? replies.get(endpoint) : undefined;
    if (!reply) return Promise.resolve(jsonResponse({ detail: 'Not Found' }, 404));
    switch (reply.kind) {
      case 'network':
        return Promise.reject(new TypeError('Failed to fetch'));
      case 'hang':
        return abortable(signal);
      case 'handler': {
        const { body, status = 200 } = reply.handle(request);
        return Promise.resolve(jsonResponse(body, status));
      }
      case 'json':
        return Promise.resolve(jsonResponse(reply.body, reply.status));
    }
  }

  const fetch = mockFetch().mockImplementation((input, init) => {
    const endpoint = endpointOf(input, init);
    const url = urlString(input);
    const request: FakeRequest = {
      url,
      method: methodOf(init),
      query: new URLSearchParams(url.split('?')[1] ?? ''),
      body: bodyOf(init),
    };
    const gate = endpoint ? gates.get(endpoint) : undefined;
    if (gate) {
      return Promise.race([
        gate.then(() => answer(endpoint, request, init?.signal)),
        abortable(init?.signal),
      ]);
    }
    return answer(endpoint, request, init?.signal);
  });

  const callsOf = (endpoint: Endpoint) =>
    fetch.mock.calls.filter(([input, init]) => endpointOf(input, init) === endpoint);

  return {
    fetch,
    /** Answer `endpoint` with this JSON body and status from now on. */
    reply(endpoint: Endpoint, body: unknown, status = 200) {
      replies.set(endpoint, { kind: 'json', body, status });
    },
    /** Answer `endpoint` from each request (its query and body) from now on. */
    handle(
      endpoint: Endpoint,
      handle: (request: FakeRequest) => { body: unknown; status?: number },
    ) {
      replies.set(endpoint, { kind: 'handler', handle });
    },
    /** Make requests to `endpoint` fail as an unreachable server does. */
    failNetwork(endpoint: Endpoint) {
      replies.set(endpoint, { kind: 'network' });
    },
    /** Leave requests to `endpoint` unanswered. */
    hang(endpoint: Endpoint) {
      replies.set(endpoint, { kind: 'hang' });
    },
    /** Answer nothing for `endpoint` until `release()`; then the reply set at that time. */
    hold(endpoint: Endpoint) {
      let release = () => {};
      gates.set(
        endpoint,
        new Promise<void>((resolve) => {
          release = () => {
            gates.delete(endpoint);
            resolve();
          };
        }),
      );
      return { release: () => release() };
    },
    /** How many requests went to `endpoint`. */
    calls(endpoint: Endpoint): number {
      return callsOf(endpoint).length;
    },
    /** The URL of the n-th request to `endpoint` (negative counts from the end). */
    urlOf(endpoint: Endpoint, call = 0): string | undefined {
      const input = callsOf(endpoint).at(call)?.[0];
      return input === undefined ? undefined : urlString(input);
    },
    /** The query of the n-th request to `endpoint` (negative counts from the end). */
    queryOf(endpoint: Endpoint, call = 0): URLSearchParams {
      const input = callsOf(endpoint).at(call)?.[0];
      return new URLSearchParams(input === undefined ? '' : (urlString(input).split('?')[1] ?? ''));
    },
    /** The parsed JSON body of the n-th request to `endpoint` (negative counts from the end). */
    bodyOf(endpoint: Endpoint, call = 0): unknown {
      return bodyOf(callsOf(endpoint).at(call)?.[1]);
    },
    /** The Authorization header of the n-th request to `endpoint` (negative counts from the end). */
    authOf(endpoint: Endpoint, call = 0): string | null {
      const init = callsOf(endpoint).at(call)?.[1];
      return new Headers(init?.headers).get('Authorization');
    },
  };
}

export type FakeServer = ReturnType<typeof fakeServer>;

/** A fake 0.4 server with an answer for every endpoint; override any of them. */
export function stage3Server(bodies: Partial<Record<Endpoint, unknown>> = {}) {
  return fakeServer({
    info: installedInfo(),
    status: busyStatus(),
    jobs: sampleJobs(),
    job: { job: sampleJob() },
    jobItems: sampleItemPage(),
    cancelJob: { job: sampleJob({ state: 'cancelled', finished: '2026-11-14T09:34:00Z' }) },
    retryJob: { job: sampleJob() },
    settings: sampleSettings(),
    updateSettings: sampleSettings(),
    browse: sampleBrowse(),
    queueFolder: sampleFolderQueued(),
    selfTest: passedSelfTest(),
    log: sampleLog(),
    ...bodies,
  });
}
