import { act, fireEvent, render, screen, within } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { TOKEN_STORAGE_KEY } from '../../api/token';
import { ApiProvider } from '../../app/ApiProvider';
import type { ColorScheme } from '../../app/router';
import {
  autoScanJob,
  busyStatus,
  fakeServer,
  idleStatus,
  installedInfo,
  sampleInfo,
  sampleJob,
  type FakeServer,
} from '../../test/fixtures';
import { advance, installFakeClock, settle } from '../../test/render';
import { BUSY_REFRESH_MS, IDLE_REFRESH_MS } from '../overview/live';
import { WidgetPage } from './WidgetPage';

installFakeClock();

async function renderWidget(server: FakeServer, theme: ColorScheme | null = null) {
  const result = render(
    <ApiProvider fetch={server.fetch}>
      <WidgetPage theme={theme} />
    </ApiProvider>,
  );
  await settle();
  return result;
}

/** An info body with the converter installed and every root available. */
function healthyInfo() {
  return { ...installedInfo(), roots: [{ id: 'archive', label: 'Archive', available: true }] };
}

function idleServer() {
  return fakeServer({ info: healthyInfo(), status: idleStatus(), jobs: { jobs: [] } });
}

/** Job 7 is being built; job 8 (newer) and jobs 6 and 5 (older) wait. */
function busyServer() {
  const waiting = { building: 0, queued: 100, ready: 0, failed: 0 };
  return fakeServer({
    info: healthyInfo(),
    status: busyStatus(),
    jobs: {
      jobs: [
        autoScanJob(),
        sampleJob(),
        sampleJob({ id: 6, label: 'Older selection', counts: { total: 100, ...waiting } }),
        sampleJob({ id: 5, label: 'Oldest selection', counts: { total: 100, ...waiting } }),
      ],
    },
  });
}

/** The text next to a label: «Today», «Cache», «Processes», «Automatic scan». */
function figure(label: string): string {
  return screen.getByText(label, { selector: 'dt' }).nextElementSibling?.textContent ?? '';
}

function problemLine(): HTMLElement {
  return screen.getByRole('status');
}

function visibility() {
  return vi.spyOn(document, 'visibilityState', 'get');
}

function announceVisibility() {
  act(() => {
    document.dispatchEvent(new Event('visibilitychange'));
  });
}

const UNAUTHORIZED = { detail: 'Missing or invalid token.' };

describe('WidgetPage', () => {
  it('shows an idle server in one calm line, with today and the cache', async () => {
    const server = idleServer();
    await renderWidget(server);

    expect(screen.getByRole('heading', { level: 1, name: 'LR Remote Previews' })).toBeTruthy();
    const brand = screen.getByRole('link', { name: 'LR Remote Previews' });
    expect(brand.getAttribute('href')).toBe('./');
    expect(brand.getAttribute('target')).toBe('_blank');
    expect(brand.getAttribute('rel')).toBe('noopener');
    expect(screen.getByText('Idle', { selector: '.badge' })).toBeTruthy();
    expect(screen.getByText('Nothing is queued.')).toBeTruthy();
    expect(figure('Today')).toBe('1,542 built · none failed');
    expect(figure('Cache')).toBe('5,629 files · 3.0 GB');
    expect(figure('Processes')).toBe('0 of 4 busy');
    expect(figure('Automatic scan')).toBe('off');
    expect(document.title).toBe('Widget · LR Remote Previews');

    // Nothing is wrong, nothing is built, and nothing can be changed from here.
    expect(screen.queryByRole('status')).toBeNull();
    expect(screen.queryByRole('progressbar')).toBeNull();
    expect(screen.queryByRole('button')).toBeNull();
    expect(screen.getAllByRole('link')).toHaveLength(1);
    expect(server.urlOf('jobs')).toBe('api/v1/jobs?limit=10&state=active');
  });

  it('shows the work in progress, the job being built first', async () => {
    await renderWidget(busyServer());

    expect(screen.getByText('Running', { selector: '.badge' })).toBeTruthy();
    expect(screen.getByText('300 queued · 8 building')).toBeTruthy();
    expect(screen.getByText('173 photos/min · about 2 min left')).toBeTruthy();

    const jobs = within(screen.getByRole('list', { name: 'Active jobs' })).getAllByRole(
      'listitem',
    );
    expect(jobs.map((job) => job.querySelector('.widget-job__title')?.textContent)).toEqual([
      'Lightroom selection',
      'Automatic scan: archive',
      'Older selection',
    ]);
    expect(jobs[0]?.textContent).toContain('192 / 500');
    expect(jobs[1]?.textContent).toContain('0 / 120');
    const bar = screen.getByRole('progressbar', { name: 'Progress of Lightroom selection' });
    expect(bar.getAttribute('aria-valuenow')).toBe('192');
    expect(bar.getAttribute('aria-valuemax')).toBe('500');

    expect(figure('Processes')).toBe('4 of 4 busy');
    expect(figure('Automatic scan')).toMatch(
      /^next at .+ \(in 27 min\) · last at .+ \(33 min ago\), 120 files queued$/,
    );
  });

  it('says why queued work does not move', async () => {
    const server = busyServer();
    server.reply('status', { ...busyStatus(), state: 'waiting', etaSeconds: null });
    await renderWidget(server);
    expect(screen.getByText('Waiting for working hours', { selector: '.badge' })).toBeTruthy();
    expect(screen.getByText('Building starts when the working hours begin.')).toBeTruthy();

    server.reply('status', { ...busyStatus(), state: 'paused', etaSeconds: null });
    await advance(BUSY_REFRESH_MS);
    expect(screen.getByText('Paused', { selector: '.badge' })).toBeTruthy();
    expect(screen.getByText('Paused: no new conversions start.')).toBeTruthy();

    server.reply('status', {
      ...busyStatus(),
      queue: { queued: 0, building: 8 },
      rate: { perMinute: 0, windowSeconds: 60 },
      etaSeconds: null,
    });
    await advance(BUSY_REFRESH_MS);
    expect(screen.getByText('8 building')).toBeTruthy();
    expect(screen.getByText('The time left is not known yet.')).toBeTruthy();
  });

  it('emphasises failures today and links them to the jobs in a new tab', async () => {
    await renderWidget(busyServer());

    expect(figure('Today')).toBe('1,234 built · 2 failed');
    const failed = screen.getByRole('link', { name: '2 failed' });
    expect(failed.getAttribute('href')).toBe('#/jobs');
    expect(failed.getAttribute('target')).toBe('_blank');
    expect(failed.getAttribute('rel')).toBe('noopener');
    expect(failed.className).toContain('text-bad');
  });

  it('names what keeps the server from building', async () => {
    // The sample info: no converter, and the root «Offsite copy» unavailable.
    const server = fakeServer({ info: sampleInfo(), status: idleStatus(), jobs: { jobs: [] } });
    await renderWidget(server);

    expect(screen.getByText('Converter missing', { selector: '.badge' })).toBeTruthy();
    expect(problemLine().textContent).toBe(
      'Adobe DNG Converter is not installed.Library root unavailable: Offsite copy.',
    );
    expect(screen.getByText('Nothing is queued.')).toBeTruthy();
  });

  it('asks for the info once a minute, the status at the pace of the overview', async () => {
    const server = idleServer();
    await renderWidget(server);
    expect(server.calls('status')).toBe(1);
    expect(server.calls('info')).toBe(1);

    // The root goes offline; the widget notices with the next info, a minute after the first.
    server.reply('info', sampleInfo());
    for (let refresh = 1; refresh < 6; refresh += 1) await advance(IDLE_REFRESH_MS);
    expect(server.calls('status')).toBe(6);
    expect(server.calls('info')).toBe(1);
    expect(screen.queryByRole('status')).toBeNull();

    await advance(IDLE_REFRESH_MS);
    expect(server.calls('status')).toBe(7);
    expect(server.calls('info')).toBe(2);
    expect(problemLine().textContent).toContain('Library root unavailable: Offsite copy.');
  });

  it('keeps asking at its pace when the server answers with an error', async () => {
    const server = idleServer();
    await renderWidget(server);

    server.reply('status', { detail: 'Internal error' }, 500);
    await advance(IDLE_REFRESH_MS);
    expect(problemLine().textContent).toBe('The server answered with HTTP 500.');
    // The last answer stays as it was.
    expect(screen.getByText('Nothing is queued.')).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Check again' })).toBeNull();

    // An answer is no outage: the next request comes at the usual interval.
    await advance(IDLE_REFRESH_MS - 1);
    expect(server.calls('status')).toBe(2);
    await advance(1);
    expect(server.calls('status')).toBe(3);

    server.reply('status', idleStatus());
    await advance(IDLE_REFRESH_MS);
    expect(screen.queryByRole('status')).toBeNull();
  });

  it('asks for the token in the frame, stops meanwhile, and goes on with it', async () => {
    const server = idleServer();
    server.reply('status', UNAUTHORIZED, 401);
    await renderWidget(server);

    expect(screen.getByRole('heading', { name: 'Access token required' })).toBeTruthy();
    expect(screen.getByText('Server message: Missing or invalid token.')).toBeTruthy();
    expect(screen.getByRole('main').querySelector('form')?.className).toContain(
      'token-form--compact',
    );
    expect(screen.queryByRole('link', { name: 'LR Remote Previews' })).toBeNull();

    const calls = server.calls('status');
    await advance(10 * 60_000);
    expect(server.calls('status')).toBe(calls);

    server.reply('status', idleStatus());
    fireEvent.change(screen.getByLabelText('Access token'), { target: { value: 'secret-token' } });
    fireEvent.click(screen.getByRole('button', { name: 'Save token' }));
    await settle();

    expect(screen.getByText('Nothing is queued.')).toBeTruthy();
    expect(server.authOf('status', -1)).toBe('Bearer secret-token');
    expect(window.localStorage.getItem(TOKEN_STORAGE_KEY)).toBe('secret-token');
  });

  it('applies a colour scheme from the address, and only while it is shown', async () => {
    const root = document.documentElement;
    const { unmount } = await renderWidget(idleServer(), 'dark');
    expect(root.getAttribute('data-theme')).toBe('dark');
    expect(root.getAttribute('data-view')).toBe('widget');

    unmount();
    expect(root.hasAttribute('data-theme')).toBe(false);
    expect(root.hasAttribute('data-view')).toBe(false);

    await renderWidget(idleServer());
    expect(root.hasAttribute('data-theme')).toBe(false);
    expect(root.getAttribute('data-view')).toBe('widget');
  });
});

describe('a server that stops answering', () => {
  it('is tried three more times, then not again until «Check again»', async () => {
    const server = idleServer();
    await renderWidget(server);
    expect(server.calls('status')).toBe(1);

    // The NAS falls asleep.
    server.failNetwork('status');
    await advance(IDLE_REFRESH_MS);
    expect(server.calls('status')).toBe(2);
    expect(problemLine().textContent).toBe('Server not reachable. Trying again…');
    expect(screen.queryByRole('button', { name: 'Check again' })).toBeNull();
    // The last answer stays on screen, dimmed.
    expect(screen.getByText('Nothing is queued.')).toBeTruthy();
    expect(screen.getByRole('main').className).toContain('widget--stale');

    // The tries come 5 s, 15 s and 60 s after the failures.
    await advance(4_999);
    expect(server.calls('status')).toBe(2);
    await advance(1);
    expect(server.calls('status')).toBe(3);
    await advance(14_999);
    expect(server.calls('status')).toBe(3);
    await advance(1);
    expect(server.calls('status')).toBe(4);
    await advance(59_999);
    expect(server.calls('status')).toBe(4);
    await advance(1);
    expect(server.calls('status')).toBe(5);

    // Then it gives up and asks nothing by itself: not on a timer...
    expect(problemLine().textContent).toMatch(
      /^Server not reachable\. Last answer at .+\.Check again$/,
    );
    const checkAgain = screen.getByRole('button', { name: 'Check again' });
    const requests = server.fetch.mock.calls.length;
    await advance(60 * 60_000);
    expect(server.fetch.mock.calls.length).toBe(requests);

    // ...and not when the tab is shown again.
    const state = visibility();
    state.mockReturnValue('hidden');
    announceVisibility();
    state.mockReturnValue('visible');
    announceVisibility();
    await settle();
    expect(server.fetch.mock.calls.length).toBe(requests);

    // The button asks once more; the server is back, and so is the usual polling.
    server.reply('status', idleStatus());
    fireEvent.click(checkAgain);
    await settle();
    expect(server.calls('status')).toBe(6);
    expect(screen.queryByRole('status')).toBeNull();
    expect(screen.getByRole('main').className).not.toContain('widget--stale');
    await advance(IDLE_REFRESH_MS);
    expect(server.calls('status')).toBe(7);
  });

  it('starts the tries afresh after «Check again», also before any answer', async () => {
    const server = idleServer();
    server.failNetwork('status');
    await renderWidget(server);

    expect(server.calls('status')).toBe(1);
    expect(problemLine().textContent).toBe('Server not reachable. Trying again…');
    expect(screen.queryByText('Connecting…')).toBeNull();
    await advance(5_000 + 15_000 + 60_000);
    expect(server.calls('status')).toBe(4);
    // Never answered: no time of a last answer.
    expect(within(problemLine()).getByText('Server not reachable.', { selector: 'strong' }))
      .toBeTruthy();
    expect(within(problemLine()).queryByText(/Last answer/)).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: 'Check again' }));
    await settle();
    expect(server.calls('status')).toBe(5);
    expect(problemLine().textContent).toBe('Server not reachable. Trying again…');

    await advance(5_000 + 15_000 + 60_000);
    expect(server.calls('status')).toBe(8);
    expect(screen.getByRole('button', { name: 'Check again' })).toBeTruthy();
    await advance(60 * 60_000);
    expect(server.calls('status')).toBe(8);
  });
});
