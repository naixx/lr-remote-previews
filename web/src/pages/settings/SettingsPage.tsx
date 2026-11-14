import { useCallback, useId, useRef, useState, type FormEvent } from 'react';
import { isMissingEndpoint } from '../../api/errors';
import { CLIENT_API_VERSION, type ServerInfo } from '../../api/info';
import type { ServerSettings } from '../../api/settings';
import type { ServerStatus } from '../../api/status';
import { useApi } from '../../app/ApiContext';
import { links } from '../../app/router';
import { ActionError } from '../../components/ActionError';
import { Card } from '../../components/Card';
import { ConnectionNote } from '../../components/ConnectionNote';
import { ErrorPanel, OlderServerNote } from '../../components/ErrorPanel';
import { Fact } from '../../components/Fact';
import { PageHeader } from '../../components/PageHeader';
import { PauseButton } from '../../components/PauseButton';
import { StatePanel } from '../../components/StatePanel';
import { StatusBadge } from '../../components/StatusBadge';
import { useAction } from '../../hooks/useAction';
import { useApiResource } from '../../hooks/useApiResource';
import { usePolling } from '../../hooks/usePolling';
import { formatCount, plural } from '../../lib/format';
import { AutoScanCard } from './AutoScanCard';
import { CacheCard } from './CacheCard';
import {
  changesOf,
  formValuesOf,
  validate,
  type FormErrors,
  type FormValues,
} from './form';
import { SCAN_WATCH_MS, statusInterval } from './live';
import './settings.css';

/** The forms of the page, each saved on its own. */
type FormName = 'building' | 'autoScan' | 'cache';

interface Latest {
  /** The settings as the server last answered a change. */
  settings: ServerSettings;
  /** Per form: grows with every save of it, so that form starts again from the saved values. */
  versions: Record<FormName, number>;
  /** The form saved last, which shows «Saved»; null after any other change, such as Pause. */
  saved: FormName | null;
}

const FIRST_VERSIONS: Record<FormName, number> = { building: 0, autoScan: 0, cache: 0 };

export function SettingsPage() {
  const { client } = useApi();
  const loadInfo = useCallback((signal: AbortSignal) => client.getInfo(signal), [client]);
  const loadSettings = useCallback((signal: AbortSignal) => client.getSettings(signal), [client]);
  const loadStatus = useCallback((signal: AbortSignal) => client.getStatus(signal), [client]);
  const info = useApiResource(loadInfo);
  const settings = useApiResource(loadSettings);
  const [latest, setLatest] = useState<Latest | null>(null);
  const current = latest?.settings ?? (settings.status === 'ready' ? settings.data : null);

  // The status gives the state of the scan and the size of the cache. After Scan now it is read
  // as often as during a scan for a while, so a short scan is not missed.
  const watchUntil = useRef(0);
  const interval = useCallback(
    (data: ServerStatus | null) => statusInterval(data, watchUntil.current),
    [],
  );
  const status = usePolling(loadStatus, { enabled: current !== null, interval });
  const refreshStatus = status.refresh;

  const changed = useCallback((next: ServerSettings, form: FormName | null) => {
    setLatest((previous) => {
      const versions = previous?.versions ?? FIRST_VERSIONS;
      return {
        settings: next,
        versions: form ? { ...versions, [form]: versions[form] + 1 } : versions,
        saved: form,
      };
    });
  }, []);

  const versions = latest?.versions ?? FIRST_VERSIONS;
  const roots = info.status === 'ready' ? info.data.roots : null;

  return (
    <div className="page">
      <PageHeader
        title="Settings"
        lead="How the server builds, scans and keeps its cache, and what it reports about itself."
      />
      <div className="page-stack">
        {current ? (
          <>
            {status.data && status.error && (
              <ConnectionNote error={status.error} updatedAt={status.updatedAt} />
            )}
            <BuildingCard settings={current} onChanged={(next) => changed(next, null)} />
            <Card title="Converter processes and working hours" wide>
              <SettingsForm
                key={versions.building}
                initial={current}
                onSaved={(next) => changed(next, 'building')}
              />
              {latest?.saved === 'building' && (
                <p className="callout callout--ok" role="status">
                  Saved. The change takes effect with the next wave of conversions.
                </p>
              )}
            </Card>
            <AutoScanCard
              settings={current.autoScan}
              roots={roots}
              scan={status.data ? status.data.autoScan : undefined}
              statusError={status.error}
              now={status.checkedAt ?? 0}
              formKey={versions.autoScan}
              saved={latest?.saved === 'autoScan'}
              onSaved={(next) => {
                changed(next, 'autoScan');
                refreshStatus();
              }}
              onScanStarted={() => {
                watchUntil.current = Date.now() + SCAN_WATCH_MS;
                refreshStatus();
              }}
            />
            <CacheCard
              limits={current.cache}
              cache={status.data?.cache ?? null}
              statusError={status.error}
              formKey={versions.cache}
              saved={latest?.saved === 'cache'}
              onSaved={(next) => changed(next, 'cache')}
              onCleaned={refreshStatus}
            />
          </>
        ) : settings.status === 'error' ? (
          isMissingEndpoint(settings.error) ? (
            <OlderServerNote feature="settings that can be changed from the dashboard" />
          ) : (
            <ErrorPanel
              error={settings.error}
              title="Settings could not be loaded"
              onRetry={settings.reload}
            />
          )
        ) : (
          <StatePanel tone="neutral" busy title="Loading the settings…" />
        )}

        <TokenCard auth={info.status === 'ready' ? info.data.auth : null} />

        {info.status === 'ready' ? (
          <ServerFacts info={info.data} />
        ) : info.status === 'error' ? (
          <ErrorPanel error={info.error} title="Server details could not be loaded" onRetry={info.reload} />
        ) : null}
      </div>
    </div>
  );
}

function BuildingCard({
  settings,
  onChanged,
}: {
  settings: ServerSettings;
  onChanged: (settings: ServerSettings) => void;
}) {
  return (
    <Card
      title="Building"
      wide
      aside={
        settings.paused ? (
          <StatusBadge tone="warn">Paused</StatusBadge>
        ) : (
          <StatusBadge tone="ok">Not paused</StatusBadge>
        )
      }
    >
      <div className="building">
        <p>
          {settings.paused
            ? 'Paused: no new wave of conversions starts. Queued files wait until you resume.'
            : 'The server builds whatever is queued, within the working hours if they are on.'}
        </p>
        <PauseButton paused={settings.paused} onChanged={onChanged} />
      </div>
    </Card>
  );
}

interface SettingsFormProps {
  initial: ServerSettings;
  onSaved: (settings: ServerSettings) => void;
}

function SettingsForm({ initial, onSaved }: SettingsFormProps) {
  const { client } = useApi();
  const ids = {
    auto: useId(),
    fixed: useId(),
    count: useId(),
    countHelp: useId(),
    countError: useId(),
    batch: useId(),
    batchHelp: useId(),
    batchError: useId(),
    hours: useId(),
    from: useId(),
    to: useId(),
    hoursHelp: useId(),
    hoursError: useId(),
  };
  const [values, setValues] = useState<FormValues>(() => formValuesOf(initial));
  const [showErrors, setShowErrors] = useState(false);
  const save = useAction(
    useCallback(
      (change: Parameters<typeof client.updateSettings>[0]) => client.updateSettings(change),
      [client],
    ),
  );

  const errors: FormErrors = validate(values);
  const visible: FormErrors = showErrors ? errors : {};
  const change = changesOf(initial, values);
  const hasChanges = Object.keys(change).length > 0;

  function update(patch: Partial<FormValues>) {
    setValues((previous) => ({ ...previous, ...patch }));
    save.reset();
  }

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (Object.keys(errors).length > 0) {
      setShowErrors(true);
      return;
    }
    if (!hasChanges) return;
    const saved = await save.run(change);
    if (saved) onSaved(saved);
  }

  return (
    <form className="settings-form" onSubmit={(event) => void handleSubmit(event)} noValidate>
      <fieldset className="settings-group">
        <legend className="settings-group__title">Converter processes</legend>
        <p className="field-hint">
          How many converter processes run side by side. Automatic comes to{' '}
          {plural(initial.effectiveWorkers, 'process', 'processes')} on this server.
        </p>
        <div className="settings-choices">
          <label className="check" htmlFor={ids.auto}>
            <input
              id={ids.auto}
              type="radio"
              name="workers"
              checked={values.workersMode === 'auto'}
              onChange={() => update({ workersMode: 'auto' })}
            />
            <span>Automatic</span>
          </label>
          <span className="settings-fixed">
            <label className="check" htmlFor={ids.fixed}>
              <input
                id={ids.fixed}
                type="radio"
                name="workers"
                checked={values.workersMode === 'fixed'}
                onChange={() => update({ workersMode: 'fixed' })}
              />
              <span>Fixed number</span>
            </label>
            <label className="visually-hidden" htmlFor={ids.count}>
              Number of converter processes
            </label>
            <input
              id={ids.count}
              className="input input--short"
              type="number"
              inputMode="numeric"
              min={1}
              max={32}
              step={1}
              value={values.workersCount}
              disabled={values.workersMode !== 'fixed'}
              aria-invalid={visible.workers ? true : undefined}
              aria-describedby={`${ids.countHelp}${visible.workers ? ` ${ids.countError}` : ''}`}
              onChange={(event) => update({ workersCount: event.target.value })}
            />
          </span>
        </div>
        <p className="field-hint" id={ids.countHelp}>
          1 to 32, never 2: two converter processes side by side waste CPU time. In effect now:{' '}
          <strong className="tabular">{formatCount(initial.effectiveWorkers)}</strong>.
        </p>
        {visible.workers && (
          <p className="field-error" id={ids.countError}>
            {visible.workers}
          </p>
        )}
      </fieldset>

      <fieldset className="settings-group">
        <legend className="settings-group__title">Files per process</legend>
        <label className="visually-hidden" htmlFor={ids.batch}>
          Files per process
        </label>
        <input
          id={ids.batch}
          className="input input--short"
          type="number"
          inputMode="numeric"
          min={1}
          max={64}
          step={1}
          value={values.batchSize}
          aria-invalid={visible.batchSize ? true : undefined}
          aria-describedby={`${ids.batchHelp}${visible.batchSize ? ` ${ids.batchError}` : ''}`}
          onChange={(event) => update({ batchSize: event.target.value })}
        />
        <p className="field-hint" id={ids.batchHelp}>
          How many files each converter process takes in one wave, 1 to 64.
        </p>
        {visible.batchSize && (
          <p className="field-error" id={ids.batchError}>
            {visible.batchSize}
          </p>
        )}
      </fieldset>

      <fieldset className="settings-group">
        <legend className="settings-group__title">Working hours</legend>
        <label className="check" htmlFor={ids.hours}>
          <input
            id={ids.hours}
            type="checkbox"
            checked={values.hoursEnabled}
            onChange={(event) => update({ hoursEnabled: event.target.checked })}
          />
          <span>Start conversions only between these times</span>
        </label>
        <div className="settings-hours">
          <label className="settings-time" htmlFor={ids.from}>
            <span className="field-label">From</span>
            <input
              id={ids.from}
              className="input input--short"
              type="time"
              value={values.from}
              disabled={!values.hoursEnabled}
              aria-invalid={visible.hours ? true : undefined}
              aria-describedby={`${ids.hoursHelp}${visible.hours ? ` ${ids.hoursError}` : ''}`}
              onChange={(event) => update({ from: event.target.value })}
            />
          </label>
          <label className="settings-time" htmlFor={ids.to}>
            <span className="field-label">To</span>
            <input
              id={ids.to}
              className="input input--short"
              type="time"
              value={values.to}
              disabled={!values.hoursEnabled}
              aria-invalid={visible.hours ? true : undefined}
              aria-describedby={`${ids.hoursHelp}${visible.hours ? ` ${ids.hoursError}` : ''}`}
              onChange={(event) => update({ to: event.target.value })}
            />
          </label>
        </div>
        <p className="field-hint" id={ids.hoursHelp}>
          The server&apos;s local time, 24-hour clock. A window across midnight, such as 22:00 to
          07:00, is fine; the same time twice is not. A wave that has started finishes.
        </p>
        {visible.hours && (
          <p className="field-error" id={ids.hoursError}>
            {visible.hours}
          </p>
        )}
      </fieldset>

      <ActionError error={save.error} action="The server did not accept the settings" />

      <div className="actions">
        <button type="submit" className="button" disabled={save.pending || !hasChanges}>
          {save.pending && <span className="spinner spinner--small" aria-hidden="true" />}
          Save settings
        </button>
        {hasChanges && !save.pending && (
          <button
            type="button"
            className="button button--quiet"
            onClick={() => {
              setValues(formValuesOf(initial));
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

function TokenCard({ auth }: { auth: ServerInfo['auth'] | null }) {
  const { token, tokenPersisted, forgetToken } = useApi();
  return (
    <Card title="Access token" wide>
      {token !== null ? (
        <div className="token-row">
          <p>
            {tokenPersisted
              ? 'A token is saved in this browser and sent with every request.'
              : 'The browser did not keep the token; it is used until this tab closes.'}
          </p>
          <button type="button" className="button button--secondary" onClick={forgetToken}>
            Forget token
          </button>
        </div>
      ) : (
        <p className="muted">
          {auth === 'none'
            ? 'This server does not ask for a token, so none is stored.'
            : 'No token is stored in this browser.'}
        </p>
      )}
      {token !== null && (
        <p className="hint">
          After forgetting it, the dashboard asks for the token again on its next request.
        </p>
      )}
    </Card>
  );
}

function ServerFacts({ info }: { info: ServerInfo }) {
  const { capabilities } = info;
  return (
    <Card title="Server" wide>
      <dl className="facts facts--small">
        <Fact label="Name">{info.name}</Fact>
        <Fact label="Server version">{info.version}</Fact>
        <Fact label="Dashboard version">{__APP_VERSION__}</Fact>
        <Fact label="API version">
          {info.api}
          {info.api !== CLIENT_API_VERSION && (
            <span className="facts__note facts__note--warn">
              This dashboard was built for API {CLIENT_API_VERSION}.
            </span>
          )}
        </Fact>
        <Fact label="Access">{info.auth === 'token' ? 'Token required' : 'Open, no token'}</Fact>
        <Fact label="Converter">
          <a href={links.converter()}>{info.converter.installed ? 'Installed' : 'Not installed'}</a>
        </Fact>
        <Fact label="Smart preview size">{formatCount(capabilities.previewLongEdge)} px long edge</Fact>
        <Fact label="Most photos per job">
          {capabilities.maxItemsPerJob === null ? 'Not reported' : formatCount(capabilities.maxItemsPerJob)}
        </Fact>
        <Fact label="Jobs kept">
          {capabilities.jobRetentionDays === null
            ? 'Not reported'
            : `${plural(capabilities.jobRetentionDays, 'day', 'days')} after they finish`}
        </Fact>
      </dl>

      <div className="settings-facts-block">
        <h3 className="settings-facts-block__title">Roots</h3>
        {info.roots.length === 0 ? (
          <p className="muted">No roots are configured on the server.</p>
        ) : (
          <ul className="roots" aria-label="Roots">
            {info.roots.map((root) => (
              <li className="roots__item" key={root.id}>
                <span className="roots__name">
                  <span className="roots__label">{root.label}</span>
                  <code className="roots__id">{root.id}</code>
                </span>
                {root.available ? (
                  <StatusBadge tone="ok">Available</StatusBadge>
                ) : (
                  <StatusBadge tone="bad">Unavailable</StatusBadge>
                )}
              </li>
            ))}
          </ul>
        )}
        <p className="hint">Roots are set in the server&apos;s configuration, not here.</p>
      </div>

      <div className="settings-facts-block">
        <h3 className="settings-facts-block__title">Raw formats</h3>
        {capabilities.extensions.length === 0 ? (
          <p className="muted">The server lists no supported raw formats.</p>
        ) : (
          <ul className="chips" aria-label="Supported raw file extensions">
            {capabilities.extensions.map((extension) => (
              <li className="chip" key={extension}>
                {extension}
              </li>
            ))}
          </ul>
        )}
      </div>
    </Card>
  );
}
