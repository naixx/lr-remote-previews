import { fireEvent, screen, within } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import { autoScanJob, sampleJob, sampleJobs, fullServer } from '../../test/fixtures';
import { advance, renderPage, settle, installFakeClock } from '../../test/render';
import { JobsPage } from './JobsPage';
import { ACTIVE_REFRESH_MS, IDLE_REFRESH_MS, JOBS_PAGE } from './live';

installFakeClock();

function jobRows(): HTMLElement[] {
  return Array.from(screen.getByRole('list', { name: 'Jobs' }).children) as HTMLElement[];
}

function manyJobs(n: number, state = 'done') {
  return {
    jobs: Array.from({ length: n }, (_, index) =>
      sampleJob({ id: 1000 - index, label: null, state, finished: '2026-11-14T09:00:00Z' }),
    ),
  };
}

describe('JobsPage', () => {
  it('lists the jobs newest first, each linking to its page', async () => {
    const server = fullServer();
    await renderPage(<JobsPage state={null} />, server);

    expect(server.urlOf('jobs')).toBe(`api/v1/jobs?limit=${JOBS_PAGE}`);
    expect(document.title).toBe('Jobs · LR Remote Previews');
    const rows = jobRows();
    expect(rows.map((row) => within(row).getByRole('heading').textContent)).toEqual([
      'Lightroom selection',
      'Job 6',
      'Shoot 2026-06-20',
    ]);
    expect(within(rows[1]!).getByRole('link', { name: 'Job 6' }).getAttribute('href')).toBe(
      '#/jobs/6',
    );
    expect(screen.getByRole('region', { name: 'All jobs' }).textContent).toContain('3 jobs');
    // Fewer jobs than asked for: there are no more to load.
    expect(screen.queryByRole('button', { name: 'Load more' })).toBeNull();
  });

  it('marks background jobs and names the automatic scan as their sender', async () => {
    const server = fullServer({ jobs: { jobs: [autoScanJob(), sampleJob()] } });
    await renderPage(<JobsPage state={null} />, server);

    const [scan, plugin] = jobRows() as [HTMLElement, HTMLElement];
    expect(within(scan).getByRole('heading').textContent).toBe('Automatic scan: archive');
    expect(within(scan).getByText('Background', { selector: '.badge' })).toBeTruthy();
    expect(within(scan).getByText('Job 8 · Automatic scan')).toBeTruthy();
    // Normal priority needs no badge.
    expect(within(plugin).queryByText('Background')).toBeNull();
    expect(Array.from(plugin.querySelectorAll('.job__head .badge'), (b) => b.textContent)).toEqual([
      'Active',
    ]);
  });

  it('filters by state with links that keep the filter in the address', async () => {
    const server = fullServer({ jobs: { jobs: [sampleJob()] } });
    await renderPage(<JobsPage state="active" />, server);

    expect(server.queryOf('jobs').get('state')).toBe('active');
    const filters = screen.getByRole('navigation', { name: 'Filter jobs by state' });
    const current = within(filters).getByRole('link', { name: 'Active' });
    expect(current.getAttribute('aria-current')).toBe('true');
    expect(current.getAttribute('href')).toBe('#/jobs?state=active');
    expect(within(filters).getByRole('link', { name: 'All' }).getAttribute('href')).toBe('#/jobs');
    expect(within(filters).getByRole('link', { name: 'All' }).getAttribute('aria-current')).toBeNull();
  });

  it('says so when a filter matches nothing', async () => {
    const server = fullServer({ jobs: { jobs: [] } });
    await renderPage(<JobsPage state="cancelled" />, server);
    expect(screen.getByText('No job was cancelled.')).toBeTruthy();
  });

  it('loads more with a larger limit and keeps the list on screen meanwhile', async () => {
    const server = fullServer({ jobs: manyJobs(JOBS_PAGE) });
    await renderPage(<JobsPage state={null} />, server);
    expect(jobRows()).toHaveLength(JOBS_PAGE);

    const gate = server.hold('jobs');
    server.reply('jobs', manyJobs(JOBS_PAGE + 20));
    fireEvent.click(screen.getByRole('button', { name: 'Load more' }));
    await settle();

    expect(server.queryOf('jobs', -1).get('limit')).toBe(String(JOBS_PAGE * 2));
    expect(jobRows()).toHaveLength(JOBS_PAGE);
    expect(screen.getByRole('button', { name: 'Loading…' })).toHaveProperty('disabled', true);

    gate.release();
    await settle();
    expect(jobRows()).toHaveLength(JOBS_PAGE + 20);
    expect(screen.queryByRole('button', { name: 'Load more' })).toBeNull();
  });

  it('refreshes every 2 s while a job is active and every 15 s otherwise', async () => {
    const server = fullServer();
    await renderPage(<JobsPage state={null} />, server);
    expect(server.calls('jobs')).toBe(1);

    await advance(ACTIVE_REFRESH_MS);
    expect(server.calls('jobs')).toBe(2);

    server.reply('jobs', { jobs: sampleJobs().jobs.slice(1) });
    await advance(ACTIVE_REFRESH_MS);
    expect(server.calls('jobs')).toBe(3);
    await advance(ACTIVE_REFRESH_MS);
    expect(server.calls('jobs')).toBe(3);
    await advance(IDLE_REFRESH_MS - ACTIVE_REFRESH_MS);
    expect(server.calls('jobs')).toBe(4);
  });

  it('reports a failure before any data and retries on request', async () => {
    const server = fullServer();
    server.reply('jobs', { detail: 'Internal error' }, 500);
    await renderPage(<JobsPage state={null} />, server);

    const alert = screen.getByRole('alert');
    expect(alert.textContent).toContain('Jobs could not be loaded');
    expect(alert.textContent).toContain('HTTP 500');

    server.reply('jobs', sampleJobs());
    fireEvent.click(within(alert).getByRole('button', { name: 'Retry' }));
    await settle();
    expect(jobRows()).toHaveLength(3);
  });

  it('keeps the list when a refresh fails, and says so', async () => {
    const server = fullServer();
    await renderPage(<JobsPage state={null} />, server);
    server.failNetwork('jobs');
    await advance(ACTIVE_REFRESH_MS);

    expect(screen.getByRole('status').textContent).toContain('Connection lost, retrying…');
    expect(jobRows()).toHaveLength(3);
  });
});
