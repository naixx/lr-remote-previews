import { describe, expect, it } from 'vitest';
import { authHeaderOf, jsonResponse, mockFetch, sampleInfo } from '../test/fixtures';
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
