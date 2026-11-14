import { act, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiProvider } from '../../app/ApiProvider';
import { Layout } from '../../app/Layout';
import {
  busyStatus,
  fakeServer,
  idleStatus,
  installedInfo,
  legacyStatus,
  sampleInfo,
  sampleJobs,
  sampleSettings,
  scheduledScan,
  stage3Status,
  type FakeServer,
} from '../../test/fixtures';
import { BUSY_REFRESH_MS, IDLE_REFRESH_MS } from './live';
import { OverviewPage } from './OverviewPage';

// Three minutes after the newest sample job was created.
const NOW = new Date('2026-11-14T09:33:00Z');

beforeEach(() => {
  // Only the timers the dashboard uses; promises and fetch bodies resolve as usual.
  vi.useFakeTimers({
    toFake: ['setTimeout', 'clearTimeout', 'setInterval', 'clearInterval', 'Date'],
  });
  vi.setSystemTime(NOW);
});

afterEach(() => {
  vi.useRealTimers();
});

/** Moves the fake clock and lets every request and render that follows settle. */
async function advance(ms: number) {
  await act(async () => {
    await vi.advanceTimersByTimeAsync(ms);
  });
}

/** Lets the requests in flight finish without moving the clock. */
async function settle() {
  for (let round = 0; round < 5; round += 1) await advance(0);
}

async function renderOverview(server: FakeServer) {
  render(
    <ApiProvider fetch={server.fetch}>
      <Layout>
        <OverviewPage />
      </Layout>
    </ApiProvider>,
  );
  await settle();
}

function busyServer() {
  return fakeServer({ info: installedInfo(), status: busyStatus(), jobs: sampleJobs() });
}

function idleServer() {
  return fakeServer({ info: installedInfo(), status: idleStatus(), jobs: { jobs: [] } });
}

function queueCard() {
  return screen.getByRole('region', { name: 'Queue' });
}

/** The text of one figure of the Queue card, found by its label. */
function stat(label: string): string {
  const term = within(queueCard()).getByText(label, { selector: 'dt' });
  return term.parentElement?.textContent ?? '';
}

/** The job rows only, not the count items nested in them. */
function jobRows(): HTMLElement[] {
  const list = screen.getByRole('list', { name: 'Recent jobs' });
  return Array.from(list.children) as HTMLElement[];
}

function visibility() {
  return vi.spyOn(document, 'visibilityState', 'get');
}

function announceVisibility() {
  act(() => {
    document.dispatchEvent(new Event('visibilitychange'));
  });
}

describe('Queue card', () => {
  it('shows the work in progress', async () => {
    await renderOverview(busyServer());

    expect(within(queueCard()).getByText('Running', { selector: '.badge' })).toBeTruthy();
    expect(queueCard().textContent).toContain('Building, about 2 min left.');
    expect(queueCard().textContent).toContain('308 left · CPU 68 °C');
    expect(stat('Queued')).toContain('300');
    expect(stat('Building')).toContain('8');
    expect(stat('Processes busy')).toContain('4 of 4');
    expect(stat('Rate')).toContain('173 photos/min');
    expect(stat('Rate')).toContain('over the last 60 s');
    expect(stat('Today')).toContain('1,234 built');
    expect(stat('Today')).toContain('2 failed');
    expect(stat('Cache')).toContain('2.9 GB');
    expect(stat('Cache')).toContain('5,321 files');
    expect(within(queueCard()).queryByText(/cannot be built/)).toBeNull();
  });

  it('shows an idle server', async () => {
    await renderOverview(idleServer());

    expect(within(queueCard()).getByText('Idle', { selector: '.badge' })).toBeTruthy();
    expect(stat('Rate')).toContain('Idle');
    expect(stat('Rate')).not.toContain('photos/min');
    expect(stat('Queued')).toContain('0');
    expect(stat('Processes busy')).toContain('0 of 4');
    expect(stat('Today')).toContain('none failed');
  });

  it('says that jobs cannot be built while the converter is missing', async () => {
    const server = fakeServer({ info: sampleInfo(), status: idleStatus(), jobs: { jobs: [] } });
    await renderOverview(server);

    expect(within(queueCard()).getByText('Converter missing')).toBeTruthy();
    expect(queueCard().textContent).toContain(
      'Jobs cannot be built until Adobe DNG Converter is installed on the server.',
    );
    // The figures are still shown.
    expect(stat('Cache')).toContain('3.0 GB');
  });
});

describe('Automatic scan line', () => {
  function scanLine(): string {
    return queueCard().querySelector('.queue-autoscan')?.textContent ?? '';
  }

  it('says when the next scan is due and what the last one queued', async () => {
    await renderOverview(busyServer());
    expect(scanLine()).toMatch(
      /^Automatic scan: next at .+ \(in 27 min\) · last at .+ \(33 min ago\), 120 files queued$/,
    );
    const link = within(queueCard()).getByRole('link', { name: 'Automatic scan' });
    expect(link.getAttribute('href')).toBe('#/settings');
    const times = queueCard().querySelectorAll('.queue-autoscan time');
    expect(Array.from(times, (time) => time.getAttribute('dateTime'))).toEqual([
      '2026-11-14T10:00:00Z',
      '2026-11-14T09:00:00Z',
    ]);
  });

  it('says when the scan is off or running', async () => {
    const server = idleServer();
    await renderOverview(server);
    expect(scanLine()).toBe('Automatic scan: off');

    server.reply('status', { ...idleStatus(), autoScan: scheduledScan({ nextRun: null }) });
    await advance(IDLE_REFRESH_MS);
    expect(scanLine()).toMatch(
      /^Automatic scan: off · last at .+ \(33 min ago\), 120 files queued$/,
    );

    server.reply('status', { ...idleStatus(), autoScan: scheduledScan({ running: true }) });
    await advance(IDLE_REFRESH_MS);
    expect(scanLine()).toBe('Automatic scan: running now');
  });

  it('leaves the line out for a server without the automatic scan', async () => {
    await renderOverview(
      fakeServer({ info: installedInfo(), status: stage3Status(), jobs: sampleJobs() }),
    );
    expect(stat('Queued')).toContain('300');
    expect(queueCard().querySelector('.queue-autoscan')).toBeNull();
  });
});

describe('Server state and pausing', () => {
  function serverWith(status: unknown, settings: unknown = sampleSettings()) {
    return fakeServer({ info: installedInfo(), status, jobs: sampleJobs(), settings });
  }

  it('names each state plainly', async () => {
    const server = serverWith({ ...busyStatus(), state: 'waiting', etaSeconds: null });
    await renderOverview(server);
    expect(within(queueCard()).getByText('Waiting for working hours')).toBeTruthy();
    expect(queueCard().textContent).toContain('building starts when the working hours begin');

    server.reply('status', { ...busyStatus(), etaSeconds: null });
    await advance(BUSY_REFRESH_MS);
    expect(within(queueCard()).getByText('Running', { selector: '.badge' })).toBeTruthy();
    expect(queueCard().textContent).toContain('The time left is not known yet.');

    server.reply('status', { ...busyStatus(), etaSeconds: 8100 });
    await advance(BUSY_REFRESH_MS);
    expect(queueCard().textContent).toContain('about 2 h 15 min left');

    server.reply('status', idleStatus());
    await advance(BUSY_REFRESH_MS);
    expect(queueCard().textContent).toContain('Nothing is queued.');
    // No temperature from this server: none shown.
    expect(queueCard().textContent).not.toContain('°C');
  });

  it('pauses: the button is disabled while the request runs, then shows Resume', async () => {
    const server = serverWith(busyStatus());
    await renderOverview(server);

    const gate = server.hold('updateSettings');
    server.reply('updateSettings', sampleSettings({ paused: true }));
    fireEvent.click(within(queueCard()).getByRole('button', { name: 'Pause' }));
    await settle();
    expect(server.bodyOf('updateSettings')).toEqual({ paused: true });
    expect(within(queueCard()).getByRole('button', { name: 'Pause' })).toHaveProperty(
      'disabled',
      true,
    );

    // The server now reports the pause; the answer to the change starts a refresh at once.
    server.reply('status', { ...busyStatus(), state: 'paused', etaSeconds: null });
    server.reply('settings', sampleSettings({ paused: true }));
    const before = server.calls('status');
    gate.release();
    await settle();

    expect(server.calls('status')).toBe(before + 1);
    expect(within(queueCard()).getByText('Paused', { selector: '.badge' })).toBeTruthy();
    expect(queueCard().textContent).toContain('no new wave of conversions starts');
    const resume = within(queueCard()).getByRole('button', { name: 'Resume' });
    expect(resume).toHaveProperty('disabled', false);

    server.reply('updateSettings', sampleSettings({ paused: false }));
    server.reply('status', busyStatus());
    server.reply('settings', sampleSettings({ paused: false }));
    fireEvent.click(resume);
    await settle();
    expect(server.bodyOf('updateSettings', -1)).toEqual({ paused: false });
    expect(within(queueCard()).getByRole('button', { name: 'Pause' })).toBeTruthy();
    expect(within(queueCard()).getByText('Running', { selector: '.badge' })).toBeTruthy();
  });

  it('shows the server error when pausing fails', async () => {
    const server = serverWith(busyStatus());
    server.reply('updateSettings', { detail: 'The database is read-only.' }, 500);
    await renderOverview(server);

    fireEvent.click(within(queueCard()).getByRole('button', { name: 'Pause' }));
    await settle();

    const alert = within(queueCard()).getByRole('alert');
    expect(alert.textContent).toContain('Could not pause.');
    expect(alert.textContent).toContain('The database is read-only.');
    expect(within(queueCard()).getByRole('button', { name: 'Pause' })).toHaveProperty(
      'disabled',
      false,
    );
  });

  it('works with a server older than the dashboard', async () => {
    // No state, time left or temperature in the status, and no settings endpoint.
    const server = fakeServer({ info: installedInfo(), status: legacyStatus(), jobs: sampleJobs() });
    await renderOverview(server);

    expect(within(queueCard()).getByText('Running', { selector: '.badge' })).toBeTruthy();
    expect(queueCard().textContent).toContain('The time left is not known yet.');
    expect(queueCard().textContent).toContain('older than the dashboard and cannot be paused');
    expect(within(queueCard()).queryByRole('button', { name: 'Pause' })).toBeNull();
    expect(stat('Queued')).toContain('300');
  });
});

describe('Jobs card', () => {
  it('lists the most recent jobs, newest first, with their progress', async () => {
    const server = busyServer();
    await renderOverview(server);

    expect(server.urlOf('jobs')).toBe('api/v1/jobs?limit=10');
    const rows = jobRows();
    expect(rows).toHaveLength(3);
    const [active, done, cancelled] = rows as [HTMLElement, HTMLElement, HTMLElement];

    // Active job with a label: the label is the title, the id goes next to the client.
    expect(within(active).getByRole('heading', { name: 'Lightroom selection' })).toBeTruthy();
    expect(
      within(active).getByRole('link', { name: 'Lightroom selection' }).getAttribute('href'),
    ).toBe('#/jobs/7');
    expect(within(active).getByText('Active')).toBeTruthy();
    expect(within(active).getByText('Job 7 · lr-plugin/0.2.0')).toBeTruthy();
    expect(within(active).getByText('3 min ago')).toBeTruthy();
    expect(active.querySelector('time')?.getAttribute('dateTime')).toBe('2026-11-14T09:30:00Z');
    const bar = within(active).getByRole('progressbar', { name: 'Progress of Lightroom selection' });
    expect(bar.getAttribute('aria-valuenow')).toBe('192');
    expect(bar.getAttribute('aria-valuemax')).toBe('500');
    expect(bar.getAttribute('aria-valuetext')).toBe('192 of 500 finished: 190 ready, 2 failed');
    expect(active.textContent).toContain('192 / 500');
    const counts = within(within(active).getByRole('list')).getAllByRole('listitem');
    expect(counts.map((item) => item.textContent)).toEqual([
      '190 ready',
      '2 failed',
      '8 building',
      '300 queued',
    ]);
    // Failed items are drawn apart from ready ones.
    expect(bar.querySelector('.progress__part--ready')).not.toBeNull();
    expect(bar.querySelector('.progress__part--failed')).not.toBeNull();

    // Finished job without a label: "Job 6"; problems are named in the badge.
    expect(within(done).getByRole('heading', { name: 'Job 6' })).toBeTruthy();
    expect(within(done).getByText('Done with problems')).toBeTruthy();
    expect(within(done).getByText('lr-plugin/0.2.0')).toBeTruthy();
    expect(within(done).getByText('1 h ago')).toBeTruthy();
    expect(done.textContent).toContain('120 / 120');
    expect(done.textContent).toContain('1 failed');
    expect(done.textContent).toContain('2 rejected');
    expect(within(done).getByRole('progressbar').querySelector('.progress__part--rejected')).not
      .toBeNull();

    // Cancelled job without a client.
    expect(within(cancelled).getByRole('heading', { name: 'Shoot 2026-06-20' })).toBeTruthy();
    expect(within(cancelled).getByText('Cancelled')).toBeTruthy();
    expect(within(cancelled).getByText('Job 5')).toBeTruthy();
    expect(within(cancelled).getByText('15 h ago')).toBeTruthy();
    expect(cancelled.textContent).toContain('80 / 80');
    expect(cancelled.textContent).toContain('40 cancelled');
  });

  it('says so when there are no jobs', async () => {
    await renderOverview(idleServer());

    const jobs = screen.getByRole('region', { name: 'Jobs' });
    expect(jobs.textContent).toContain('No jobs yet.');
    expect(within(jobs).queryByRole('list')).toBeNull();
  });
});

describe('refreshing', () => {
  it('refreshes every 2 s while busy and every 10 s when idle', async () => {
    const server = busyServer();
    await renderOverview(server);
    expect(server.calls('status')).toBe(1);

    await advance(BUSY_REFRESH_MS - 1);
    expect(server.calls('status')).toBe(1);
    await advance(1);
    expect(server.calls('status')).toBe(2);

    // The next answer says the queue is empty: the refresh after it waits 10 s.
    server.reply('status', idleStatus());
    await advance(BUSY_REFRESH_MS);
    expect(server.calls('status')).toBe(3);
    expect(stat('Rate')).toContain('Idle');
    await advance(BUSY_REFRESH_MS);
    expect(server.calls('status')).toBe(3);
    await advance(IDLE_REFRESH_MS - BUSY_REFRESH_MS);
    expect(server.calls('status')).toBe(4);

    // Work arrives: the first refresh that sees it speeds the polling up again.
    server.reply('status', busyStatus());
    await advance(IDLE_REFRESH_MS);
    expect(server.calls('status')).toBe(5);
    await advance(BUSY_REFRESH_MS);
    expect(server.calls('status')).toBe(6);

    // Status and jobs are refreshed together.
    expect(server.calls('jobs')).toBe(6);
  });

  it('pauses while the page is hidden and refreshes at once when it is shown', async () => {
    const server = busyServer();
    await renderOverview(server);
    expect(server.calls('status')).toBe(1);

    const state = visibility();
    state.mockReturnValue('hidden');
    announceVisibility();
    await advance(60_000);
    expect(server.calls('status')).toBe(1);

    state.mockReturnValue('visible');
    announceVisibility();
    await settle();
    expect(server.calls('status')).toBe(2);
    await advance(BUSY_REFRESH_MS);
    expect(server.calls('status')).toBe(3);
  });

  it('never starts a refresh while the previous one is still running', async () => {
    const server = busyServer();
    await renderOverview(server);

    server.hang('status');
    await advance(BUSY_REFRESH_MS);
    expect(server.calls('status')).toBe(2);

    await advance(60_000);
    expect(server.calls('status')).toBe(2);
    expect(server.calls('jobs')).toBe(2);

    // Coming back to the tab does not start a second request next to the one in flight.
    const state = visibility();
    state.mockReturnValue('hidden');
    announceVisibility();
    state.mockReturnValue('visible');
    announceVisibility();
    await settle();
    expect(server.calls('status')).toBe(2);
  });

  it('keeps the last data on screen when a refresh fails, and says so', async () => {
    const server = busyServer();
    await renderOverview(server);
    expect(screen.queryByRole('status')).toBeNull();

    server.failNetwork('status');
    await advance(BUSY_REFRESH_MS);

    const note = screen.getByRole('status');
    expect(note.textContent).toContain('Connection lost, retrying…');
    expect(note.textContent).toContain('Showing data from');
    expect(stat('Queued')).toContain('300');
    expect(jobRows()).toHaveLength(3);

    // It keeps trying at the same pace, and the note goes once a refresh succeeds.
    server.reply('status', busyStatus());
    await advance(BUSY_REFRESH_MS);
    expect(screen.queryByRole('status')).toBeNull();
    expect(server.calls('status')).toBe(3);
  });

  it('names a server error in the note', async () => {
    const server = busyServer();
    await renderOverview(server);

    server.reply('jobs', { detail: 'Internal error' }, 500);
    await advance(BUSY_REFRESH_MS);

    expect(screen.getByRole('status').textContent).toContain(
      'Could not refresh: The server answered with HTTP 500. Retrying…',
    );
    expect(stat('Queued')).toContain('300');
  });

  it('reports a failure before any data arrived and offers a retry', async () => {
    const server = idleServer();
    server.reply('status', { detail: 'Not Found' }, 404);
    await renderOverview(server);

    const alert = within(queueCard()).getByRole('alert');
    expect(alert.textContent).toContain('Queue and jobs could not be loaded');
    expect(alert.textContent).toContain('HTTP 404');
    expect(alert.textContent).toContain('older than this dashboard');
    expect(screen.queryByRole('region', { name: 'Jobs' })).toBeNull();
    // The rest of the overview is unaffected.
    expect(screen.getByRole('region', { name: 'Server' })).toBeTruthy();

    server.reply('status', idleStatus());
    fireEvent.click(within(alert).getByRole('button', { name: 'Retry now' }));
    await settle();

    expect(stat('Rate')).toContain('Idle');
    expect(screen.getByRole('region', { name: 'Jobs' }).textContent).toContain('No jobs yet.');
  });

  it('asks for the token when the server starts refusing it, and stops polling', async () => {
    const server = busyServer();
    await renderOverview(server);

    server.reply('status', { detail: 'Missing or invalid token.' }, 401);
    server.reply('jobs', { detail: 'Missing or invalid token.' }, 401);
    await advance(BUSY_REFRESH_MS);

    expect(screen.getByRole('heading', { name: 'Access token required' })).toBeTruthy();
    expect(screen.queryByRole('region', { name: 'Queue' })).toBeNull();
    const calls = server.calls('status');
    await advance(60_000);
    expect(server.calls('status')).toBe(calls);

    // Not even when the tab is shown again: only a new token starts it over.
    const state = visibility();
    state.mockReturnValue('hidden');
    announceVisibility();
    state.mockReturnValue('visible');
    announceVisibility();
    await settle();
    expect(server.calls('status')).toBe(calls);
  });
});
