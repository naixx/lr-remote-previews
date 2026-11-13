import { describe, expect, it } from 'vitest';
import {
  authHeaderOf,
  busyStatus,
  jsonResponse,
  mockFetch,
  sampleInfo,
  sampleJob,
  sampleJobs,
} from '../test/fixtures';
import { createApiClient } from './client';
import { ApiError } from './errors';

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
