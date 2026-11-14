import { act, render, screen, within } from '@testing-library/react';
import { afterEach, describe, expect, it } from 'vitest';
import { fullServer } from '../test/fixtures';
import { ApiProvider } from './ApiProvider';
import { CurrentPage } from './App';
import { Layout } from './Layout';
import { hrefFor, parseRoute, type Route } from './router';

afterEach(() => {
  window.location.hash = '';
});

describe('parseRoute', () => {
  it('reads every page', () => {
    expect(parseRoute('')).toEqual({ page: 'overview' });
    expect(parseRoute('#')).toEqual({ page: 'overview' });
    expect(parseRoute('#/')).toEqual({ page: 'overview' });
    expect(parseRoute('#/jobs')).toEqual({ page: 'jobs', state: null });
    expect(parseRoute('#/jobs?state=done')).toEqual({ page: 'jobs', state: 'done' });
    expect(parseRoute('#/jobs/7')).toEqual({ page: 'job', id: 7, itemState: null });
    expect(parseRoute('#/jobs/7?state=failed')).toEqual({ page: 'job', id: 7, itemState: 'failed' });
    expect(parseRoute('#/folders')).toEqual({ page: 'folders', root: null, path: '' });
    expect(parseRoute('#/folders/archive')).toEqual({ page: 'folders', root: 'archive', path: '' });
    expect(parseRoute('#/folders/archive/2026/2026.06.20%20-%20shoot')).toEqual({
      page: 'folders',
      root: 'archive',
      path: '2026/2026.06.20 - shoot',
    });
    expect(parseRoute('#/settings')).toEqual({ page: 'settings' });
    expect(parseRoute('#/converter')).toEqual({ page: 'converter' });
    expect(parseRoute('#/log/')).toEqual({ page: 'log' });
  });

  it('ignores a filter it does not know', () => {
    expect(parseRoute('#/jobs?state=paused')).toEqual({ page: 'jobs', state: null });
    expect(parseRoute('#/jobs/7?state=lost')).toEqual({ page: 'job', id: 7, itemState: null });
  });

  it('sends anything else to «not found»', () => {
    for (const hash of ['#/nope', '#/jobs/0', '#/jobs/x', '#/jobs/7/items', '#/log/more', '#/%E0%A4%A']) {
      expect(parseRoute(hash).page).toBe('not-found');
    }
  });

  it('writes links that read back as the same route', () => {
    const routes: Route[] = [
      { page: 'overview' },
      { page: 'jobs', state: null },
      { page: 'jobs', state: 'cancelled' },
      { page: 'job', id: 12, itemState: 'rejected' },
      { page: 'folders', root: null, path: '' },
      { page: 'folders', root: 'archive', path: '2026/a #1 & 100%?' },
      { page: 'settings' },
      { page: 'converter' },
      { page: 'log' },
    ];
    for (const route of routes) {
      const href = hrefFor(route);
      expect(href.startsWith('#/')).toBe(true);
      expect(parseRoute(href)).toEqual(route);
    }
    expect(hrefFor({ page: 'folders', root: 'archive', path: '2026/a b' })).toBe(
      '#/folders/archive/2026/a%20b',
    );
  });
});

function renderApp(hash: string) {
  window.location.hash = hash;
  const server = fullServer();
  render(
    <ApiProvider fetch={server.fetch}>
      <Layout>
        <CurrentPage />
      </Layout>
    </ApiProvider>,
  );
  return server;
}

function navigateTo(hash: string) {
  act(() => {
    window.location.hash = hash;
    window.dispatchEvent(new HashChangeEvent('hashchange'));
  });
}

describe('pages by route', () => {
  it('opens a deep route on load, as after a reload', async () => {
    renderApp('#/jobs/7');
    expect(await screen.findByRole('heading', { level: 1, name: 'Lightroom selection' })).toBeTruthy();
    expect(document.title).toBe('Lightroom selection · LR Remote Previews');
    const nav = screen.getByRole('navigation', { name: 'Sections' });
    expect(within(nav).getByRole('link', { name: 'Jobs' }).getAttribute('aria-current')).toBe('page');
    expect(within(nav).getByRole('link', { name: 'Overview' }).getAttribute('aria-current')).toBeNull();
  });

  it('follows the hash and moves focus to the new page heading', async () => {
    renderApp('#/');
    await screen.findByRole('heading', { level: 1, name: 'Overview' });

    navigateTo('#/settings');
    const heading = await screen.findByRole('heading', { level: 1, name: 'Settings' });
    expect(document.activeElement).toBe(heading);
    expect(document.title).toBe('Settings · LR Remote Previews');

    navigateTo('#/log');
    expect(await screen.findByRole('heading', { level: 1, name: 'Log' })).toBeTruthy();
    navigateTo('#/converter');
    expect(await screen.findByRole('heading', { level: 1, name: 'Converter' })).toBeTruthy();
    navigateTo('#/folders');
    expect(await screen.findByRole('heading', { level: 1, name: 'Folders' })).toBeTruthy();
    navigateTo('#/jobs');
    expect(await screen.findByRole('heading', { level: 1, name: 'Jobs' })).toBeTruthy();
  });

  it('says so for an unknown route and links to the overview', async () => {
    renderApp('#/queue');
    expect(await screen.findByRole('heading', { level: 1, name: 'Page not found' })).toBeTruthy();
    expect(screen.getByText('#/queue')).toBeTruthy();
    expect(screen.getByRole('link', { name: 'Go to the overview' }).getAttribute('href')).toBe('#/');
  });

  it('links every section with a hash, never a server path', () => {
    renderApp('#/');
    const nav = screen.getByRole('navigation', { name: 'Sections' });
    expect(within(nav).getAllByRole('link').map((link) => link.getAttribute('href'))).toEqual([
      '#/',
      '#/jobs',
      '#/folders',
      '#/settings',
      '#/converter',
      '#/log',
    ]);
  });
});
