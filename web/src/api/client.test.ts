import { describe, expect, it, vi } from 'vitest';
import {
  authHeaderOf,
  busyStatus,
  failedItem,
  failedSelfTest,
  jsonResponse,
  mockFetch,
  passedSelfTest,
  sampleBrowse,
  sampleFolderQueued,
  sampleInfo,
  sampleItemPage,
  sampleJob,
  sampleJobs,
  sampleLog,
  sampleSettings,
} from '../test/fixtures';
import { createApiClient } from './client';
import { ApiError, describeError, isMissingEndpoint } from './errors';

async function captureError(promise: Promise<unknown>): Promise<unknown> {
  try {
    await promise;
  } catch (error) {
    return error;
  }
  throw new Error('Expected the request to fail.');
}

describe('createApiClient().getInfo', () => {
  it('returns the checked info on success', async () => {
    const fetchMock = mockFetch().mockResolvedValue(jsonResponse(sampleInfo()));
    const client = createApiClient({ fetch: fetchMock });

    const info = await client.getInfo();

    expect(info.name).toBe('LR Remote Previews');
    expect(info.converter.installed).toBe(false);
    expect(info.roots.map((root) => root.id)).toEqual(['archive', 'offsite']);
    expect(info.capabilities.previewLongEdge).toBe(2560);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock.mock.calls[0]?.[0]).toBe('api/v1/info');
  });

  it('sends the token as a bearer header', async () => {
    const fetchMock = mockFetch().mockResolvedValue(jsonResponse(sampleInfo()));
    await createApiClient({ token: ' secret-token ', fetch: fetchMock }).getInfo();
    expect(authHeaderOf(fetchMock)).toBe('Bearer secret-token');
  });

  it('sends no Authorization header without a token', async () => {
    const fetchMock = mockFetch().mockResolvedValue(jsonResponse(sampleInfo()));
    await createApiClient({ token: null, fetch: fetchMock }).getInfo();
    expect(authHeaderOf(fetchMock)).toBeNull();
  });

  it('reports 401 as unauthorized with the server detail', async () => {
    const fetchMock = mockFetch().mockResolvedValue(
      jsonResponse({ detail: 'Missing or invalid token.' }, 401),
    );

    const error = await captureError(createApiClient({ fetch: fetchMock }).getInfo());

    expect(error).toBeInstanceOf(ApiError);
    expect(error).toMatchObject({
      kind: 'unauthorized',
      status: 401,
      detail: 'Missing or invalid token.',
    });
  });

  it('reports 401 without a JSON body as unauthorized with no detail', async () => {
    const fetchMock = mockFetch().mockResolvedValue(new Response('nope', { status: 401 }));
    const error = await captureError(createApiClient({ fetch: fetchMock }).getInfo());
    expect(error).toMatchObject({ kind: 'unauthorized', status: 401, detail: null });
  });

  it('reports other error statuses as http errors', async () => {
    const fetchMock = mockFetch().mockResolvedValue(jsonResponse({ detail: 'Boom' }, 500));
    const error = await captureError(createApiClient({ fetch: fetchMock }).getInfo());
    expect(error).toMatchObject({ kind: 'http', status: 500, detail: 'Boom' });
  });

  it('reports a failed fetch as a network error', async () => {
    const fetchMock = mockFetch().mockRejectedValue(new TypeError('Failed to fetch'));
    const error = await captureError(createApiClient({ fetch: fetchMock }).getInfo());
    expect(error).toBeInstanceOf(ApiError);
    expect(error).toMatchObject({ kind: 'network', status: null });
  });

  it('rethrows an abort the caller asked for unchanged', async () => {
    const controller = new AbortController();
    controller.abort();
    const abortError = new DOMException('The operation was aborted.', 'AbortError');
    const fetchMock = mockFetch().mockRejectedValue(abortError);

    const error = await captureError(createApiClient({ fetch: fetchMock }).getInfo(controller.signal));

    expect(error).toBe(abortError);
  });

  it('reports a body with the wrong shape as a bad response naming the field', async () => {
    const body = sampleInfo();
    const broken = { ...body, roots: [{ id: 'archive', label: 'Archive', available: 'yes' }] };
    const fetchMock = mockFetch().mockResolvedValue(jsonResponse(broken));

    const error = await captureError(createApiClient({ fetch: fetchMock }).getInfo());

    expect(error).toMatchObject({ kind: 'bad-response', status: 200 });
    expect((error as ApiError).detail).toContain('roots[0].available');
  });

  it('reports a body that is not JSON as a bad response', async () => {
    const fetchMock = mockFetch().mockResolvedValue(
      new Response('<html>proxy error page</html>', { status: 200 }),
    );
    const error = await captureError(createApiClient({ fetch: fetchMock }).getInfo());
    expect(error).toMatchObject({ kind: 'bad-response', status: 200 });
  });
});

describe('createApiClient().getStatus', () => {
  it('returns the checked status on success, with the token', async () => {
    const fetchMock = mockFetch().mockResolvedValue(jsonResponse(busyStatus()));

    const status = await createApiClient({ token: 'secret-token', fetch: fetchMock }).getStatus();

    expect(status).toEqual(busyStatus());
    expect(fetchMock.mock.calls[0]?.[0]).toBe('api/v1/status');
    expect(authHeaderOf(fetchMock)).toBe('Bearer secret-token');
  });

  it('reports a body with the wrong shape as a bad response naming the field', async () => {
    const body = { ...busyStatus(), rate: { perMinute: '172.5', windowSeconds: 60 } };
    const fetchMock = mockFetch().mockResolvedValue(jsonResponse(body));

    const error = await captureError(createApiClient({ fetch: fetchMock }).getStatus());

    expect(error).toMatchObject({ kind: 'bad-response', status: 200 });
    expect((error as ApiError).detail).toBe('rate.perMinute: expected a number, got string "172.5"');
  });

  it('reports 401 as unauthorized', async () => {
    const fetchMock = mockFetch().mockResolvedValue(
      jsonResponse({ detail: 'Missing or invalid token.' }, 401),
    );
    const error = await captureError(createApiClient({ fetch: fetchMock }).getStatus());
    expect(error).toMatchObject({
      kind: 'unauthorized',
      status: 401,
      detail: 'Missing or invalid token.',
    });
  });
});

describe('createApiClient().getJobs', () => {
  it('returns the checked jobs on success', async () => {
    const fetchMock = mockFetch().mockResolvedValue(jsonResponse(sampleJobs()));

    const list = await createApiClient({ fetch: fetchMock }).getJobs();

    expect(list.jobs.map((job) => job.id)).toEqual([7, 6, 5]);
    expect(list.jobs[0]).toEqual(sampleJob());
    expect(list.jobs[1]?.label).toBeNull();
    expect(fetchMock.mock.calls[0]?.[0]).toBe('api/v1/jobs');
  });

  it('sends limit and state as query parameters on a relative path', async () => {
    const fetchMock = mockFetch().mockResolvedValue(jsonResponse({ jobs: [] }));

    await createApiClient({ fetch: fetchMock }).getJobs({ limit: 10, state: 'active' });

    expect(fetchMock.mock.calls[0]?.[0]).toBe('api/v1/jobs?limit=10&state=active');
  });

  it('reports a body with the wrong shape as a bad response naming the field', async () => {
    const body = { jobs: [sampleJob(), sampleJob({ id: 6, state: 'paused' })] };
    const fetchMock = mockFetch().mockResolvedValue(jsonResponse(body));

    const error = await captureError(createApiClient({ fetch: fetchMock }).getJobs());

    expect(error).toMatchObject({ kind: 'bad-response', status: 200 });
    expect((error as ApiError).detail).toContain('jobs[1].state');
  });

  it('reports 401 as unauthorized', async () => {
    const fetchMock = mockFetch().mockResolvedValue(
      jsonResponse({ detail: 'Missing or invalid token.' }, 401),
    );
    const error = await captureError(createApiClient({ fetch: fetchMock }).getJobs({ limit: 10 }));
    expect(error).toMatchObject({ kind: 'unauthorized', status: 401 });
  });
});

/** The method, path and JSON body of the n-th call to a fetch mock. */
function requestOf(fetchMock: ReturnType<typeof mockFetch>, call = 0) {
  const [input, init] = fetchMock.mock.calls[call] ?? [];
  const headers = new Headers(init?.headers);
  return {
    url: input,
    method: init?.method ?? 'GET',
    body: typeof init?.body === 'string' ? (JSON.parse(init.body) as unknown) : undefined,
    contentType: headers.get('Content-Type'),
  };
}

function answering(body: unknown, status = 200) {
  return mockFetch().mockResolvedValue(jsonResponse(body, status));
}

describe('error bodies', () => {
  it('keeps the code of an error answer next to its detail', async () => {
    const fetchMock = answering(
      { detail: 'Adobe DNG Converter is not installed.', code: 'converter_not_installed' },
      409,
    );
    const error = await captureError(
      createApiClient({ fetch: fetchMock }).queueFolder({
        root: 'archive',
        path: '2026',
        recursive: false,
      }),
    );
    expect(error).toMatchObject({
      kind: 'http',
      status: 409,
      code: 'converter_not_installed',
      detail: 'Adobe DNG Converter is not installed.',
    });
    expect(describeError(error as ApiError)).toBe('Adobe DNG Converter is not installed.');
    expect(isMissingEndpoint(error as ApiError)).toBe(false);
  });

  it('tells a missing endpoint (404 without a code) from a 404 with a code', async () => {
    const missing = await captureError(
      createApiClient({ fetch: answering({ detail: 'Not Found' }, 404) }).getSettings(),
    );
    expect(isMissingEndpoint(missing as ApiError)).toBe(true);

    const notFound = await captureError(
      createApiClient({
        fetch: answering({ detail: 'No such folder', code: 'not_found' }, 404),
      }).browse('archive', 'gone'),
    );
    expect(isMissingEndpoint(notFound as ApiError)).toBe(false);
    expect(notFound).toMatchObject({ code: 'not_found' });
  });

  it('calls onUnauthorized with the detail of every 401', async () => {
    const onUnauthorized = vi.fn();
    const fetchMock = answering({ detail: 'Missing or invalid token.' }, 401);
    const client = createApiClient({ fetch: fetchMock, onUnauthorized });
    await captureError(client.getLog());
    await captureError(client.updateSettings({ paused: true }));
    expect(onUnauthorized).toHaveBeenCalledTimes(2);
    expect(onUnauthorized).toHaveBeenCalledWith('Missing or invalid token.');
  });
});

describe('createApiClient().getJob and getJobItems', () => {
  it('reads one job', async () => {
    const fetchMock = answering({ job: sampleJob() });
    const job = await createApiClient({ fetch: fetchMock }).getJob(7);
    expect(job).toEqual(sampleJob());
    expect(requestOf(fetchMock)).toMatchObject({ url: 'api/v1/jobs/7', method: 'GET' });
  });

  it('reads a page of items with since, limit and state', async () => {
    const fetchMock = answering(sampleItemPage([failedItem()], true));
    const page = await createApiClient({ fetch: fetchMock }).getJobItems(7, {
      since: 40,
      limit: 100,
      state: 'failed',
    });
    expect(requestOf(fetchMock).url).toBe('api/v1/jobs/7/items?since=40&limit=100&state=failed');
    expect(page.more).toBe(true);
    expect(page.job.id).toBe(7);
    expect(page.items[0]).toMatchObject({
      id: 4212,
      state: 'failed',
      error: { code: 'converter_failed', message: 'The converter exited with code 1.' },
      result: null,
    });
  });

  it('asks without a query when none is given', async () => {
    const fetchMock = answering(sampleItemPage());
    await createApiClient({ fetch: fetchMock }).getJobItems(7);
    expect(requestOf(fetchMock).url).toBe('api/v1/jobs/7/items');
  });

  it('reports a bad item as a bad response naming the field', async () => {
    const fetchMock = answering(sampleItemPage([failedItem({ state: 'lost' })]));
    const error = await captureError(createApiClient({ fetch: fetchMock }).getJobItems(7));
    expect(error).toMatchObject({ kind: 'bad-response' });
    expect((error as ApiError).detail).toContain('items[0].state');
  });

  it('reports an unknown job as a 404', async () => {
    const fetchMock = answering({ detail: 'No such job' }, 404);
    const error = await captureError(createApiClient({ fetch: fetchMock }).getJob(99));
    expect(error).toMatchObject({ kind: 'http', status: 404, detail: 'No such job', code: null });
  });
});

describe('createApiClient().cancelJob and retryJob', () => {
  it('cancels with DELETE and returns the job', async () => {
    const cancelled = sampleJob({ state: 'cancelled', finished: '2026-11-14T09:34:00Z' });
    const fetchMock = answering({ job: cancelled });
    const job = await createApiClient({ token: 't', fetch: fetchMock }).cancelJob(7);
    expect(job.state).toBe('cancelled');
    expect(requestOf(fetchMock)).toMatchObject({
      url: 'api/v1/jobs/7',
      method: 'DELETE',
      body: undefined,
    });
    expect(authHeaderOf(fetchMock)).toBe('Bearer t');
  });

  it('retries with POST to the retry path', async () => {
    const fetchMock = answering({ job: sampleJob() });
    await createApiClient({ fetch: fetchMock }).retryJob(7);
    expect(requestOf(fetchMock)).toMatchObject({ url: 'api/v1/jobs/7/retry', method: 'POST' });
  });

  it('reports job_cancelled with its code', async () => {
    const fetchMock = answering({ detail: 'The job was cancelled.', code: 'job_cancelled' }, 409);
    const error = await captureError(createApiClient({ fetch: fetchMock }).retryJob(5));
    expect(error).toMatchObject({ kind: 'http', status: 409, code: 'job_cancelled' });
  });

  it('reports an answer without a job as a bad response', async () => {
    const fetchMock = answering({ jobs: [] });
    const error = await captureError(createApiClient({ fetch: fetchMock }).cancelJob(7));
    expect(error).toMatchObject({ kind: 'bad-response' });
    expect((error as ApiError).detail).toBe('job: expected an object, got nothing');
  });
});

describe('createApiClient().getSettings and updateSettings', () => {
  it('reads the settings', async () => {
    const fetchMock = answering(sampleSettings({ workers: 6 }));
    const settings = await createApiClient({ fetch: fetchMock }).getSettings();
    expect(settings).toEqual(sampleSettings({ workers: 6 }));
    expect(requestOf(fetchMock)).toMatchObject({ url: 'api/v1/settings', method: 'GET' });
  });

  it('sends a change with PATCH as JSON and returns the new settings', async () => {
    const fetchMock = answering(sampleSettings({ batchSize: 16 }));
    const change = {
      batchSize: 16,
      workingHours: { enabled: true, from: '22:00', to: '07:00' },
    };
    const settings = await createApiClient({ fetch: fetchMock }).updateSettings(change);
    expect(settings.batchSize).toBe(16);
    expect(requestOf(fetchMock)).toEqual({
      url: 'api/v1/settings',
      method: 'PATCH',
      body: change,
      contentType: 'application/json',
    });
  });

  it('reports a refused value with the server text', async () => {
    const fetchMock = answering({ detail: 'workers: 2 is not allowed' }, 422);
    const error = await captureError(
      createApiClient({ fetch: fetchMock }).updateSettings({ workers: 2 }),
    );
    expect(error).toMatchObject({ kind: 'http', status: 422, detail: 'workers: 2 is not allowed' });
  });

  it('reports settings with the wrong shape naming the field', async () => {
    const fetchMock = answering({ ...sampleSettings(), workers: 'many' });
    const error = await captureError(createApiClient({ fetch: fetchMock }).getSettings());
    expect((error as ApiError).detail).toContain('workers: expected "auto" or a whole number');
  });
});

describe('createApiClient().browse and queueFolder', () => {
  it('browses a folder of a root', async () => {
    const fetchMock = answering(sampleBrowse());
    const folder = await createApiClient({ fetch: fetchMock }).browse('archive', '2026/a b');
    expect(folder.dirs).toHaveLength(2);
    expect(requestOf(fetchMock).url).toBe('api/v1/browse?root=archive&path=2026%2Fa+b');
  });

  it('leaves the path out for the root itself', async () => {
    const fetchMock = answering(sampleBrowse({ path: '', parent: null }));
    const folder = await createApiClient({ fetch: fetchMock }).browse('archive', '');
    expect(folder.parent).toBeNull();
    expect(requestOf(fetchMock).url).toBe('api/v1/browse?root=archive');
  });

  it('reports a browse error with its code', async () => {
    const fetchMock = answering({ detail: 'Root is not mounted', code: 'root_unavailable' }, 404);
    const error = await captureError(createApiClient({ fetch: fetchMock }).browse('offsite', ''));
    expect(error).toMatchObject({ status: 404, code: 'root_unavailable' });
  });

  it('reports a browse body with the wrong shape naming the field', async () => {
    const fetchMock = answering({ ...sampleBrowse(), rawFiles: -1 });
    const error = await captureError(createApiClient({ fetch: fetchMock }).browse('archive', ''));
    expect((error as ApiError).detail).toContain('rawFiles');
  });

  it('queues a folder with POST and returns the jobs', async () => {
    const fetchMock = answering(sampleFolderQueued(), 201);
    const result = await createApiClient({ fetch: fetchMock }).queueFolder({
      root: 'archive',
      path: '2026/2026.06.20 - shoot',
      recursive: true,
    });
    expect(result.files).toBe(384);
    expect(result.jobs.map((job) => job.id)).toEqual([12]);
    expect(requestOf(fetchMock)).toMatchObject({
      url: 'api/v1/folders',
      method: 'POST',
      body: { root: 'archive', path: '2026/2026.06.20 - shoot', recursive: true },
    });
  });

  it('reports too_many_files with its code', async () => {
    const fetchMock = answering({ detail: '61234 raw files found', code: 'too_many_files' }, 422);
    const error = await captureError(
      createApiClient({ fetch: fetchMock }).queueFolder({
        root: 'archive',
        path: '',
        recursive: true,
      }),
    );
    expect(error).toMatchObject({ status: 422, code: 'too_many_files' });
  });
});

describe('createApiClient().runSelfTest', () => {
  it('runs without a body when no file is named', async () => {
    const fetchMock = answering({ ok: true, steps: passedSelfTest().steps.slice(0, 3) });
    const result = await createApiClient({ fetch: fetchMock }).runSelfTest(null);
    expect(result.ok).toBe(true);
    expect(requestOf(fetchMock)).toEqual({
      url: 'api/v1/converter/selftest',
      method: 'POST',
      body: undefined,
      contentType: null,
    });
  });

  it('sends the file to convert and returns the failed steps', async () => {
    const fetchMock = answering(failedSelfTest());
    const file = { root: 'archive', path: '2026/IMG_0001.ARW' };
    const result = await createApiClient({ fetch: fetchMock }).runSelfTest(file);
    expect(result.ok).toBe(false);
    expect(result.steps.map((step) => step.ok)).toEqual([true, true, false]);
    expect(requestOf(fetchMock).body).toEqual(file);
  });

  it('reports busy with its code', async () => {
    const fetchMock = answering({ detail: 'A self-test is running.', code: 'busy' }, 409);
    const error = await captureError(createApiClient({ fetch: fetchMock }).runSelfTest(null));
    expect(error).toMatchObject({ status: 409, code: 'busy' });
  });

  it('reports a step with the wrong shape naming the field', async () => {
    const fetchMock = answering({ ok: true, steps: [{ name: 'installed', ok: 'yes', detail: '' }] });
    const error = await captureError(createApiClient({ fetch: fetchMock }).runSelfTest(null));
    expect((error as ApiError).detail).toContain('steps[0].ok');
  });
});

describe('createApiClient().getLog', () => {
  it('asks for the newest lines with a limit', async () => {
    const fetchMock = answering(sampleLog());
    const log = await createApiClient({ fetch: fetchMock }).getLog(500);
    expect(log.lines.map((line) => line.level)).toEqual(['INFO', 'WARNING', 'ERROR']);
    expect(requestOf(fetchMock).url).toBe('api/v1/log?limit=500');
  });

  it('reports a line with the wrong shape naming the field', async () => {
    const fetchMock = answering({ lines: [{ ...sampleLog().lines[0], time: 'now' }] });
    const error = await captureError(createApiClient({ fetch: fetchMock }).getLog());
    expect((error as ApiError).detail).toContain('lines[0].time');
  });

  it('reports a missing endpoint on an older server', async () => {
    const fetchMock = answering({ detail: 'Not Found' }, 404);
    const error = await captureError(createApiClient({ fetch: fetchMock }).getLog());
    expect(isMissingEndpoint(error as ApiError)).toBe(true);
  });
});
