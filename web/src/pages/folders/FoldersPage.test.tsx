import { act, fireEvent, screen, within } from '@testing-library/react';
import { afterEach, describe, expect, it } from 'vitest';
import { CurrentPage } from '../../app/App';
import {
  sampleBrowse,
  sampleInfo,
  sampleJob,
  shootBrowse,
  stage3Server,
} from '../../test/fixtures';
import { renderPage, settle, installFakeClock } from '../../test/render';
import { FoldersPage } from './FoldersPage';

installFakeClock();

afterEach(() => {
  window.location.hash = '';
});

function folderCard() {
  return screen.getByRole('region', { name: 'This folder' });
}

function fact(label: string): string {
  const term = within(folderCard()).getByText(label, { selector: 'dt' });
  return term.parentElement?.textContent ?? '';
}

async function openQueueConfirmation() {
  fireEvent.click(within(folderCard()).getByRole('button', { name: 'Queue this folder…' }));
  await settle();
  return within(folderCard()).getByRole('group', { name: /^Queue «/ });
}

describe('FoldersPage: roots', () => {
  it('lists the roots; an unavailable one is named but not a link', async () => {
    const server = stage3Server();
    await renderPage(<FoldersPage root={null} path="" />, server);

    const roots = screen.getByRole('list', { name: 'Roots' });
    const [archive, offsite] = within(roots).getAllByRole('listitem') as [HTMLElement, HTMLElement];
    expect(within(archive).getByRole('link', { name: 'Archive' }).getAttribute('href')).toBe(
      '#/folders/archive',
    );
    expect(within(archive).getByText('Available')).toBeTruthy();
    expect(within(offsite).queryByRole('link')).toBeNull();
    expect(within(offsite).getByText('Unavailable')).toBeTruthy();
    expect(screen.getByText(/missing on the server right now/)).toBeTruthy();
    expect(server.calls('browse')).toBe(0);
  });

  it('says so when the server has no roots', async () => {
    const server = stage3Server({ info: { ...sampleInfo(), roots: [] } });
    await renderPage(<FoldersPage root={null} path="" />, server);
    expect(screen.getByText('No roots configured')).toBeTruthy();
  });
});

describe('FoldersPage: browsing', () => {
  it('shows a folder with its counts, its sub-folders and a breadcrumb', async () => {
    const server = stage3Server();
    await renderPage(<FoldersPage root="archive" path="2026" />, server);

    expect(server.urlOf('browse')).toBe('api/v1/browse?root=archive&path=2026');
    expect(document.title).toBe('2026 · Folders · LR Remote Previews');
    const crumbs = within(screen.getByRole('navigation', { name: 'Breadcrumb' })).getAllByRole(
      'listitem',
    );
    expect(crumbs.map((crumb) => crumb.textContent)).toEqual(['Roots', 'Archive', '2026']);
    expect(within(crumbs[0]!).getByRole('link').getAttribute('href')).toBe('#/folders');
    expect(within(crumbs[1]!).getByRole('link').getAttribute('href')).toBe('#/folders/archive');
    expect(within(crumbs[2]!).queryByRole('link')).toBeNull();
    expect(within(crumbs[2]!).getByText('2026').getAttribute('aria-current')).toBe('page');

    expect(fact('Raw files')).toContain('0');
    expect(fact('Other files')).toContain('12');
    expect(fact('Sub-folders')).toContain('2');

    const subfolders = screen.getByRole('list', { name: 'Sub-folders' });
    expect(
      within(subfolders)
        .getAllByRole('link')
        .map((link) => [link.textContent, link.getAttribute('href')]),
    ).toEqual([
      ['2026.06.20 - shoot', '#/folders/archive/2026/2026.06.20%20-%20shoot'],
      ['2026.07.04 - trip', '#/folders/archive/2026/2026.07.04%20-%20trip'],
    ]);
    expect(screen.getByRole('link', { name: 'Up one level' }).getAttribute('href')).toBe(
      '#/folders/archive',
    );
  });

  it('follows a link into a sub-folder, and back through the breadcrumb', async () => {
    window.location.hash = '#/folders/archive/2026';
    const server = stage3Server();
    server.handle('browse', ({ query }) =>
      query.get('path') === '2026/2026.06.20 - shoot'
        ? { body: shootBrowse() }
        : { body: sampleBrowse() },
    );
    await renderPage(<CurrentPage />, server);
    expect(fact('Sub-folders')).toContain('2');

    act(() => {
      window.location.hash = '#/folders/archive/2026/2026.06.20%20-%20shoot';
      window.dispatchEvent(new HashChangeEvent('hashchange'));
    });
    await settle();
    expect(server.queryOf('browse', -1).get('path')).toBe('2026/2026.06.20 - shoot');
    expect(fact('Raw files')).toContain('384');
    expect(fact('Already built')).toContain('120');
    expect(fact('Already built')).toContain('264 still to build');
    const crumbs = within(screen.getByRole('navigation', { name: 'Breadcrumb' })).getAllByRole(
      'link',
    );
    expect(crumbs.map((crumb) => crumb.getAttribute('href'))).toEqual([
      '#/folders',
      '#/folders/archive',
      '#/folders/archive/2026',
    ]);
    expect(screen.getByText('No sub-folders.')).toBeTruthy();
  });

  it('shows the root itself without an «up» link', async () => {
    const server = stage3Server({ browse: sampleBrowse({ path: '', parent: null }) });
    await renderPage(<FoldersPage root="archive" path="" />, server);
    expect(server.urlOf('browse')).toBe('api/v1/browse?root=archive');
    expect(screen.queryByRole('link', { name: 'Up one level' })).toBeNull();
  });

  it('says so for an empty folder and a cut list', async () => {
    const server = stage3Server({
      browse: sampleBrowse({ dirs: [], rawFiles: 0, builtFiles: 0, otherFiles: 0 }),
    });
    await renderPage(<FoldersPage root="archive" path="2026" />, server);
    expect(folderCard().textContent).toContain('This folder is empty');
  });

  it('warns that a long list was cut', async () => {
    const server = stage3Server({ browse: sampleBrowse({ truncated: true }) });
    await renderPage(<FoldersPage root="archive" path="2026" />, server);
    expect(screen.getByText(/more than 5,000 sub-folders/)).toBeTruthy();
  });

  it('explains an unavailable root', async () => {
    const server = stage3Server();
    server.reply('browse', { detail: 'Root offsite is not mounted.', code: 'root_unavailable' }, 404);
    await renderPage(<FoldersPage root="offsite" path="" />, server);

    const panel = screen.getByRole('alert');
    expect(panel.textContent).toContain('Root not available');
    expect(panel.textContent).toContain('the volume is not mounted');
    expect(panel.textContent).toContain('Server message: Root offsite is not mounted.');
    expect(within(panel).getByRole('link', { name: 'Back to the roots' })).toBeTruthy();
  });

  it('explains a folder that is gone', async () => {
    const server = stage3Server();
    server.reply('browse', { detail: 'No such folder', code: 'not_found' }, 404);
    await renderPage(<FoldersPage root="archive" path="2026/old" />, server);
    const panel = screen.getByRole('alert');
    expect(panel.textContent).toContain('Folder not found');
    expect(within(panel).getByRole('link', { name: 'Up one level' }).getAttribute('href')).toBe(
      '#/folders/archive/2026',
    );
  });

  it('says that an older server has no folder browser', async () => {
    const server = stage3Server();
    server.reply('browse', { detail: 'Not Found' }, 404);
    await renderPage(<FoldersPage root="archive" path="2026" />, server);
    expect(screen.getByText('This server is older than the dashboard')).toBeTruthy();
    expect(screen.getByText(/does not offer a folder browser/)).toBeTruthy();
  });
});

describe('FoldersPage: queueing a folder', () => {
  it('asks first, saying what will happen, then queues and links the job', async () => {
    const server = stage3Server({ browse: shootBrowse() });
    await renderPage(<FoldersPage root="archive" path="2026/2026.06.20 - shoot" />, server);

    const confirm = await openQueueConfirmation();
    expect(confirm.textContent).toContain('the 384 raw files directly in this folder');
    expect(confirm.textContent).toContain('120 already have their DNG and are ready at once');
    expect(confirm.textContent).toContain('The converter builds the other 264 files.');
    expect(server.calls('queueFolder')).toBe(0);

    const gate = server.hold('queueFolder');
    fireEvent.click(within(confirm).getByRole('button', { name: 'Queue' }));
    await settle();
    expect(server.bodyOf('queueFolder')).toEqual({
      root: 'archive',
      path: '2026/2026.06.20 - shoot',
      recursive: false,
    });
    expect(within(confirm).getByRole('button', { name: 'Queue' })).toHaveProperty('disabled', true);

    gate.release();
    await settle();
    const result = within(folderCard()).getByRole('status');
    expect(result.textContent).toContain('Queued 384 raw files, 120 of them already built.');
    expect(within(result).getByRole('link', { name: 'Job 12' }).getAttribute('href')).toBe(
      '#/jobs/12',
    );
    expect(within(folderCard()).queryByRole('group')).toBeNull();
    // The folder is read again, so its counts follow.
    expect(server.calls('browse')).toBe(2);
  });

  it('queues the sub-folders too when asked, and lists every job made', async () => {
    const server = stage3Server({ browse: shootBrowse({ dirs: sampleBrowse().dirs }) });
    server.reply('queueFolder', {
      files: 6200,
      alreadyBuilt: 0,
      jobs: [
        sampleJob({ id: 20, counts: { total: 5000 } }),
        sampleJob({ id: 21, counts: { total: 1200 } }),
      ],
    });
    await renderPage(<FoldersPage root="archive" path="2026/2026.06.20 - shoot" />, server);

    fireEvent.click(within(folderCard()).getByRole('checkbox', { name: 'Include sub-folders' }));
    const confirm = await openQueueConfirmation();
    expect(confirm.textContent).toContain('and in all its sub-folders');
    expect(confirm.textContent).toContain('More than 5,000 files are split into several jobs.');
    expect(confirm.textContent).toContain('More than 50,000 files are refused.');
    fireEvent.click(within(confirm).getByRole('button', { name: 'Queue' }));
    await settle();

    expect(server.bodyOf('queueFolder')).toMatchObject({ recursive: true });
    const result = within(folderCard()).getByRole('status');
    expect(result.textContent).toContain('Queued 6,200 raw files.');
    expect(result.textContent).toContain('Job 20 (5,000 files), Job 21 (1,200 files)');
  });

  it('cannot queue a folder without raw files unless sub-folders are included', async () => {
    const server = stage3Server();
    await renderPage(<FoldersPage root="archive" path="2026" />, server);

    const button = within(folderCard()).getByRole('button', { name: 'Queue this folder…' });
    expect(button).toHaveProperty('disabled', true);
    expect(folderCard().textContent).toContain('Tick «Include sub-folders» to queue the files below it.');
    fireEvent.click(within(folderCard()).getByRole('checkbox', { name: 'Include sub-folders' }));
    expect(button).toHaveProperty('disabled', false);
  });

  it('says so when nothing was found to queue', async () => {
    const server = stage3Server({ queueFolder: { files: 0, alreadyBuilt: 0, jobs: [] } });
    await renderPage(<FoldersPage root="archive" path="2026" />, server);
    fireEvent.click(within(folderCard()).getByRole('checkbox', { name: 'Include sub-folders' }));
    const confirm = await openQueueConfirmation();
    fireEvent.click(within(confirm).getByRole('button', { name: 'Queue' }));
    await settle();
    expect(within(folderCard()).getByRole('status').textContent).toContain(
      'No raw files were found in this folder or its sub-folders; nothing was queued.',
    );
  });

  it('explains too many files', async () => {
    const server = stage3Server({ browse: shootBrowse() });
    server.reply('queueFolder', { detail: '61,234 raw files found.', code: 'too_many_files' }, 422);
    await renderPage(<FoldersPage root="archive" path="2026/2026.06.20 - shoot" />, server);

    const confirm = await openQueueConfirmation();
    fireEvent.click(within(confirm).getByRole('button', { name: 'Queue' }));
    await settle();
    const alert = within(folderCard()).getByRole('alert');
    expect(alert.textContent).toContain('The folder was not queued.');
    expect(alert.textContent).toContain('Queue the sub-folders one at a time instead.');
    expect(alert.textContent).toContain('61,234 raw files found.');
    // The confirmation stays, so the person can go back.
    expect(within(confirm).getByRole('button', { name: 'Queue' })).toHaveProperty('disabled', false);
  });

  it('explains a missing converter', async () => {
    const server = stage3Server({ info: sampleInfo(), browse: shootBrowse() });
    server.reply(
      'queueFolder',
      { detail: 'Adobe DNG Converter is not installed.', code: 'converter_not_installed' },
      409,
    );
    await renderPage(<FoldersPage root="archive" path="2026/2026.06.20 - shoot" />, server);
    expect(screen.getByText(/only files whose DNG is already in the cache can be queued/)).toBeTruthy();

    const confirm = await openQueueConfirmation();
    fireEvent.click(within(confirm).getByRole('button', { name: 'Queue' }));
    await settle();
    const alert = within(folderCard()).getByRole('alert');
    expect(alert.textContent).toContain('files without a DNG cannot be built');
  });

  it('goes back without queueing', async () => {
    const server = stage3Server({ browse: shootBrowse() });
    await renderPage(<FoldersPage root="archive" path="2026/2026.06.20 - shoot" />, server);
    const confirm = await openQueueConfirmation();
    fireEvent.keyDown(confirm, { key: 'Escape' });
    expect(within(folderCard()).queryByRole('group')).toBeNull();
    expect(server.calls('queueFolder')).toBe(0);
  });
});
