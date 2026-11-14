import { fireEvent, screen, within } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import {
  failedSelfTest,
  installedInfo,
  passedSelfTest,
  sampleInfo,
  stage3Server,
} from '../../test/fixtures';
import { renderPage, settle, installFakeClock } from '../../test/render';
import { ConverterPage } from './ConverterPage';

installFakeClock();

function converterCard() {
  return screen.getByRole('region', { name: 'Adobe DNG Converter' });
}

function selfTestCard() {
  return screen.getByRole('region', { name: 'Self-test' });
}

function runButton() {
  return within(selfTestCard()).getByRole('button', { name: /self-test/ });
}

function steps(): string[] {
  return within(within(selfTestCard()).getByRole('list'))
    .getAllByRole('listitem')
    .map((item) => item.querySelector('.checklist__name')?.textContent ?? '');
}

describe('ConverterPage', () => {
  it('shows an installed converter with its path and version', async () => {
    const server = stage3Server({ info: installedInfo() });
    await renderPage(<ConverterPage />, server);

    expect(document.title).toBe('Converter · LR Remote Previews');
    const card = converterCard();
    expect(within(card).getByText('Installed')).toBeTruthy();
    expect(card.textContent).toContain('Adobe DNG Converter.exe');
    expect(card.textContent).toContain('17.5');
    expect(card.textContent).toContain('not part of LR Remote Previews');
    expect(within(card).getByText('docs/converter.md')).toBeTruthy();
  });

  it('shows a missing converter with the path the server expects', async () => {
    const server = stage3Server({ info: sampleInfo() });
    await renderPage(<ConverterPage />, server);

    const card = converterCard();
    expect(within(card).getByText('Not installed')).toBeTruthy();
    expect(card.textContent).toContain('Expected path in the Wine prefix');
    expect(card.textContent).toContain('does not include it, download it or distribute it');
  });

  it('says when the version cannot be read', async () => {
    const info = installedInfo();
    const server = stage3Server({ info: { ...info, converter: { ...info.converter, version: null } } });
    await renderPage(<ConverterPage />, server);
    expect(converterCard().textContent).toContain('Unknown: the server could not read it');
  });

  it('runs the self-test without a file and shows the steps as a checklist', async () => {
    const server = stage3Server({ selfTest: { ok: true, steps: passedSelfTest().steps.slice(0, 3) } });
    await renderPage(<ConverterPage />, server);

    const gate = server.hold('selfTest');
    fireEvent.click(runButton());
    await settle();
    expect(server.bodyOf('selfTest')).toBeUndefined();
    expect(runButton().textContent).toContain('Running the self-test…');
    expect(runButton()).toHaveProperty('disabled', true);

    gate.release();
    await settle();
    const report = within(selfTestCard()).getByRole('status');
    expect(within(report).getByText('Passed')).toBeTruthy();
    expect(steps()).toEqual(['Converter installedOK', 'Virtual displayOK', 'Warm-upOK']);
    expect(report.textContent).toContain('Xvfb on :99');
    expect(report.textContent).toContain('Name a raw file above to also try a real conversion.');
    expect(runButton()).toHaveProperty('disabled', false);
  });

  it('converts a named file as the last step', async () => {
    const server = stage3Server({ selfTest: passedSelfTest() });
    await renderPage(<ConverterPage />, server);

    fireEvent.change(within(selfTestCard()).getByLabelText('Root'), { target: { value: 'archive' } });
    fireEvent.change(within(selfTestCard()).getByLabelText('Path inside the root'), {
      target: { value: '/2026/2026.06.20 - shoot/IMG_0001.ARW ' },
    });
    fireEvent.click(runButton());
    await settle();

    expect(server.bodyOf('selfTest')).toEqual({
      root: 'archive',
      path: '2026/2026.06.20 - shoot/IMG_0001.ARW',
    });
    expect(steps()).toContain('Test conversionOK');
    expect(selfTestCard().textContent).toContain('IMG_0001.ARW → 359310 bytes in 2.1 s');
  });

  it('shows where it failed and which steps did not run', async () => {
    const server = stage3Server({ selfTest: failedSelfTest() });
    await renderPage(<ConverterPage />, server);
    fireEvent.change(within(selfTestCard()).getByLabelText('Path inside the root'), {
      target: { value: '2026/IMG_0001.ARW' },
    });
    fireEvent.click(runButton());
    await settle();

    const report = within(selfTestCard()).getByRole('status');
    expect(within(report).getByText('Failed', { selector: '.badge' })).toBeTruthy();
    expect(steps()).toEqual([
      'Converter installedOK',
      'Virtual displayOK',
      'Warm-upFailed',
      'Test conversionNot run',
    ]);
    expect(report.textContent).toContain('wine: could not load kernel32.dll');
  });

  it('says another self-test is running when the server is busy', async () => {
    const server = stage3Server();
    server.reply('selfTest', { detail: 'A self-test is already running.', code: 'busy' }, 409);
    await renderPage(<ConverterPage />, server);
    fireEvent.click(runButton());
    await settle();

    const alert = within(selfTestCard()).getByRole('alert');
    expect(alert.textContent).toContain('Another self-test is running on the server.');
    expect(alert.textContent).toContain('A self-test is already running.');
  });

  it('explains a file the server will not use', async () => {
    const server = stage3Server();
    server.reply('selfTest', { detail: 'No such file: 2026/x.ARW', code: 'not_found' }, 422);
    await renderPage(<ConverterPage />, server);
    fireEvent.change(within(selfTestCard()).getByLabelText('Path inside the root'), {
      target: { value: '2026/x.ARW' },
    });
    fireEvent.click(runButton());
    await settle();

    const alert = within(selfTestCard()).getByRole('alert');
    expect(alert.textContent).toContain('The file cannot be used: The file was not found');
    expect(alert.textContent).toContain('No such file: 2026/x.ARW');
  });

  it('says that an older server has no self-test', async () => {
    const server = stage3Server();
    server.reply('selfTest', { detail: 'Not Found' }, 404);
    await renderPage(<ConverterPage />, server);
    fireEvent.click(runButton());
    await settle();
    expect(selfTestCard().textContent).toContain('This server is older than the dashboard');
    expect(within(selfTestCard()).queryByRole('button')).toBeNull();
  });
});
