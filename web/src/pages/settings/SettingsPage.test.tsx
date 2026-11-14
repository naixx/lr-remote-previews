import { fireEvent, screen, within } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import { TOKEN_STORAGE_KEY } from '../../api/token';
import { sampleInfo, sampleSettings, stage3Server } from '../../test/fixtures';
import { renderPage, settle, installFakeClock } from '../../test/render';
import { SettingsPage } from './SettingsPage';

installFakeClock();

function formCard() {
  return screen.getByRole('region', { name: 'Converter processes and working hours' });
}

function saveButton() {
  return within(formCard()).getByRole('button', { name: 'Save settings' });
}

function typeInto(label: string, value: string) {
  fireEvent.change(within(formCard()).getByLabelText(label), { target: { value } });
}

describe('SettingsPage', () => {
  it('shows the current settings in the form', async () => {
    const server = stage3Server();
    await renderPage(<SettingsPage />, server);

    expect(document.title).toBe('Settings · LR Remote Previews');
    const form = formCard();
    expect(within(form).getByRole('radio', { name: 'Automatic' })).toHaveProperty('checked', true);
    expect(within(form).getByLabelText('Number of converter processes')).toHaveProperty(
      'disabled',
      true,
    );
    expect(form.textContent).toContain('Automatic comes to 4 processes on this server.');
    expect(form.textContent).toContain('never 2: two converter processes side by side waste CPU time');
    expect(within(form).getByLabelText('Files per process')).toHaveProperty('value', '8');
    expect(
      within(form).getByRole('checkbox', { name: 'Start conversions only between these times' }),
    ).toHaveProperty('checked', false);
    expect(within(form).getByLabelText('From')).toHaveProperty('value', '22:00');
    expect(within(form).getByLabelText('To')).toHaveProperty('value', '07:00');
    // Nothing changed yet.
    expect(saveButton()).toHaveProperty('disabled', true);
  });

  it('saves only what changed and shows the values the server answered', async () => {
    const server = stage3Server();
    await renderPage(<SettingsPage />, server);

    fireEvent.click(within(formCard()).getByRole('radio', { name: 'Fixed number' }));
    typeInto('Number of converter processes', '6');
    typeInto('Files per process', '16');
    fireEvent.click(
      within(formCard()).getByRole('checkbox', { name: 'Start conversions only between these times' }),
    );

    const gate = server.hold('updateSettings');
    server.reply(
      'updateSettings',
      sampleSettings({
        workers: 6,
        effectiveWorkers: 6,
        batchSize: 16,
        workingHours: { enabled: true, from: '22:00', to: '07:00' },
      }),
    );
    fireEvent.click(saveButton());
    await settle();
    expect(server.bodyOf('updateSettings')).toEqual({
      workers: 6,
      batchSize: 16,
      workingHours: { enabled: true, from: '22:00', to: '07:00' },
    });
    expect(saveButton()).toHaveProperty('disabled', true);

    gate.release();
    await settle();
    expect(within(formCard()).getByRole('status').textContent).toContain('Saved.');
    expect(formCard().textContent).toContain('In effect now: 6');
    expect(within(formCard()).getByLabelText('Number of converter processes')).toHaveProperty(
      'value',
      '6',
    );
    expect(saveButton()).toHaveProperty('disabled', true);
  });

  it('refuses 2 processes and equal times before sending anything', async () => {
    const server = stage3Server();
    await renderPage(<SettingsPage />, server);

    fireEvent.click(within(formCard()).getByRole('radio', { name: 'Fixed number' }));
    typeInto('Number of converter processes', '2');
    fireEvent.click(
      within(formCard()).getByRole('checkbox', { name: 'Start conversions only between these times' }),
    );
    typeInto('To', '22:00');
    fireEvent.click(saveButton());
    await settle();

    expect(server.calls('updateSettings')).toBe(0);
    expect(formCard().textContent).toContain('Two processes are not allowed');
    expect(formCard().textContent).toContain('The start and the end must differ.');
    const count = within(formCard()).getByLabelText('Number of converter processes');
    expect(count.getAttribute('aria-invalid')).toBe('true');

    typeInto('Number of converter processes', '40');
    expect(formCard().textContent).toContain('Enter a whole number from 1 to 32.');
    typeInto('Number of converter processes', '3');
    typeInto('To', '06:30');
    expect(formCard().textContent).not.toContain('must differ');
    fireEvent.click(saveButton());
    await settle();
    expect(server.bodyOf('updateSettings')).toEqual({
      workers: 3,
      workingHours: { enabled: true, from: '22:00', to: '06:30' },
    });
  });

  it('shows a value the server refuses next to the form and keeps the input', async () => {
    const server = stage3Server();
    server.reply('updateSettings', { detail: 'batchSize: must be at most 48 on this server' }, 422);
    await renderPage(<SettingsPage />, server);

    typeInto('Files per process', '64');
    fireEvent.click(saveButton());
    await settle();

    const alert = within(formCard()).getByRole('alert');
    expect(alert.textContent).toContain('The server did not accept the settings.');
    expect(alert.textContent).toContain('batchSize: must be at most 48 on this server');
    expect(within(formCard()).getByLabelText('Files per process')).toHaveProperty('value', '64');
    expect(saveButton()).toHaveProperty('disabled', false);

    fireEvent.click(within(formCard()).getByRole('button', { name: 'Undo changes' }));
    expect(within(formCard()).getByLabelText('Files per process')).toHaveProperty('value', '8');
  });

  it('pauses and resumes from the Building card', async () => {
    const server = stage3Server({ updateSettings: sampleSettings({ paused: true }) });
    await renderPage(<SettingsPage />, server);
    const building = screen.getByRole('region', { name: 'Building' });

    fireEvent.click(within(building).getByRole('button', { name: 'Pause' }));
    await settle();
    expect(server.bodyOf('updateSettings')).toEqual({ paused: true });
    expect(within(building).getByText('Paused', { selector: '.badge' })).toBeTruthy();
    expect(within(building).getByRole('button', { name: 'Resume' })).toBeTruthy();
  });

  it('forgets the token on request, and the dashboard asks for it again', async () => {
    window.localStorage.setItem(TOKEN_STORAGE_KEY, 'secret-token');
    const server = stage3Server();
    await renderPage(<SettingsPage />, server);

    const card = screen.getByRole('region', { name: 'Access token' });
    expect(card.textContent).toContain('A token is saved in this browser');
    server.reply('info', { detail: 'Missing or invalid token.' }, 401);
    server.reply('settings', { detail: 'Missing or invalid token.' }, 401);
    fireEvent.click(within(card).getByRole('button', { name: 'Forget token' }));
    await settle();

    expect(window.localStorage.getItem(TOKEN_STORAGE_KEY)).toBeNull();
    expect(screen.getByRole('heading', { name: 'Access token required' })).toBeTruthy();
    expect(server.authOf('settings', -1)).toBeNull();
  });

  it('says that an open server needs no token', async () => {
    const server = stage3Server({ info: { ...sampleInfo(), auth: 'none' } });
    await renderPage(<SettingsPage />, server);
    expect(screen.getByRole('region', { name: 'Access token' }).textContent).toContain(
      'This server does not ask for a token',
    );
  });

  it('lists the server facts', async () => {
    const server = stage3Server();
    await renderPage(<SettingsPage />, server);

    const facts = screen.getByRole('region', { name: 'Server' });
    expect(facts.textContent).toContain('Server version0.4.0');
    expect(facts.textContent).toContain(`Dashboard version${__APP_VERSION__}`);
    expect(facts.textContent).toContain('Jobs kept30 days after they finish');
    expect(facts.textContent).toContain('Most photos per job5,000');
    expect(facts.textContent).toContain('2,560 px long edge');
    const roots = within(facts).getByRole('list', { name: 'Roots' });
    expect(within(roots).getAllByRole('listitem').map((item) => item.textContent)).toEqual([
      'ArchivearchiveAvailable',
      'Offsite copyoffsiteUnavailable',
    ]);
    expect(
      within(within(facts).getByRole('list', { name: 'Supported raw file extensions' }))
        .getAllByRole('listitem')
        .map((item) => item.textContent),
    ).toEqual(['.arw', '.cr2']);
  });

  it('keeps the token and the facts when the server is older and has no settings', async () => {
    const server = stage3Server();
    server.reply('settings', { detail: 'Not Found' }, 404);
    await renderPage(<SettingsPage />, server);

    expect(screen.getByText('This server is older than the dashboard')).toBeTruthy();
    expect(screen.getByText(/settings that can be changed from the dashboard/)).toBeTruthy();
    expect(screen.queryByRole('region', { name: 'Converter processes and working hours' })).toBeNull();
    expect(screen.getByRole('region', { name: 'Access token' })).toBeTruthy();
    expect(screen.getByRole('region', { name: 'Server' })).toBeTruthy();
  });
});
