import { fireEvent, screen, within } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import {
  autoScanJob,
  failedItem,
  itemRun,
  rejectedItem,
  sampleItem,
  sampleItemPage,
  sampleJob,
  fullServer,
  stage3Job,
} from '../../test/fixtures';
import { advance, renderPage, settle, installFakeClock } from '../../test/render';
import { JobPage } from './JobPage';
import { ACTIVE_REFRESH_MS, IDLE_REFRESH_MS, ITEMS_PAGE } from './live';

installFakeClock();

function jobCard() {
  return screen.getByRole('region', { name: 'Job' });
}

function itemsCard() {
  return screen.getByRole('region', { name: 'Items' });
}

function itemRows(): HTMLElement[] {
  return within(within(itemsCard()).getByRole('table')).getAllByRole('row').slice(1);
}

const doneJob = sampleJob({
  state: 'done',
  finished: '2026-11-14T09:32:00Z',
  counts: { queued: 0, building: 0, ready: 497, failed: 2, rejected: 1 },
});

describe('JobPage', () => {
  it('shows the facts, the progress and the items with their errors', async () => {
    const server = fullServer();
    await renderPage(<JobPage id={7} itemState={null} />, server);

    expect(server.urlOf('jobItems')).toBe(`api/v1/jobs/7/items?since=0&limit=${ITEMS_PAGE}`);
    expect(screen.getByRole('heading', { level: 1, name: 'Lightroom selection' })).toBeTruthy();
    expect(document.title).toBe('Lightroom selection · LR Remote Previews');

    const card = jobCard();
    expect(within(card).getByText('Active')).toBeTruthy();
    expect(card.textContent).toContain('lr-plugin/0.2.0');
    expect(card.textContent).toContain('c1f0a6e2-7d0b-4c55-9d0e-3f6a1b2c4d5e');
    expect(card.textContent).toContain('3 min ago');
    expect(card.textContent).toContain('Not yet');
    const bar = within(card).getByRole('progressbar');
    expect(bar.getAttribute('aria-valuenow')).toBe('192');
    expect(bar.getAttribute('aria-valuemax')).toBe('500');
    expect(card.textContent).toContain('192 of 500 items finished.');

    const rows = itemRows();
    expect(rows).toHaveLength(3);
    const [rejected, ready, failed] = rows as [HTMLElement, HTMLElement, HTMLElement];
    expect(rejected.textContent).toContain('notes.txt');
    expect(rejected.textContent).toContain('Rejected');
    expect(rejected.textContent).toContain('unsupported_format');
    expect(rejected.textContent).toContain('Not a camera raw file.');
    expect(ready.textContent).toContain('IMG_0001.ARW');
    expect(ready.textContent).toContain('archive · 2026/2026.06.20 - shoot');
    expect(ready.textContent).toContain('DNG 359 kB');
    expect(ready.textContent).toContain('original 6000 × 4000');
    expect(failed.textContent).toContain('converter_failed');
    expect(failed.textContent).toContain('The converter exited with code 1.');
    expect(failed.textContent).toContain('The converter could not convert the file.');
    expect(itemsCard().textContent).toContain('Items 1–3 of 500');
  });

  it('shows the priority: a background job is marked, a normal one only says so', async () => {
    const server = fullServer({ jobItems: sampleItemPage([], false, autoScanJob()) });
    await renderPage(<JobPage id={8} itemState={null} />, server);

    const header = jobCard().querySelector('.card__header');
    expect(Array.from(header?.querySelectorAll('.badge') ?? [], (b) => b.textContent)).toEqual([
      'Active',
      'Background',
    ]);
    const priority = within(jobCard()).getByText('Priority', { selector: 'dt' }).parentElement;
    expect(priority?.textContent).toBe('PriorityBackgroundBuilt when no normal job is waiting');
    expect(jobCard().textContent).toContain('Sent byAutomatic scan');

    server.reply('jobItems', sampleItemPage([], false, sampleJob()));
    await advance(ACTIVE_REFRESH_MS);
    expect(within(jobCard()).queryByText('Background')).toBeNull();
    expect(within(jobCard()).getByText('Priority', { selector: 'dt' }).parentElement?.textContent).toBe(
      'PriorityNormalBuilt in turn, oldest job first',
    );
  });

  it('shows no priority for a job from a server without priorities', async () => {
    const server = fullServer({ jobItems: sampleItemPage([], false, stage3Job()) });
    await renderPage(<JobPage id={7} itemState={null} />, server);
    expect(within(jobCard()).queryByText('Priority', { selector: 'dt' })).toBeNull();
    expect(within(jobCard()).getByText('Active')).toBeTruthy();
  });

  it('filters the items by state through links that show the counts', async () => {
    const server = fullServer({ jobItems: sampleItemPage([failedItem()]) });
    await renderPage(<JobPage id={7} itemState="failed" />, server);

    expect(server.queryOf('jobItems').get('state')).toBe('failed');
    const filters = within(itemsCard()).getByRole('navigation', { name: 'Filter items by state' });
    const failed = within(filters).getByRole('link', { name: /Failed/ });
    expect(failed.getAttribute('aria-current')).toBe('true');
    expect(failed.textContent).toBe('Failed2');
    expect(failed.getAttribute('href')).toBe('#/jobs/7?state=failed');
    expect(within(filters).getByRole('link', { name: /All/ }).getAttribute('href')).toBe('#/jobs/7');
    expect(itemRows()).toHaveLength(1);
    expect(itemsCard().textContent).toContain('Items 1–1 of 2');
  });

  it('says so when no item has the chosen state', async () => {
    const server = fullServer({ jobItems: sampleItemPage([]) });
    await renderPage(<JobPage id={7} itemState="rejected" />, server);
    expect(itemsCard().textContent).toContain('No rejected items.');
  });

  it('pages through the items with since and limit, one page in the table at a time', async () => {
    const server = fullServer();
    const job = sampleJob({ counts: { total: 150, queued: 150, building: 0, ready: 0, failed: 0 } });
    server.handle('jobItems', ({ query }) => {
      const since = Number(query.get('since'));
      return since === 0
        ? { body: sampleItemPage(itemRun(ITEMS_PAGE, 1), true, job) }
        : { body: sampleItemPage(itemRun(50, since + 1), false, job) };
    });
    await renderPage(<JobPage id={7} itemState={null} />, server);

    expect(itemRows()).toHaveLength(ITEMS_PAGE);
    expect(itemsCard().textContent).toContain('Items 1–100 of 150');
    const previous = within(itemsCard()).getByRole('button', { name: 'Previous' });
    expect(previous).toHaveProperty('disabled', true);

    fireEvent.click(within(itemsCard()).getByRole('button', { name: 'Next' }));
    await settle();
    expect(server.queryOf('jobItems', -1).get('since')).toBe('100');
    expect(itemRows()).toHaveLength(50);
    expect(itemRows()[0]?.textContent).toContain('IMG_0101.ARW');
    expect(itemsCard().textContent).toContain('Items 101–150 of 150');
    expect(within(itemsCard()).getByRole('button', { name: 'Next' })).toHaveProperty('disabled', true);

    // The page shown is the one refreshed while the job runs.
    await advance(ACTIVE_REFRESH_MS);
    expect(server.queryOf('jobItems', -1).get('since')).toBe('100');

    fireEvent.click(within(itemsCard()).getByRole('button', { name: 'Previous' }));
    await settle();
    expect(server.queryOf('jobItems', -1).get('since')).toBe('0');
    expect(itemRows()).toHaveLength(ITEMS_PAGE);
  });

  it('cancels only after a confirmation, and shows the job as cancelled', async () => {
    const server = fullServer();
    await renderPage(<JobPage id={7} itemState={null} />, server);

    fireEvent.click(within(jobCard()).getByRole('button', { name: 'Cancel job…' }));
    const confirm = within(jobCard()).getByRole('group', { name: 'Cancel this job?' });
    expect(confirm.textContent).toContain('300 queued items will not be built.');
    expect(confirm.textContent).toContain('8 items that are being built now finish');
    // Focus starts on the safe choice.
    expect(document.activeElement).toBe(within(confirm).getByRole('button', { name: 'Keep the job' }));

    fireEvent.click(within(confirm).getByRole('button', { name: 'Keep the job' }));
    expect(within(jobCard()).queryByRole('group')).toBeNull();
    expect(server.calls('cancelJob')).toBe(0);

    fireEvent.click(within(jobCard()).getByRole('button', { name: 'Cancel job…' }));
    const gate = server.hold('cancelJob');
    fireEvent.click(within(jobCard()).getByRole('button', { name: 'Cancel job' }));
    await settle();
    expect(server.calls('cancelJob')).toBe(1);
    expect(server.urlOf('cancelJob')).toBe('api/v1/jobs/7');
    expect(within(jobCard()).getByRole('button', { name: 'Cancel job' })).toHaveProperty(
      'disabled',
      true,
    );

    server.reply('jobItems', sampleItemPage(undefined, false, sampleJob({ state: 'cancelled' })));
    gate.release();
    await settle();
    expect(within(jobCard()).getByText('Cancelled', { selector: '.badge' })).toBeTruthy();
    expect(within(jobCard()).getByRole('status').textContent).toBe('The job was cancelled.');
    expect(within(jobCard()).queryByRole('button', { name: /Cancel job/ })).toBeNull();
  });

  it('shows the server error when cancelling fails', async () => {
    const server = fullServer();
    server.reply('cancelJob', { detail: 'The store is locked.' }, 500);
    await renderPage(<JobPage id={7} itemState={null} />, server);

    fireEvent.click(within(jobCard()).getByRole('button', { name: 'Cancel job…' }));
    fireEvent.click(within(jobCard()).getByRole('button', { name: 'Cancel job' }));
    await settle();

    const alert = within(jobCard()).getByRole('alert');
    expect(alert.textContent).toContain('Could not cancel the job.');
    expect(alert.textContent).toContain('The store is locked.');
    expect(within(jobCard()).getByRole('button', { name: 'Cancel job' })).toHaveProperty(
      'disabled',
      false,
    );
  });

  it('retries the failed items', async () => {
    const server = fullServer({ jobItems: sampleItemPage(undefined, false, doneJob) });
    await renderPage(<JobPage id={7} itemState={null} />, server);
    // A finished job cannot be cancelled.
    expect(within(jobCard()).queryByRole('button', { name: 'Cancel job…' })).toBeNull();

    const gate = server.hold('retryJob');
    fireEvent.click(within(jobCard()).getByRole('button', { name: 'Retry 2 failed items' }));
    await settle();
    expect(server.urlOf('retryJob')).toBe('api/v1/jobs/7/retry');
    expect(
      within(jobCard()).getByRole('button', { name: 'Retry 2 failed items' }),
    ).toHaveProperty('disabled', true);

    server.reply('jobItems', sampleItemPage([sampleItem()], false, sampleJob()));
    gate.release();
    await settle();
    expect(within(jobCard()).getByRole('status').textContent).toBe(
      '2 failed items are queued again.',
    );
    expect(within(jobCard()).getByText('Active')).toBeTruthy();
  });

  it('explains a refused retry', async () => {
    const server = fullServer({ jobItems: sampleItemPage(undefined, false, doneJob) });
    server.reply('retryJob', { detail: 'Job 7 is cancelled.', code: 'job_cancelled' }, 409);
    await renderPage(<JobPage id={7} itemState={null} />, server);

    fireEvent.click(within(jobCard()).getByRole('button', { name: 'Retry 2 failed items' }));
    await settle();
    const alert = within(jobCard()).getByRole('alert');
    expect(alert.textContent).toContain('A cancelled job cannot be retried.');
    expect(alert.textContent).toContain('Job 7 is cancelled.');
  });

  it('offers neither action for a cancelled job', async () => {
    const cancelled = sampleJob({ state: 'cancelled', counts: { queued: 0, building: 0 } });
    const server = fullServer({ jobItems: sampleItemPage([rejectedItem()], false, cancelled) });
    await renderPage(<JobPage id={7} itemState={null} />, server);
    expect(within(jobCard()).queryByRole('button')).toBeNull();
  });

  it('says so for a job the server does not have', async () => {
    const server = fullServer();
    server.reply('jobItems', { detail: 'No such job' }, 404);
    await renderPage(<JobPage id={99} itemState={null} />, server);

    expect(screen.getByRole('heading', { level: 1, name: 'Job 99' })).toBeTruthy();
    const panel = screen.getByRole('alert');
    expect(panel.textContent).toContain('Job 99 was not found');
    expect(within(panel).getByRole('link', { name: 'All jobs' }).getAttribute('href')).toBe('#/jobs');
  });

  it('refreshes every 2 s while the job is active and every 15 s once it is done', async () => {
    const server = fullServer();
    await renderPage(<JobPage id={7} itemState={null} />, server);
    await advance(ACTIVE_REFRESH_MS);
    expect(server.calls('jobItems')).toBe(2);

    server.reply('jobItems', sampleItemPage(undefined, false, doneJob));
    await advance(ACTIVE_REFRESH_MS);
    expect(server.calls('jobItems')).toBe(3);
    expect(within(jobCard()).getByText('Done with problems')).toBeTruthy();
    await advance(IDLE_REFRESH_MS - 1);
    expect(server.calls('jobItems')).toBe(3);
    await advance(1);
    expect(server.calls('jobItems')).toBe(4);
  });
});
