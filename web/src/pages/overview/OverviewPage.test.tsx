import { render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it } from 'vitest';
import { TOKEN_STORAGE_KEY } from '../../api/token';
import { ApiProvider } from '../../app/ApiProvider';
import { Layout } from '../../app/Layout';
import { authHeaderOf, jsonResponse, mockFetch, sampleInfo } from '../../test/fixtures';
import { OverviewPage } from './OverviewPage';

function renderOverview(fetchMock: ReturnType<typeof mockFetch>) {
  return render(
    <ApiProvider fetch={fetchMock}>
      <Layout>
        <OverviewPage />
      </Layout>
    </ApiProvider>,
  );
}

function unauthorized() {
  return jsonResponse({ detail: 'Missing or invalid token.' }, 401);
}

describe('OverviewPage', () => {
  it('shows a loading state, then the server details', async () => {
    const fetchMock = mockFetch().mockResolvedValue(jsonResponse(sampleInfo()));
    renderOverview(fetchMock);

    expect(screen.getByRole('status').textContent).toContain('Connecting to the server');

    const server = await screen.findByRole('region', { name: 'Server' });
    expect(within(server).getByText('LR Remote Previews')).toBeTruthy();
    expect(within(server).getByText('0.1.0')).toBeTruthy();
    expect(within(server).getByText('Token required')).toBeTruthy();
    expect(within(server).getByText('1')).toBeTruthy();
    expect(screen.queryByRole('status')).toBeNull();
  });

  it('shows a missing converter with its expected path and the install hint', async () => {
    renderOverview(mockFetch().mockResolvedValue(jsonResponse(sampleInfo())));

    const converter = await screen.findByRole('region', { name: 'DNG converter' });
    expect(within(converter).getByText('Not installed')).toBeTruthy();
    expect(within(converter).getByText('Expected path')).toBeTruthy();
    expect(
      within(converter).getByText(
        'C:\\Program Files\\Adobe\\Adobe DNG Converter\\Adobe DNG Converter.exe',
      ),
    ).toBeTruthy();
    expect(within(converter).getByText('docs/converter.md')).toBeTruthy();
    expect(converter.textContent).toContain('not part of LR Remote Previews');
  });

  it('shows an installed converter with its version', async () => {
    const body = sampleInfo();
    const info = { ...body, converter: { ...body.converter, installed: true, version: '17.5' } };
    renderOverview(mockFetch().mockResolvedValue(jsonResponse(info)));

    const converter = await screen.findByRole('region', { name: 'DNG converter' });
    expect(within(converter).getByText('Installed')).toBeTruthy();
    expect(within(converter).getByText('17.5')).toBeTruthy();
    expect(within(converter).queryByText('docs/converter.md')).toBeNull();
  });

  it('lists roots with their availability and the supported extensions', async () => {
    renderOverview(mockFetch().mockResolvedValue(jsonResponse(sampleInfo())));

    const roots = await screen.findByRole('region', { name: 'Library roots' });
    const items = within(roots).getAllByRole('listitem');
    expect(items).toHaveLength(2);
    expect(items[0]?.textContent).toContain('Archive');
    expect(items[0]?.textContent).toContain('Available');
    expect(items[1]?.textContent).toContain('Offsite copy');
    expect(items[1]?.textContent).toContain('Unavailable');
    expect(roots.textContent).toContain('1 of 2 available');

    const extensions = screen.getByRole('list', { name: 'Supported raw file extensions' });
    expect(
      within(extensions)
        .getAllByRole('listitem')
        .map((item) => item.textContent),
    ).toEqual(['.arw', '.cr2']);
    expect(screen.getByText(/2560 px on the long edge/)).toBeTruthy();
  });

  it('offers a retry when the server is unreachable', async () => {
    const fetchMock = mockFetch()
      .mockRejectedValueOnce(new TypeError('Failed to fetch'))
      .mockResolvedValue(jsonResponse(sampleInfo()));
    const user = userEvent.setup();
    renderOverview(fetchMock);

    const alert = await screen.findByRole('alert');
    expect(alert.textContent).toContain('Server unreachable');

    await user.click(within(alert).getByRole('button', { name: 'Retry' }));

    expect(await screen.findByRole('region', { name: 'Server' })).toBeTruthy();
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it('reports an unexpected response shape with the offending field', async () => {
    const fetchMock = mockFetch().mockResolvedValue(jsonResponse({ ...sampleInfo(), api: 'one' }));
    renderOverview(fetchMock);

    const alert = await screen.findByRole('alert');
    expect(alert.textContent).toContain('Unexpected response');
    expect(alert.textContent).toContain('api: expected an integer');
    expect(within(alert).getByRole('button', { name: 'Retry' })).toBeTruthy();
  });

  it('asks for a token on 401, stores it and retries with it', async () => {
    const fetchMock = mockFetch()
      .mockResolvedValueOnce(unauthorized())
      .mockResolvedValue(jsonResponse(sampleInfo()));
    const user = userEvent.setup();
    renderOverview(fetchMock);

    expect(await screen.findByRole('heading', { name: 'Access token required' })).toBeTruthy();
    expect(screen.getByText('Server message: Missing or invalid token.')).toBeTruthy();
    expect(authHeaderOf(fetchMock, 0)).toBeNull();

    await user.type(screen.getByLabelText('Access token'), 'secret-token');
    await user.click(screen.getByRole('button', { name: 'Save token' }));

    expect(await screen.findByRole('region', { name: 'Server' })).toBeTruthy();
    expect(window.localStorage.getItem(TOKEN_STORAGE_KEY)).toBe('secret-token');
    expect(authHeaderOf(fetchMock, 1)).toBe('Bearer secret-token');
  });

  it('says so when the saved token is rejected', async () => {
    window.localStorage.setItem(TOKEN_STORAGE_KEY, 'old-token');
    const fetchMock = mockFetch().mockResolvedValue(unauthorized());
    renderOverview(fetchMock);

    expect(
      await screen.findByText('The server did not accept the saved token. Enter the current one.'),
    ).toBeTruthy();
    expect(authHeaderOf(fetchMock, 0)).toBe('Bearer old-token');
  });

  it('forgets the token on request and asks for it again', async () => {
    window.localStorage.setItem(TOKEN_STORAGE_KEY, 'secret-token');
    const fetchMock = mockFetch()
      .mockResolvedValueOnce(jsonResponse(sampleInfo()))
      .mockResolvedValue(unauthorized());
    const user = userEvent.setup();
    renderOverview(fetchMock);

    await screen.findByRole('region', { name: 'Server' });
    await user.click(screen.getByRole('button', { name: 'Forget token' }));

    expect(await screen.findByRole('heading', { name: 'Access token required' })).toBeTruthy();
    expect(window.localStorage.getItem(TOKEN_STORAGE_KEY)).toBeNull();
    expect(authHeaderOf(fetchMock, 1)).toBeNull();
    expect(screen.queryByRole('button', { name: 'Forget token' })).toBeNull();
  });
});
