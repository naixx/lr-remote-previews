import { act, render } from '@testing-library/react';
import type { ReactElement } from 'react';
import { afterEach, beforeEach, vi } from 'vitest';
import { ApiProvider } from '../app/ApiProvider';
import { Layout } from '../app/Layout';
import type { FakeServer } from './fixtures';

/** Three minutes after the newest sample job was created. */
export const NOW = new Date('2026-11-14T09:33:00Z');

/**
 * Fakes only the timers the dashboard uses, for the tests of the calling file; promises and
 * fetch bodies resolve as usual. Drive time with `advance` and `settle`, not `findBy…`.
 */
export function installFakeClock() {
  beforeEach(() => {
    vi.useFakeTimers({
      toFake: ['setTimeout', 'clearTimeout', 'setInterval', 'clearInterval', 'Date'],
    });
    vi.setSystemTime(NOW);
  });
  afterEach(() => {
    vi.useRealTimers();
  });
}

/** Moves the fake clock and lets every request and render that follows settle. */
export async function advance(ms: number) {
  await act(async () => {
    await vi.advanceTimersByTimeAsync(ms);
  });
}

/** Lets the requests in flight finish without moving the clock. */
export async function settle() {
  for (let round = 0; round < 6; round += 1) await advance(0);
}

/** Renders a page inside the provider and the layout, talking to `server`. */
export async function renderPage(page: ReactElement, server: FakeServer) {
  const result = render(
    <ApiProvider fetch={server.fetch}>
      <Layout>{page}</Layout>
    </ApiProvider>,
  );
  await settle();
  return result;
}
