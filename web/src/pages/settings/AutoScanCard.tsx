import { useCallback, useId, useState, type FormEvent } from 'react';
import { describeError, type ApiError } from '../../api/errors';
import type { RootInfo } from '../../api/info';
import type { AutoScanSettings, ServerSettings } from '../../api/settings';
import type { AutoScanStatus } from '../../api/status';
import { useApi } from '../../app/ApiContext';
import { links } from '../../app/router';
import { ActionError } from '../../components/ActionError';
import { Card } from '../../components/Card';
import { OlderServerCallout } from '../../components/ErrorPanel';
import { Fact } from '../../components/Fact';
import { StatusBadge } from '../../components/StatusBadge';
import { useAction } from '../../hooks/useAction';
import { explainAutoScanError } from '../../lib/codes';
import {
  formatCount,
  formatFullTime,
  formatLocalTime,
  formatRelative,
  formatTimeOfDay,
  formatUntil,
} from '../../lib/format';
import { Field } from './Field';
import { scanChange, scanValuesOf, validateScan, type ScanErrors, type ScanValues } from './scanForm';

interface AutoScanCardProps {
  /** The saved settings; null from a server that has no automatic scan. */
  settings: AutoScanSettings | null;
  /** The server's roots; null until the info has arrived or when it failed. */
  roots: RootInfo[] | null;
  /** From the status: undefined until it has arrived, null from a server that does not report it. */
  scan: AutoScanStatus | null | undefined;
  /** The status request failed. */
  statusError: ApiError | null;
  /** When the status was fetched, for «in 27 min». */
  now: number;
  /** Grows with every save of this form, so the form starts again from the saved values. */
  formKey: number;
  /** Show «Saved»: this form was the last thing saved. */
  saved: boolean;
  onSaved: (settings: ServerSettings) => void;
  /** After Scan now was accepted: the page then follows the scan. */
  onScanStarted: () => void;
}

export function AutoScanCard({
  settings,
  roots,
  scan,
  statusError,
  now,
  formKey,
  saved,
  onSaved,
  onScanStarted,
}: AutoScanCardProps) {
  const aside =
    settings === null ? undefined : scan?.running ? (
      <StatusBadge tone="info">Scanning</StatusBadge>
    ) : settings.enabled ? (
      <StatusBadge tone="ok">On</StatusBadge>
    ) : (
      <StatusBadge tone="neutral">Off</StatusBadge>
    );

  return (
    <Card title="Automatic scan" wide aside={aside}>
      {settings === null ? (
        <OlderServerCallout feature="an automatic scan" />
      ) : (
        <>
          <p>
            The server looks through the roots you choose at a fixed interval and queues every raw
            file that has no smart preview yet, as background jobs, so work sent from Lightroom
            always goes first. It is off by default.
          </p>
          <ScanState settings={settings} scan={scan} statusError={statusError} now={now} />
          <ScanNow
            settings={settings}
            roots={roots}
            running={scan?.running ?? false}
            onStarted={onScanStarted}
          />
          <ScanForm key={formKey} initial={settings} roots={roots} onSaved={onSaved} />
          {saved && (
            <p className="callout callout--ok" role="status">
              Saved. The next scan follows these settings.
            </p>
          )}
        </>
      )}
    </Card>
  );
}

function At({ iso, now }: { iso: string; now: number }) {
  return (
    <time dateTime={iso} title={formatFullTime(iso)}>
      {formatLocalTime(iso, now)}
    </time>
  );
}

function ScanState({
  settings,
  scan,
  statusError,
  now,
}: {
  settings: AutoScanSettings;
  scan: AutoScanStatus | null | undefined;
  statusError: ApiError | null;
  now: number;
}) {
  if (scan === undefined) {
    return statusError ? (
      <p className="muted">The state of the scan could not be read. {describeError(statusError)}</p>
    ) : (
      <p className="muted">Reading the state of the scan…</p>
    );
  }
  // A server that has the settings but does not report the scan in its status.
  if (scan === null) return null;

  return (
    <dl className="facts facts--small scan-state">
      <Fact label="Last scan">
        {scan.lastRun ? (
          <>
            <At iso={scan.lastRun} now={now} />
            <span className="facts__note">{formatRelative(scan.lastRun, now)}</span>
          </>
        ) : (
          'None yet'
        )}
      </Fact>
      <Fact label="Files it queued">
        {scan.lastRun ? (
          <>
            <span className="tabular">{formatCount(scan.lastQueued)}</span>
            {scan.lastQueued > 0 && (
              <span className="facts__note">
                <a href={links.jobs()}>See the jobs</a>
              </span>
            )}
          </>
        ) : (
          '—'
        )}
      </Fact>
      <Fact label="Next scan">
        {scan.running ? (
          'Running now'
        ) : scan.nextRun ? (
          <>
            <At iso={scan.nextRun} now={now} />
            <span className="facts__note">{formatUntil(scan.nextRun, now)}</span>
          </>
        ) : settings.enabled ? (
          'Not scheduled yet'
        ) : (
          <>
            Off
            <span className="facts__note">Scan now still works</span>
          </>
        )}
      </Fact>
    </dl>
  );
}

/** `Archive`, `Archive and Offsite`, `A, B and C`. */
function joinNames(names: string[]): string {
  if (names.length <= 1) return names.join('');
  return `${names.slice(0, -1).join(', ')} and ${names[names.length - 1]}`;
}

function ScanNow({
  settings,
  roots,
  running,
  onStarted,
}: {
  settings: AutoScanSettings;
  roots: RootInfo[] | null;
  running: boolean;
  onStarted: () => void;
}) {
  const { client } = useApi();
  const hintId = useId();
  const [startedAt, setStartedAt] = useState<number | null>(null);
  const action = useAction(useCallback(() => client.runAutoScan(null), [client]));
  const names = settings.roots.map((id) => roots?.find((root) => root.id === id)?.label ?? id);
  const noRoots = settings.roots.length === 0;

  async function start() {
    setStartedAt(null);
    const result = await action.run();
    if (!result) return;
    setStartedAt(Date.now());
    onStarted();
  }

  return (
    <div className="scan-now">
      <div className="actions">
        <button
          type="button"
          className="button button--secondary"
          disabled={action.pending || noRoots || running}
          aria-describedby={hintId}
          onClick={() => void start()}
        >
          {(action.pending || running) && (
            <span className="spinner spinner--small" aria-hidden="true" />
          )}
          {running ? 'Scanning…' : 'Scan now'}
        </button>
        <p className="hint" id={hintId}>
          {noRoots
            ? 'Tick the roots to scan below and save them first.'
            : `One scan of ${joinNames(names)} now, whether the automatic scan is on or off.`}
        </p>
      </div>
      <ActionError error={action.error} action="The scan did not start" explain={explainAutoScanError} />
      {startedAt !== null && (
        <p className="callout callout--ok" role="status">
          The scan started at {formatTimeOfDay(startedAt)}. What it queues shows above when it has
          finished.
        </p>
      )}
    </div>
  );
}

interface ListedRoot {
  id: string;
  label: string;
  /** `unknown`: saved in the settings but not among the server's roots any more. */
  state: 'available' | 'unavailable' | 'unknown';
}

/** The server's roots, then any saved root it no longer has, so it can be unticked. */
function listRoots(roots: RootInfo[] | null, saved: string[]): ListedRoot[] {
  const listed: ListedRoot[] = (roots ?? []).map((root) => ({
    id: root.id,
    label: root.label,
    state: root.available ? 'available' : 'unavailable',
  }));
  for (const id of saved) {
    if (!listed.some((root) => root.id === id)) {
      // Without the info the dashboard cannot tell; it shows the id alone.
      listed.push({ id, label: id, state: roots === null ? 'available' : 'unknown' });
    }
  }
  return listed;
}

function isDirty(initial: ScanValues, values: ScanValues): boolean {
  return (
    initial.enabled !== values.enabled ||
    initial.roots.length !== values.roots.length ||
    values.roots.some((root) => !initial.roots.includes(root)) ||
    initial.interval !== values.interval.trim() ||
    initial.settle !== values.settle.trim() ||
    initial.maxFiles !== values.maxFiles.trim()
  );
}

function ScanForm({
  initial,
  roots,
  onSaved,
}: {
  initial: AutoScanSettings;
  roots: RootInfo[] | null;
  onSaved: (settings: ServerSettings) => void;
}) {
  const { client } = useApi();
  const enabledId = useId();
  const rootsHelpId = useId();
  const rootsErrorId = useId();
  const [values, setValues] = useState<ScanValues>(() => scanValuesOf(initial));
  const [showErrors, setShowErrors] = useState(false);
  const save = useAction(
    useCallback(
      (autoScan: AutoScanSettings) => client.updateSettings({ autoScan }),
      [client],
    ),
  );

  const errors = validateScan(values);
  const visible: ScanErrors = showErrors ? errors : {};
  const dirty = isDirty(scanValuesOf(initial), values);
  const listed = listRoots(roots, initial.roots);

  function update(patch: Partial<ScanValues>) {
    setValues((previous) => ({ ...previous, ...patch }));
    save.reset();
  }

  function toggleRoot(id: string, ticked: boolean) {
    setValues((previous) => ({
      ...previous,
      roots: ticked
        ? [...previous.roots.filter((root) => root !== id), id]
        : previous.roots.filter((root) => root !== id),
    }));
    save.reset();
  }

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (Object.keys(errors).length > 0) {
      setShowErrors(true);
      return;
    }
    const change = scanChange(initial, values);
    if (change === null) {
      // Only the spelling changed (`060` for `60`): nothing to send.
      setValues(scanValuesOf(initial));
      return;
    }
    const next = await save.run(change);
    if (next) onSaved(next);
  }

  return (
    <form
      className="settings-form settings-section"
      aria-label="Automatic scan settings"
      onSubmit={(event) => void handleSubmit(event)}
      noValidate
    >
      <label className="check" htmlFor={enabledId}>
        <input
          id={enabledId}
          type="checkbox"
          checked={values.enabled}
          onChange={(event) => update({ enabled: event.target.checked })}
        />
        <span>Scan automatically</span>
      </label>

      <fieldset
        className="settings-group"
        aria-describedby={visible.roots ? `${rootsHelpId} ${rootsErrorId}` : rootsHelpId}
      >
        <legend className="settings-group__title">Roots to scan</legend>
        {listed.length === 0 ? (
          <p className="muted">
            {roots === null ? 'Reading the roots…' : 'No roots are configured on the server.'}
          </p>
        ) : (
          <ul className="scan-roots" aria-label="Roots to scan">
            {listed.map((root) => (
              <li className="scan-roots__item" key={root.id}>
                <label className="check">
                  <input
                    type="checkbox"
                    checked={values.roots.includes(root.id)}
                    onChange={(event) => toggleRoot(root.id, event.target.checked)}
                  />
                  <span className="scan-roots__name">
                    <span className="scan-roots__label">{root.label}</span>
                    {root.label !== root.id && <code className="roots__id">{root.id}</code>}
                  </span>
                </label>
                {root.state === 'unavailable' && <StatusBadge tone="bad">Unavailable</StatusBadge>}
                {root.state === 'unknown' && <StatusBadge tone="warn">Not configured</StatusBadge>}
              </li>
            ))}
          </ul>
        )}
        <p className="field-hint" id={rootsHelpId}>
          Every folder inside a root is scanned; names that start with a dot are skipped.
          {listed.some((root) => root.state === 'unavailable') &&
            ' An unavailable root is missing on the server right now and cannot be scanned until it is back.'}
          {listed.some((root) => root.state === 'unknown') &&
            ' A root that is not configured any more is refused when saving; untick it.'}
        </p>
        {visible.roots && (
          <p className="field-error" id={rootsErrorId}>
            {visible.roots}
          </p>
        )}
      </fieldset>

      <div className="settings-fields">
        <Field
          label="Interval (minutes)"
          value={values.interval}
          onChange={(interval) => update({ interval })}
          min={5}
          max={1440}
          hint="How often a scan starts: 5 to 1,440 minutes (a day)."
          error={visible.interval}
        />
        <Field
          label="Settle time (minutes)"
          value={values.settle}
          onChange={(settle) => update({ settle })}
          min={0}
          max={1440}
          hint="A file changed more recently is left for a later scan, so a file still being copied is not queued. 0 to 1,440."
          error={visible.settle}
        />
        <Field
          label="Files per scan"
          value={values.maxFiles}
          onChange={(maxFiles) => update({ maxFiles })}
          min={1}
          max={50000}
          hint={`At most this many files per scan, oldest folders first; the rest wait for the next one. 1 to ${formatCount(50000)}.`}
          error={visible.maxFiles}
        />
      </div>

      <p className="hint">
        A file that failed to build in an earlier automatic job is not queued again until it
        changes. Scanning runs at any time; building what it queued follows Pause and the working
        hours.
      </p>

      <ActionError error={save.error} action="The server did not accept the automatic scan settings" />

      <div className="actions">
        <button type="submit" className="button" disabled={save.pending || !dirty}>
          {save.pending && <span className="spinner spinner--small" aria-hidden="true" />}
          Save automatic scan
        </button>
        {dirty && !save.pending && (
          <button
            type="button"
            className="button button--quiet"
            onClick={() => {
              setValues(scanValuesOf(initial));
              setShowErrors(false);
              save.reset();
            }}
          >
            Undo changes
          </button>
        )}
      </div>
    </form>
  );
}
