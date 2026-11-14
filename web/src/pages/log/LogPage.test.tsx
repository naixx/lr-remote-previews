import { fireEvent, screen, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { sampleLog, stage3Server } from '../../test/fixtures';
import { advance, renderPage, settle, installFakeClock } from '../../test/render';
import { LOG_LIMIT, LOG_REFRESH_MS } from './levels';
import { LogPage } from './LogPage';

installFakeClock();

function logLines(): HTMLElement[] {
  return Array.from(screen.getByRole('region', { name: 'Server log' }).querySelectorAll('li'));
}

function logWith(n: number) {
  return {
    lines: Array.from({ length: n }, (_, index) => ({
      time: '2026-11-14T09:30:00Z',
      level: 'INFO',
      logger: 'lrrp.scheduler',
      message: `line ${index + 1}`,
    })),
  };
}

describe('LogPage', () => {
  it('shows the newest lines with the level written out on each', async () => {
    const server = stage3Server();
    await renderPage(<LogPage />, server);

    expect(server.urlOf('log')).toBe(`api/v1/log?limit=${LOG_LIMIT}`);
    expect(document.title).toBe('Log · LR Remote Previews');
    const lines = logLines();
    expect(lines).toHaveLength(3);
    const [info, warning, error] = lines as [HTMLElement, HTMLElement, HTMLElement];
    expect(info.textContent).toContain('INFO');
    expect(info.textContent).toContain('lrrp.scheduler');
    expect(info.textContent).toContain('wave: 32 file(s) in 4 process(es)');
    expect(info.querySelector('time')?.getAttribute('dateTime')).toBe('2026-11-14T09:30:00Z');
    expect(warning.className).toContain('log__line--warning');
    expect(warning.textContent).toContain('WARNING');
    expect(error.className).toContain('log__line--error');
    expect(error.textContent).toContain('ERROR');
    expect(screen.getByText('3 lines')).toBeTruthy();
  });

  it('refreshes every 3 s until paused, and at once when resumed', async () => {
    const server = stage3Server();
    await renderPage(<LogPage />, server);
    await advance(LOG_REFRESH_MS);
    expect(server.calls('log')).toBe(2);

    const pause = screen.getByRole('button', { name: 'Pause updates' });
    fireEvent.click(pause);
    await settle();
    expect(screen.getByRole('button', { name: 'Resume updates' }).getAttribute('aria-pressed')).toBe(
      'true',
    );
    expect(screen.getByText(/Updates paused\./)).toBeTruthy();
    await advance(LOG_REFRESH_MS * 5);
    expect(server.calls('log')).toBe(2);
    // The lines stay while paused.
    expect(logLines()).toHaveLength(3);

    server.reply('log', logWith(4));
    fireEvent.click(screen.getByRole('button', { name: 'Resume updates' }));
    await settle();
    expect(server.calls('log')).toBe(3);
    expect(logLines()).toHaveLength(4);
  });

  it('says that an older server has no log for the dashboard', async () => {
    const server = stage3Server();
    server.reply('log', { detail: 'Not Found' }, 404);
    await renderPage(<LogPage />, server);
    expect(screen.getByText('This server is older than the dashboard')).toBeTruthy();
  });

  it('says so when the server has logged nothing', async () => {
    const server = stage3Server({ log: { lines: [] } });
    await renderPage(<LogPage />, server);
    expect(
      within(screen.getByRole('region', { name: 'Server log' })).getByText(
        'The server has logged nothing since it started.',
      ),
    ).toBeTruthy();
  });

  describe('scrolling', () => {
    // jsdom has no layout: give the log box a fixed size.
    beforeEach(() => {
      vi.spyOn(HTMLElement.prototype, 'scrollHeight', 'get').mockReturnValue(1000);
      vi.spyOn(HTMLElement.prototype, 'clientHeight', 'get').mockReturnValue(200);
    });

    afterEach(() => {
      vi.restoreAllMocks();
    });

    it('follows the newest line unless the person scrolled up', async () => {
      const server = stage3Server({ log: sampleLog() });
      await renderPage(<LogPage />, server);
      const box = screen.getByRole('region', { name: 'Server log' });
      expect(box.scrollTop).toBe(1000);

      // The person scrolls up to read: new lines no longer move the view.
      box.scrollTop = 300;
      fireEvent.scroll(box);
      server.reply('log', logWith(5));
      await advance(LOG_REFRESH_MS);
      expect(logLines()).toHaveLength(5);
      expect(box.scrollTop).toBe(300);

      fireEvent.click(screen.getByRole('button', { name: 'Jump to the newest line' }));
      expect(box.scrollTop).toBe(1000);
      expect(screen.queryByRole('button', { name: 'Jump to the newest line' })).toBeNull();
    });
  });
});
