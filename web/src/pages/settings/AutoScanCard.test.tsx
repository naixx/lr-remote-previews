import { fireEvent, screen, within } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import {
  fullServer,
  idleStatus,
  sampleSettings,
  scanOff,
  scheduledScan,
  stage3Settings,
  stage3Status,
  type AutoScanSettingsBody,
} from '../../test/fixtures';
import { advance, installFakeClock, renderPage, settle } from '../../test/render';
import { SCAN_REFRESH_MS } from './live';
import { SettingsPage } from './SettingsPage';

installFakeClock();

const SCAN_ON: AutoScanSettingsBody = {
  enabled: true,
  roots: ['archive'],
  intervalMinutes: 60,
  settleMinutes: 15,
  maxFilesPerRun: 2000,
};

function scanCard() {
  return screen.getByRole('region', { name: 'Automatic scan' });
}

function scanForm() {
  return within(scanCard()).getByRole('form', { name: 'Automatic scan settings' });
}

function fact(label: string): string {
  const term = within(scanCard()).getByText(label, { selector: 'dt' });
  return term.parentElement?.textContent ?? '';
}

function badge(): string {
  return scanCard().querySelector('.card__header .badge')?.textContent ?? '';
}

function saveButton() {
  return within(scanForm()).getByRole('button', { name: 'Save automatic scan' });
}

function scanNowButton() {
  return within(scanCard()).getByRole('button', { name: /^(Scan now|Scanning…)$/ });
}

function typeInto(label: string, value: string) {
  fireEvent.change(within(scanForm()).getByLabelText(label), { target: { value } });
}

function rootBox(name: RegExp) {
  return within(scanForm()).getByRole('checkbox', { name });
}

describe('Settings: automatic scan', () => {
  it('shows the state of the scan and its saved settings', async () => {
    const server = fullServer({ settings: sampleSettings({ autoScan: SCAN_ON }) });
    await renderPage(<SettingsPage />, server);

    expect(badge()).toBe('On');
    expect(scanCard().textContent).toContain('as background jobs');
    expect(scanCard().textContent).toContain('It is off by default.');
    expect(fact('Last scan')).toContain('33 min ago');
    expect(fact('Files it queued')).toContain('120');
    expect(fact('Next scan')).toContain('in 27 min');

    expect(within(scanForm()).getByRole('checkbox', { name: 'Scan automatically' })).toHaveProperty(
      'checked',
      true,
    );
    const roots = within(scanForm()).getByRole('list', { name: 'Roots to scan' });
    expect(within(roots).getAllByRole('listitem').map((item) => item.textContent)).toEqual([
      'Archivearchive',
      'Offsite copyoffsiteUnavailable',
    ]);
    expect(rootBox(/^Archive/)).toHaveProperty('checked', true);
    expect(rootBox(/^Offsite copy/)).toHaveProperty('checked', false);
    expect(scanForm().textContent).toContain('cannot be scanned until it is back');
    expect(within(scanForm()).getByLabelText('Interval (minutes)')).toHaveProperty('value', '60');
    expect(within(scanForm()).getByLabelText('Settle time (minutes)')).toHaveProperty('value', '15');
    expect(within(scanForm()).getByLabelText('Files per scan')).toHaveProperty('value', '2000');
    expect(saveButton()).toHaveProperty('disabled', true);

    expect(scanNowButton()).toHaveProperty('disabled', false);
    expect(scanCard().textContent).toContain('One scan of Archive now');
  });

  it('says when the scan is off and has never run, and needs saved roots for Scan now', async () => {
    const server = fullServer({ status: idleStatus() });
    await renderPage(<SettingsPage />, server);

    expect(badge()).toBe('Off');
    expect(fact('Last scan')).toContain('None yet');
    expect(fact('Next scan')).toContain('OffScan now still works');
    expect(scanNowButton()).toHaveProperty('disabled', true);
    expect(scanCard().textContent).toContain('Tick the roots to scan below and save them first.');
  });

  it('saves the whole automatic scan object and shows the next scan', async () => {
    const server = fullServer({ status: idleStatus() });
    await renderPage(<SettingsPage />, server);

    fireEvent.click(within(scanForm()).getByRole('checkbox', { name: 'Scan automatically' }));
    fireEvent.click(rootBox(/^Archive/));
    typeInto('Interval (minutes)', '30');
    expect(saveButton()).toHaveProperty('disabled', false);

    const saved = { ...SCAN_ON, intervalMinutes: 30 };
    const gate = server.hold('updateSettings');
    server.reply('updateSettings', sampleSettings({ autoScan: saved }));
    server.reply('status', {
      ...idleStatus(),
      autoScan: { ...scanOff(), nextRun: '2026-11-14T10:03:00Z' },
    });
    const statusCalls = server.calls('status');
    fireEvent.click(saveButton());
    await settle();
    expect(server.bodyOf('updateSettings')).toEqual({ autoScan: saved });
    expect(saveButton()).toHaveProperty('disabled', true);

    gate.release();
    await settle();
    expect(within(scanCard()).getByText(/^Saved\./)).toBeTruthy();
    expect(badge()).toBe('On');
    // The status is read again at once, so the next scan shows.
    expect(server.calls('status')).toBeGreaterThan(statusCalls);
    expect(fact('Next scan')).toContain('in 30 min');
    expect(within(scanForm()).getByLabelText('Interval (minutes)')).toHaveProperty('value', '30');
    expect(saveButton()).toHaveProperty('disabled', true);
    // The other forms keep what they show.
    const processes = screen.getByRole('region', { name: 'Converter processes and working hours' });
    expect(within(processes).queryByRole('status')).toBeNull();
  });

  it('refuses a scan without roots and numbers out of range before sending anything', async () => {
    const server = fullServer();
    await renderPage(<SettingsPage />, server);

    fireEvent.click(within(scanForm()).getByRole('checkbox', { name: 'Scan automatically' }));
    typeInto('Interval (minutes)', '3');
    typeInto('Files per scan', '60000');
    fireEvent.click(saveButton());
    await settle();

    expect(server.calls('updateSettings')).toBe(0);
    expect(scanForm().textContent).toContain('Tick at least one root, or turn the automatic scan off.');
    expect(scanForm().textContent).toContain('Enter a whole number of minutes from 5 to 1,440.');
    expect(scanForm().textContent).toContain('Enter a whole number from 1 to 50,000.');
    expect(
      within(scanForm()).getByLabelText('Interval (minutes)').getAttribute('aria-invalid'),
    ).toBe('true');

    fireEvent.click(rootBox(/^Offsite copy/));
    typeInto('Interval (minutes)', '5');
    typeInto('Files per scan', '50000');
    expect(scanForm().textContent).not.toContain('Enter a whole number');
    fireEvent.click(saveButton());
    await settle();
    expect(server.bodyOf('updateSettings')).toEqual({
      autoScan: {
        enabled: true,
        roots: ['offsite'],
        intervalMinutes: 5,
        settleMinutes: 15,
        maxFilesPerRun: 50000,
      },
    });
  });

  it('shows a value the server refuses and keeps the input', async () => {
    const server = fullServer();
    server.reply('updateSettings', { detail: 'autoScan.roots: unknown root "offsite"' }, 422);
    await renderPage(<SettingsPage />, server);

    fireEvent.click(rootBox(/^Offsite copy/));
    fireEvent.click(saveButton());
    await settle();

    const alert = within(scanForm()).getByRole('alert');
    expect(alert.textContent).toContain('The server did not accept the automatic scan settings.');
    expect(alert.textContent).toContain('autoScan.roots: unknown root "offsite"');
    expect(rootBox(/^Offsite copy/)).toHaveProperty('checked', true);
    expect(saveButton()).toHaveProperty('disabled', false);

    fireEvent.click(within(scanForm()).getByRole('button', { name: 'Undo changes' }));
    expect(rootBox(/^Offsite copy/)).toHaveProperty('checked', false);
  });

  it('lists a saved root the server no longer has, so it can be unticked', async () => {
    const server = fullServer({
      settings: sampleSettings({ autoScan: { ...SCAN_ON, roots: ['archive', 'old-disk'] } }),
    });
    await renderPage(<SettingsPage />, server);

    const old = rootBox(/^old-disk/);
    expect(old).toHaveProperty('checked', true);
    expect(old.closest('li')?.textContent).toContain('Not configured');
    expect(scanForm().textContent).toContain('is refused when saving; untick it');

    fireEvent.click(old);
    fireEvent.click(saveButton());
    await settle();
    expect(server.bodyOf('updateSettings')).toEqual({ autoScan: SCAN_ON });
  });

  it('scans now, follows the scan and shows what it queued', async () => {
    const server = fullServer({
      settings: sampleSettings({ autoScan: SCAN_ON }),
      status: idleStatus(),
    });
    await renderPage(<SettingsPage />, server);

    server.reply('status', { ...idleStatus(), autoScan: scheduledScan({ running: true }) });
    fireEvent.click(scanNowButton());
    await settle();

    expect(server.calls('runAutoScan')).toBe(1);
    expect(server.bodyOf('runAutoScan')).toBeUndefined();
    expect(within(scanCard()).getByRole('status').textContent).toContain('The scan started at');
    expect(badge()).toBe('Scanning');
    expect(fact('Next scan')).toContain('Running now');
    expect(scanNowButton().textContent).toBe('Scanning…');
    expect(scanNowButton()).toHaveProperty('disabled', true);

    server.reply('status', {
      ...idleStatus(),
      autoScan: scheduledScan({
        lastRun: '2026-11-14T09:33:01Z',
        lastQueued: 37,
        nextRun: '2026-11-14T10:33:01Z',
      }),
    });
    await advance(SCAN_REFRESH_MS);
    expect(badge()).toBe('On');
    expect(fact('Last scan')).toContain('just now');
    expect(fact('Files it queued')).toContain('37');
    expect(within(scanCard()).getByRole('link', { name: 'See the jobs' }).getAttribute('href')).toBe(
      '#/jobs',
    );
    expect(scanNowButton().textContent).toBe('Scan now');
  });

  it('explains a scan that is already running, a missing converter and no roots', async () => {
    const server = fullServer({ settings: sampleSettings({ autoScan: SCAN_ON }) });
    server.reply('runAutoScan', { detail: 'A scan is running.', code: 'busy' }, 409);
    await renderPage(<SettingsPage />, server);

    fireEvent.click(scanNowButton());
    await settle();
    let alert = within(scanCard()).getByRole('alert');
    expect(alert.textContent).toContain('The scan did not start.');
    expect(alert.textContent).toContain('A scan is already running.');
    expect(within(scanCard()).queryByRole('status')).toBeNull();

    server.reply(
      'runAutoScan',
      { detail: 'Adobe DNG Converter is not installed.', code: 'converter_not_installed' },
      409,
    );
    fireEvent.click(scanNowButton());
    await settle();
    alert = within(scanCard()).getByRole('alert');
    expect(alert.textContent).toContain('files without a DNG cannot be built');

    server.reply('runAutoScan', { detail: 'No root to scan is configured.' }, 422);
    fireEvent.click(scanNowButton());
    await settle();
    alert = within(scanCard()).getByRole('alert');
    expect(alert.textContent).toContain('There is no root to scan');
    expect(alert.textContent).toContain('No root to scan is configured.');
  });

  it('gives a server without the automatic scan the older-server note in this section only', async () => {
    const server = fullServer({ settings: stage3Settings(), status: stage3Status() });
    await renderPage(<SettingsPage />, server);

    expect(scanCard().textContent).toContain(
      'This server is older than the dashboard and does not offer an automatic scan.',
    );
    expect(within(scanCard()).queryByRole('form')).toBeNull();
    expect(within(scanCard()).queryByRole('button')).toBeNull();
    expect(screen.getByRole('region', { name: 'Converter processes and working hours' })).toBeTruthy();
    expect(server.calls('runAutoScan')).toBe(0);
  });
});
