import { useCallback, useState, type FormEvent } from 'react';
import { removedTotal, type CacheCleanResult, type CacheRemoved } from '../../api/cache';
import { describeError, type ApiError } from '../../api/errors';
import type { CacheLimits, ServerSettings } from '../../api/settings';
import type { ServerStatus } from '../../api/status';
import { useApi } from '../../app/ApiContext';
import { ActionError } from '../../components/ActionError';
import { Card } from '../../components/Card';
import { ConfirmPanel } from '../../components/ConfirmPanel';
import { OlderServerCallout } from '../../components/ErrorPanel';
import { Fact } from '../../components/Fact';
import { useAction } from '../../hooks/useAction';
import { explainCacheCleanError } from '../../lib/codes';
import { byteParts, formatCount, formatQuantity, plural } from '../../lib/format';
import {
  CACHE_MIN_TENTHS,
  cacheChange,
  cacheValuesOf,
  validateCache,
  type CacheErrors,
  type CacheValues,
} from './cacheForm';
import { Field } from './Field';

interface CacheCardProps {
  /** The saved limits; null from a server that has no cache clean-up. */
  limits: CacheLimits | null;
  /** The cache as the status reports it; null until the status has arrived. */
  cache: ServerStatus['cache'] | null;
  /** The status request failed. */
  statusError: ApiError | null;
  /** Grows with every save of this form, so the form starts again from the saved values. */
  formKey: number;
  /** Show «Saved»: this form was the last thing saved. */
  saved: boolean;
  onSaved: (settings: ServerSettings) => void;
  /** After a clean-up removed files: the page then reads the cache size again. */
  onCleaned: () => void;
}

const size = (bytes: number) => formatQuantity(byteParts(bytes));

export function CacheCard({
  limits,
  cache,
  statusError,
  formKey,
  saved,
  onSaved,
  onCleaned,
}: CacheCardProps) {
  return (
    <Card title="Cache" wide>
      <dl className="facts facts--small">
        <Fact label="Size">
          <span className="tabular">{cache ? size(cache.bytes) : '—'}</span>
          {limits && (
            <span className="facts__note">
              {limits.maxBytes === null ? 'No size limit' : `Limit ${size(limits.maxBytes)}`}
            </span>
          )}
        </Fact>
        <Fact label="Files">
          <span className="tabular">{cache ? formatCount(cache.entries) : '—'}</span>
          {limits && (
            <span className="facts__note">
              {limits.maxAgeDays === null
                ? 'No age limit'
                : `Removed after ${plural(limits.maxAgeDays, 'day', 'days')} unused`}
            </span>
          )}
        </Fact>
      </dl>
      {!cache && statusError && (
        <p className="muted">The size of the cache could not be read. {describeError(statusError)}</p>
      )}
      {limits === null ? (
        <OlderServerCallout feature="cache limits or a clean-up" />
      ) : (
        <>
          <p>
            A clean-up removes the DNGs whose original is gone or has changed, then those unused
            for longer than the age limit, then the least recently used until the cache fits the
            size limit; DNGs of active jobs are kept. The server cleans up once a day, and a
            removed DNG is simply built again when somebody asks for it.
          </p>
          <CacheForm key={formKey} initial={limits} onSaved={onSaved} />
          {saved && (
            <p className="callout callout--ok" role="status">
              Saved. The next clean-up uses these limits.
            </p>
          )}
          <CleanUp limits={limits} onCleaned={onCleaned} />
        </>
      )}
    </Card>
  );
}

function isDirty(initial: CacheValues, values: CacheValues): boolean {
  return initial.size !== values.size.trim() || initial.age !== values.age.trim();
}

function CacheForm({
  initial,
  onSaved,
}: {
  initial: CacheLimits;
  onSaved: (settings: ServerSettings) => void;
}) {
  const { client } = useApi();
  const [values, setValues] = useState<CacheValues>(() => cacheValuesOf(initial));
  const [showErrors, setShowErrors] = useState(false);
  const save = useAction(
    useCallback((cache: CacheLimits) => client.updateSettings({ cache }), [client]),
  );

  const errors = validateCache(initial, values);
  const visible: CacheErrors = showErrors ? errors : {};
  const dirty = isDirty(cacheValuesOf(initial), values);

  function update(patch: Partial<CacheValues>) {
    setValues((previous) => ({ ...previous, ...patch }));
    save.reset();
  }

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (Object.keys(errors).length > 0) {
      setShowErrors(true);
      return;
    }
    const change = cacheChange(initial, values);
    if (change === null) {
      setValues(cacheValuesOf(initial));
      return;
    }
    const next = await save.run(change);
    if (next) onSaved(next);
  }

  return (
    <form
      className="settings-form"
      aria-label="Cache limits"
      onSubmit={(event) => void handleSubmit(event)}
      noValidate
    >
      <div className="settings-fields">
        <Field
          label="Size limit (GB)"
          kind="decimal"
          value={values.size}
          onChange={(text) => update({ size: text })}
          placeholder="No limit"
          hint={`Empty for no limit; at least ${CACHE_MIN_TENTHS / 10} GB, one decimal at most. 1 GB is 1,000,000,000 bytes, as sizes are shown here.`}
          error={visible.size}
        />
        <Field
          label="Age limit (days)"
          value={values.age}
          onChange={(text) => update({ age: text })}
          min={1}
          max={3650}
          placeholder="No limit"
          hint="Days since a DNG was last built, found by a job or a lookup, or downloaded. Empty for no limit; 1 to 3,650."
          error={visible.age}
        />
      </div>

      <ActionError error={save.error} action="The server did not accept the cache limits" />

      <div className="actions">
        <button type="submit" className="button" disabled={save.pending || !dirty}>
          {save.pending && <span className="spinner spinner--small" aria-hidden="true" />}
          Save cache limits
        </button>
        {dirty && !save.pending && (
          <button
            type="button"
            className="button button--quiet"
            onClick={() => {
              setValues(cacheValuesOf(initial));
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

/** The non-zero reasons of a clean-up, in the order the server applies them. */
function reasonsOf(removed: CacheRemoved, limits: CacheLimits): string[] {
  const reasons: string[] = [];
  if (removed.originalGone > 0) {
    reasons.push(`${plural(removed.originalGone, 'DNG', 'DNGs')} whose original is gone or has changed`);
  }
  if (removed.expired > 0) {
    reasons.push(
      `${plural(removed.expired, 'DNG', 'DNGs')} not used for ${
        limits.maxAgeDays === null ? 'longer than the age limit' : plural(limits.maxAgeDays, 'day', 'days')
      }`,
    );
  }
  if (removed.overLimit > 0) {
    reasons.push(`${plural(removed.overLimit, 'DNG', 'DNGs')} used least recently, to fit the size limit`);
  }
  return reasons;
}

type CleanStage =
  | { step: 'idle' }
  /** A dry run found something to remove: ask before removing it. */
  | { step: 'confirm'; result: CacheCleanResult }
  /** A clean-up ran, or a dry run found nothing to remove. */
  | { step: 'done'; result: CacheCleanResult };

function CleanUp({ limits, onCleaned }: { limits: CacheLimits; onCleaned: () => void }) {
  const { client } = useApi();
  const [stage, setStage] = useState<CleanStage>({ step: 'idle' });
  const count = useAction(useCallback(() => client.cleanCache(true), [client]));
  const clean = useAction(useCallback(() => client.cleanCache(false), [client]));

  async function preview() {
    setStage({ step: 'idle' });
    clean.reset();
    const result = await count.run();
    if (!result) return;
    // A real clean-up in answer to a dry run would be a server fault; report what it did.
    const nothing = removedTotal(result) === 0;
    setStage(!result.dryRun || nothing ? { step: 'done', result } : { step: 'confirm', result });
    if (!result.dryRun && !nothing) onCleaned();
  }

  async function confirm() {
    const result = await clean.run();
    if (!result) return;
    setStage({ step: 'done', result });
    onCleaned();
  }

  const confirming = stage.step === 'confirm';

  return (
    <div className="settings-section cache-clean">
      <h3 className="settings-group__title">Clean-up</h3>
      <div className="actions">
        <button
          type="button"
          className="button button--secondary"
          disabled={count.pending || clean.pending || confirming}
          onClick={() => void preview()}
        >
          {count.pending && <span className="spinner spinner--small" aria-hidden="true" />}
          {count.pending ? 'Counting…' : 'Clean up now…'}
        </button>
        <p className="hint">
          Uses the saved limits. It first counts what would be removed and asks before removing
          anything.
        </p>
      </div>
      {stage.step === 'confirm' && (
        <ConfirmPanel
          title={`Remove ${plural(removedTotal(stage.result), 'DNG', 'DNGs')} from the cache?`}
          tone="danger"
          confirmLabel="Clean up"
          cancelLabel="Back"
          pending={clean.pending}
          onConfirm={() => void confirm()}
          onCancel={() => {
            clean.reset();
            setStage({ step: 'idle' });
          }}
        >
          <ul className="cache-reasons">
            {reasonsOf(stage.result.removed, limits).map((reason) => (
              <li key={reason}>{reason}</li>
            ))}
          </ul>
          <p>
            This frees {size(stage.result.bytesFreed)}. The files are built again when somebody
            asks for them; the numbers can change a little by the time the clean-up runs.
          </p>
        </ConfirmPanel>
      )}
      <ActionError
        error={count.error}
        action="Could not count what a clean-up would remove"
        explain={explainCacheCleanError}
      />
      <ActionError error={clean.error} action="The cache was not cleaned up" explain={explainCacheCleanError} />
      {stage.step === 'done' && <CleanResult result={stage.result} limits={limits} />}
    </div>
  );
}

function CleanResult({ result, limits }: { result: CacheCleanResult; limits: CacheLimits }) {
  const total = removedTotal(result);
  if (total === 0) {
    return (
      <p className="callout" role="status">
        {result.dryRun
          ? 'Nothing to remove under the saved limits.'
          : 'Nothing was removed.'}
      </p>
    );
  }
  return (
    <div className="callout callout--ok" role="status">
      <p>
        Removed {plural(total, 'DNG', 'DNGs')} and freed {size(result.bytesFreed)}:
      </p>
      <ul className="cache-reasons">
        {reasonsOf(result.removed, limits).map((reason) => (
          <li key={reason}>{reason}</li>
        ))}
      </ul>
    </div>
  );
}
