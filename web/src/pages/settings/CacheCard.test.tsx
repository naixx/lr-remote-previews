import { fireEvent, screen, within } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import {
  busyStatus,
  fullServer,
  sampleCacheClean,
  sampleSettings,
  stage3Settings,
  stage3Status,
} from '../../test/fixtures';
import { installFakeClock, renderPage, settle } from '../../test/render';
import { SettingsPage } from './SettingsPage';

installFakeClock();

function cacheCard() {
  return screen.getByRole('region', { name: 'Cache' });
}

function limitsForm() {
  return within(cacheCard()).getByRole('form', { name: 'Cache limits' });
}

function fact(label: string): string {
  const term = within(cacheCard()).getByText(label, { selector: 'dt' });
  return term.parentElement?.textContent ?? '';
}

function saveButton() {
  return within(limitsForm()).getByRole('button', { name: 'Save cache limits' });
}

function typeInto(label: string, value: string) {
  fireEvent.change(within(limitsForm()).getByLabelText(label), { target: { value } });
}

function cleanUpButton() {
  return within(cacheCard()).getByRole('button', { name: /^(Clean up now…|Counting…)$/ });
}

describe('Settings: cache limits', () => {
  it('shows the size of the cache and its limits', async () => {
    const server = fullServer();
    await renderPage(<SettingsPage />, server);

    expect(fact('Size')).toBe('Size2.9 GBNo size limit');
    expect(fact('Files')).toBe('Files5,321No age limit');
    expect(cacheCard().textContent).toContain('simply built again when somebody asks for it');
    const size = within(limitsForm()).getByLabelText('Size limit (GB)');
    expect(size).toHaveProperty('value', '');
    expect(size.getAttribute('placeholder')).toBe('No limit');
    expect(within(limitsForm()).getByLabelText('Age limit (days)')).toHaveProperty('value', '');
    expect(saveButton()).toHaveProperty('disabled', true);
  });

  it('saves both limits as the whole cache object', async () => {
    const server = fullServer();
    await renderPage(<SettingsPage />, server);

    typeInto('Size limit (GB)', '12,5');
    typeInto('Age limit (days)', '90');
    const saved = { maxBytes: 12_500_000_000, maxAgeDays: 90 };
    const gate = server.hold('updateSettings');
    server.reply('updateSettings', sampleSettings({ cache: saved }));
    fireEvent.click(saveButton());
    await settle();
    expect(server.bodyOf('updateSettings')).toEqual({ cache: saved });
    expect(saveButton()).toHaveProperty('disabled', true);

    gate.release();
    await settle();
    expect(within(cacheCard()).getByText('Saved. The next clean-up uses these limits.')).toBeTruthy();
    expect(fact('Size')).toContain('Limit 12.5 GB');
    expect(fact('Files')).toContain('Removed after 90 days unused');
    expect(within(limitsForm()).getByLabelText('Size limit (GB)')).toHaveProperty('value', '12.5');
  });

  it('removes a limit when its field is emptied', async () => {
    const server = fullServer({
      settings: sampleSettings({ cache: { maxBytes: 50_000_000_000, maxAgeDays: 90 } }),
    });
    await renderPage(<SettingsPage />, server);
    expect(within(limitsForm()).getByLabelText('Size limit (GB)')).toHaveProperty('value', '50');

    typeInto('Size limit (GB)', '');
    fireEvent.click(saveButton());
    await settle();
    expect(server.bodyOf('updateSettings')).toEqual({ cache: { maxBytes: null, maxAgeDays: 90 } });
  });

  it('keeps a saved size limit to the byte when only the age changes', async () => {
    const server = fullServer({
      settings: sampleSettings({ cache: { maxBytes: 104_857_600, maxAgeDays: null } }),
    });
    await renderPage(<SettingsPage />, server);

    typeInto('Age limit (days)', '30');
    fireEvent.click(saveButton());
    await settle();
    expect(server.bodyOf('updateSettings')).toEqual({
      cache: { maxBytes: 104_857_600, maxAgeDays: 30 },
    });
  });

  it('refuses a size below the minimum and days out of range before sending anything', async () => {
    const server = fullServer();
    await renderPage(<SettingsPage />, server);

    typeInto('Size limit (GB)', '0.1');
    typeInto('Age limit (days)', '4000');
    fireEvent.click(saveButton());
    await settle();
    expect(server.calls('updateSettings')).toBe(0);
    expect(limitsForm().textContent).toContain('The smallest size limit is 0.2 GB');
    expect(limitsForm().textContent).toContain('Enter a whole number of days from 1 to 3,650');

    typeInto('Size limit (GB)', '12.55');
    expect(limitsForm().textContent).toContain('Enter a size in GB such as 50 or 12.5');
  });

  it('shows a value the server refuses', async () => {
    const server = fullServer();
    server.reply('updateSettings', { detail: 'cache.maxAgeDays: must be at most 3650' }, 422);
    await renderPage(<SettingsPage />, server);

    typeInto('Age limit (days)', '365');
    fireEvent.click(saveButton());
    await settle();
    const alert = within(limitsForm()).getByRole('alert');
    expect(alert.textContent).toContain('The server did not accept the cache limits.');
    expect(alert.textContent).toContain('cache.maxAgeDays: must be at most 3650');
  });

  it('gives a server without cache limits the older-server note, keeping the size', async () => {
    const server = fullServer({ settings: stage3Settings(), status: stage3Status() });
    await renderPage(<SettingsPage />, server);

    expect(fact('Size')).toBe('Size2.9 GB');
    expect(cacheCard().textContent).toContain(
      'This server is older than the dashboard and does not offer cache limits or a clean-up.',
    );
    expect(within(cacheCard()).queryByRole('form')).toBeNull();
    expect(within(cacheCard()).queryByRole('button')).toBeNull();
  });
});

describe('Settings: cache clean-up', () => {
  it('counts first, asks, then cleans up and reads the size again', async () => {
    const server = fullServer();
    await renderPage(<SettingsPage />, server);

    const gate = server.hold('cleanCache');
    fireEvent.click(cleanUpButton());
    await settle();
    expect(server.bodyOf('cleanCache')).toEqual({ dryRun: true });
    expect(cleanUpButton().textContent).toBe('Counting…');
    expect(cleanUpButton()).toHaveProperty('disabled', true);
    gate.release();
    await settle();

    const confirm = within(cacheCard()).getByRole('group', { name: 'Remove 12 DNGs from the cache?' });
    expect(confirm.textContent).toContain('12 DNGs whose original is gone or has changed');
    expect(confirm.textContent).toContain('This frees 6.3 MB.');
    expect(server.calls('cleanCache')).toBe(1);
    expect(cleanUpButton()).toHaveProperty('disabled', true);

    server.reply(
      'cleanCache',
      sampleCacheClean({ dryRun: false, removed: { originalGone: 12, expired: 3 }, bytesFreed: 7_340_032 }),
    );
    server.reply('status', { ...busyStatus(), cache: { entries: 5306, bytes: 2882659968 } });
    fireEvent.click(within(confirm).getByRole('button', { name: 'Clean up' }));
    await settle();

    expect(server.bodyOf('cleanCache', -1)).toEqual({ dryRun: false });
    const result = within(cacheCard()).getByRole('status');
    expect(result.textContent).toContain('Removed 15 DNGs and freed 7.3 MB:');
    expect(result.textContent).toContain('12 DNGs whose original is gone or has changed');
    expect(result.textContent).toContain('3 DNGs not used for longer than the age limit');
    expect(within(cacheCard()).queryByRole('group')).toBeNull();
    expect(fact('Files')).toContain('5,306');
    expect(cleanUpButton()).toHaveProperty('disabled', false);
  });

  it('names the age limit and the size limit among the reasons', async () => {
    const server = fullServer({
      settings: sampleSettings({ cache: { maxBytes: 1_000_000_000, maxAgeDays: 90 } }),
      cleanCache: sampleCacheClean({ removed: { originalGone: 0, expired: 1, overLimit: 40 } }),
    });
    await renderPage(<SettingsPage />, server);

    fireEvent.click(cleanUpButton());
    await settle();
    const confirm = within(cacheCard()).getByRole('group', { name: 'Remove 41 DNGs from the cache?' });
    expect(confirm.textContent).toContain('1 DNG not used for 90 days');
    expect(confirm.textContent).toContain('40 DNGs used least recently, to fit the size limit');
    expect(confirm.textContent).not.toContain('whose original');
  });

  it('says so when there is nothing to remove, without asking', async () => {
    const server = fullServer({
      cleanCache: sampleCacheClean({ removed: { originalGone: 0 }, bytesFreed: 0 }),
    });
    await renderPage(<SettingsPage />, server);

    fireEvent.click(cleanUpButton());
    await settle();
    expect(within(cacheCard()).getByRole('status').textContent).toBe(
      'Nothing to remove under the saved limits.',
    );
    expect(within(cacheCard()).queryByRole('group')).toBeNull();
    expect(server.calls('cleanCache')).toBe(1);
  });

  it('goes back without removing anything', async () => {
    const server = fullServer();
    await renderPage(<SettingsPage />, server);

    fireEvent.click(cleanUpButton());
    await settle();
    const confirm = within(cacheCard()).getByRole('group', { name: /^Remove/ });
    fireEvent.keyDown(confirm, { key: 'Escape' });
    expect(within(cacheCard()).queryByRole('group')).toBeNull();
    expect(server.calls('cleanCache')).toBe(1);
    expect(cleanUpButton()).toHaveProperty('disabled', false);
  });

  it('explains a clean-up that is already running, when counting and when removing', async () => {
    const server = fullServer();
    server.reply('cleanCache', { detail: 'A clean-up is running.', code: 'busy' }, 409);
    await renderPage(<SettingsPage />, server);

    fireEvent.click(cleanUpButton());
    await settle();
    let alert = within(cacheCard()).getByRole('alert');
    expect(alert.textContent).toContain('Could not count what a clean-up would remove.');
    expect(alert.textContent).toContain('A clean-up is already running on the server');

    server.reply('cleanCache', sampleCacheClean());
    fireEvent.click(cleanUpButton());
    await settle();
    expect(within(cacheCard()).queryByRole('alert')).toBeNull();
    server.reply('cleanCache', { detail: 'A clean-up is running.', code: 'busy' }, 409);
    const confirm = within(cacheCard()).getByRole('group', { name: /^Remove/ });
    fireEvent.click(within(confirm).getByRole('button', { name: 'Clean up' }));
    await settle();
    alert = within(cacheCard()).getByRole('alert');
    expect(alert.textContent).toContain('The cache was not cleaned up.');
    expect(alert.textContent).toContain('A clean-up is already running on the server');
    // The question stays, so the person can try again or go back.
    expect(within(confirm).getByRole('button', { name: 'Clean up' })).toHaveProperty(
      'disabled',
      false,
    );
  });

  it('reports what a server did that cleaned up in answer to a dry run', async () => {
    const server = fullServer({ cleanCache: sampleCacheClean({ dryRun: false }) });
    await renderPage(<SettingsPage />, server);

    fireEvent.click(cleanUpButton());
    await settle();
    expect(within(cacheCard()).queryByRole('group')).toBeNull();
    expect(within(cacheCard()).getByRole('status').textContent).toContain(
      'Removed 12 DNGs and freed 6.3 MB',
    );
  });
});
