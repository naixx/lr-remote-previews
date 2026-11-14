import { render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it } from 'vitest';
import { TOKEN_STORAGE_KEY } from '../../api/token';
import { ApiProvider } from '../../app/ApiProvider';
import { Layout } from '../../app/Layout';
import {
  fakeServer,
  idleStatus,
  installedInfo,
  sampleInfo,
  type FakeServer,
} from '../../test/fixtures';
import { OverviewPage } from './OverviewPage';

function renderOverview(server: FakeServer) {
  return render(
    <ApiProvider fetch={server.fetch}>
      <Layout>
        <OverviewPage />
      </Layout>
    </ApiProvider>,
  );
}

function idleServer(info: unknown = sampleInfo()) {
  return fakeServer({ info, status: idleStatus(), jobs: { jobs: [] } });
}

const UNAUTHORIZED = { detail: 'Missing or invalid token.' };

describe('OverviewPage', () => {
  it('shows a loading state, then the server details', async () => {
    renderOverview(idleServer());

    expect(screen.getByRole('status').textContent).toContain('Connecting to the server');

    const server = await screen.findByRole('region', { name: 'Server' });
    expect(within(server).getByText('LR Remote Previews')).toBeTruthy();
    expect(within(server).getByText('0.4.0')).toBeTruthy();
    expect(document.title).toBe('Overview · LR Remote Previews');
    expect(within(server).getByText('Token required')).toBeTruthy();
    expect(within(server).getByText('1')).toBeTruthy();
    expect(screen.queryByText('Connecting to the server…')).toBeNull();
  });

  it('shows a missing converter with its expected path and the install hint', async () => {
    renderOverview(idleServer());

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
    renderOverview(idleServer(installedInfo()));

    const converter = await screen.findByRole('region', { name: 'DNG converter' });
    expect(within(converter).getByText('Installed')).toBeTruthy();
    expect(within(converter).getByText('17.5')).toBeTruthy();
    expect(within(converter).queryByText('docs/converter.md')).toBeNull();
  });

  it('lists roots with their availability and the supported extensions', async () => {
    renderOverview(idleServer());

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
    expect(screen.getByText(/up to 5,000 photos/)).toBeTruthy();
  });

  it('leaves out the job size limit when an older server does not send it', async () => {
    const info = sampleInfo();
    const capabilities: Record<string, unknown> = { ...info.capabilities };
    delete capabilities.maxItemsPerJob;
    renderOverview(idleServer({ ...info, capabilities }));

    expect(await screen.findByText(/2560 px on the long edge/)).toBeTruthy();
    expect(screen.queryByText(/One job can hold/)).toBeNull();
  });

  it('offers a retry when the server is unreachable', async () => {
    const server = idleServer();
    server.failNetwork('info');
    const user = userEvent.setup();
    renderOverview(server);

    const alert = await screen.findByRole('alert');
    expect(alert.textContent).toContain('Server unreachable');
    expect(server.calls('status')).toBe(0);

    server.reply('info', sampleInfo());
    await user.click(within(alert).getByRole('button', { name: 'Retry' }));

    expect(await screen.findByRole('region', { name: 'Server' })).toBeTruthy();
    expect(server.calls('info')).toBe(2);
  });

  it('reports an unexpected response shape with the offending field', async () => {
    renderOverview(idleServer({ ...sampleInfo(), api: 'one' }));

    const alert = await screen.findByRole('alert');
    expect(alert.textContent).toContain('Unexpected response');
    expect(alert.textContent).toContain('api: expected an integer');
    expect(within(alert).getByRole('button', { name: 'Retry' })).toBeTruthy();
  });

  it('asks for a token on 401, stores it and retries with it', async () => {
    const server = idleServer();
    server.reply('info', UNAUTHORIZED, 401);
    const user = userEvent.setup();
    renderOverview(server);

    expect(await screen.findByRole('heading', { name: 'Access token required' })).toBeTruthy();
    expect(screen.getByText('Server message: Missing or invalid token.')).toBeTruthy();
    expect(server.authOf('info', 0)).toBeNull();

    server.reply('info', sampleInfo());
    await user.type(screen.getByLabelText('Access token'), 'secret-token');
    await user.click(screen.getByRole('button', { name: 'Save token' }));

    expect(await screen.findByRole('region', { name: 'Server' })).toBeTruthy();
    expect(window.localStorage.getItem(TOKEN_STORAGE_KEY)).toBe('secret-token');
    expect(server.authOf('info', 1)).toBe('Bearer secret-token');
    expect(await screen.findByText(/No jobs yet/)).toBeTruthy();
    expect(server.authOf('status', -1)).toBe('Bearer secret-token');
    expect(server.authOf('jobs', -1)).toBe('Bearer secret-token');
  });

  it('says so when the saved token is rejected', async () => {
    window.localStorage.setItem(TOKEN_STORAGE_KEY, 'old-token');
    const server = idleServer();
    server.reply('info', UNAUTHORIZED, 401);
    renderOverview(server);

    expect(
      await screen.findByText('The server did not accept the saved token. Enter the current one.'),
    ).toBeTruthy();
    expect(server.authOf('info', 0)).toBe('Bearer old-token');
  });

  it('tries again when the same token is entered once more', async () => {
    window.localStorage.setItem(TOKEN_STORAGE_KEY, 'secret-token');
    const server = idleServer();
    server.reply('info', UNAUTHORIZED, 401);
    const user = userEvent.setup();
    renderOverview(server);

    await screen.findByRole('heading', { name: 'Access token required' });
    expect(document.title).toBe('Access token required · LR Remote Previews');
    // The server accepts the token again (it was restarted with it, say).
    server.reply('info', sampleInfo());
    await user.type(screen.getByLabelText('Access token'), 'secret-token');
    await user.click(screen.getByRole('button', { name: 'Save token' }));

    expect(await screen.findByRole('region', { name: 'Server' })).toBeTruthy();
    expect(server.calls('info')).toBe(2);
  });
});
