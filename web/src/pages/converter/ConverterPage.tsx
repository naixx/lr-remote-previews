import { useCallback, useId, useState, type FormEvent } from 'react';
import {
  SELF_TEST_STEPS,
  type SelfTestFile,
  type SelfTestResult,
} from '../../api/converter';
import { isMissingEndpoint, type ApiError } from '../../api/errors';
import type { ServerInfo } from '../../api/info';
import { useApi } from '../../app/ApiContext';
import { ActionError } from '../../components/ActionError';
import { Card } from '../../components/Card';
import { ErrorPanel } from '../../components/ErrorPanel';
import { PageHeader } from '../../components/PageHeader';
import { StatePanel } from '../../components/StatePanel';
import { StatusBadge } from '../../components/StatusBadge';
import { useAction } from '../../hooks/useAction';
import { useApiResource } from '../../hooks/useApiResource';
import { explainItemError } from '../../lib/codes';
import './converter.css';

export function ConverterPage() {
  const { client } = useApi();
  const loadInfo = useCallback((signal: AbortSignal) => client.getInfo(signal), [client]);
  const info = useApiResource(loadInfo);

  return (
    <div className="page">
      <PageHeader
        title="Converter"
        lead="Adobe DNG Converter builds the smart previews. Check here that the server finds it and can run it."
      />
      {info.status === 'loading' ? (
        <StatePanel tone="neutral" busy title="Connecting to the server…" />
      ) : info.status === 'error' ? (
        <ErrorPanel error={info.error} onRetry={info.reload} />
      ) : (
        <div className="page-stack">
          <ConverterCard converter={info.data.converter} />
          <SelfTestCard roots={info.data.roots} />
        </div>
      )}
    </div>
  );
}

function ConverterCard({ converter }: { converter: ServerInfo['converter'] }) {
  return (
    <Card
      title="Adobe DNG Converter"
      wide
      aside={
        converter.installed ? (
          <StatusBadge tone="ok">Installed</StatusBadge>
        ) : (
          <StatusBadge tone="warn">Not installed</StatusBadge>
        )
      }
    >
      <dl className="stack">
        <div>
          <dt className="stack__label">
            {converter.installed ? 'Path in the Wine prefix' : 'Expected path in the Wine prefix'}
          </dt>
          <dd>
            <code className="path">{converter.path}</code>
          </dd>
        </div>
        <div>
          <dt className="stack__label">Version</dt>
          <dd>
            {converter.installed
              ? (converter.version ?? 'Unknown: the server could not read it from the program file')
              : '—'}
          </dd>
        </div>
      </dl>
      <div className={converter.installed ? 'hint' : 'callout callout--warn'}>
        <p>
          Adobe DNG Converter is not part of LR Remote Previews: the project does not include it,
          download it or distribute it. You install it into the server&apos;s Wine prefix yourself,
          under Adobe&apos;s terms. <code>docs/converter.md</code> in the project describes where
          the server expects it, how to place it and which versions were verified.
        </p>
      </div>
    </Card>
  );
}

const STEP_LABELS: Record<string, string> = {
  installed: 'Converter installed',
  display: 'Virtual display',
  'warm-up': 'Warm-up',
  conversion: 'Test conversion',
};

function SelfTestCard({ roots }: { roots: ServerInfo['roots'] }) {
  const { client } = useApi();
  const rootId = useId();
  const pathId = useId();
  const pathHelpId = useId();
  const [root, setRoot] = useState(roots[0]?.id ?? '');
  const [path, setPath] = useState('');
  const [result, setResult] = useState<{ result: SelfTestResult; withFile: boolean } | null>(null);
  const test = useAction(
    useCallback((file: SelfTestFile | null) => client.runSelfTest(file), [client]),
  );

  const filePath = path.trim().replace(/^\/+/, '');
  const withFile = filePath !== '' && root !== '';

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setResult(null);
    const outcome = await test.run(withFile ? { root, path: filePath } : null);
    if (outcome) setResult({ result: outcome, withFile });
  }

  if (isMissingEndpoint(test.error)) {
    // Shown in place of the form: there is nothing to retry until the server is updated.
    return (
      <Card title="Self-test" wide>
        <p className="callout">
          This server is older than the dashboard and has no self-test. Update the server to
          version {__APP_VERSION__} or later to use it.
        </p>
      </Card>
    );
  }

  return (
    <Card title="Self-test" wide>
      <p>
        Checks step by step that the converter can run on the server. With a raw file it also
        converts that file; the result is not kept. If the server is building, the test waits for
        the running wave to finish and holds new ones back while it runs.
      </p>
      <form className="selftest-form" onSubmit={(event) => void handleSubmit(event)}>
        <fieldset className="selftest-file" disabled={test.pending}>
          <legend className="selftest-file__title">Raw file to convert (optional)</legend>
          <div className="selftest-file__fields">
            <label className="selftest-field" htmlFor={rootId}>
              <span className="field-label">Root</span>
              <select
                id={rootId}
                className="select"
                value={root}
                onChange={(event) => setRoot(event.target.value)}
              >
                {roots.length === 0 && <option value="">No roots configured</option>}
                {roots.map((entry) => (
                  <option key={entry.id} value={entry.id}>
                    {entry.label}
                    {entry.available ? '' : ' (unavailable)'}
                  </option>
                ))}
              </select>
            </label>
            <label className="selftest-field selftest-field--wide" htmlFor={pathId}>
              <span className="field-label">Path inside the root</span>
              <input
                id={pathId}
                className="input"
                type="text"
                spellCheck={false}
                autoComplete="off"
                placeholder="2026/2026.06.20 - shoot/IMG_0001.ARW"
                aria-describedby={pathHelpId}
                value={path}
                onChange={(event) => setPath(event.target.value)}
              />
            </label>
          </div>
          <p className="field-hint" id={pathHelpId}>
            Forward slashes, relative to the root. Leave it empty to run only the first steps.
          </p>
        </fieldset>
        <div className="actions">
          <button type="submit" className="button" disabled={test.pending}>
            {test.pending && <span className="spinner spinner--small" aria-hidden="true" />}
            {test.pending ? 'Running the self-test…' : 'Run self-test'}
          </button>
        </div>
      </form>

      <ActionError error={test.error} action="The self-test did not run" explain={explainSelfTestError} />
      {test.pending && (
        <p className="hint" role="status">
          Running. This takes a few seconds, longer while a wave of conversions finishes first.
        </p>
      )}
      {result && <SelfTestReport result={result.result} withFile={result.withFile} />}
    </Card>
  );
}

function explainSelfTestError(error: ApiError): string | null {
  if (error.code === 'busy') {
    return 'Another self-test is running on the server. Try again when it has finished.';
  }
  if (error.status === 422 && error.code) {
    const reason = explainItemError(error.code);
    return reason ? `The file cannot be used: ${reason}` : null;
  }
  return null;
}

function SelfTestReport({ result, withFile }: { result: SelfTestResult; withFile: boolean }) {
  const ran = new Set(result.steps.map((step) => step.name));
  const expected = SELF_TEST_STEPS.filter((name) => withFile || name !== 'conversion');
  const notRun = result.ok ? [] : expected.filter((name) => !ran.has(name));

  return (
    <section className="selftest-report" aria-labelledby="selftest-result" role="status">
      <h3 className="selftest-report__title" id="selftest-result">
        {result.ok ? (
          <StatusBadge tone="ok">Passed</StatusBadge>
        ) : (
          <StatusBadge tone="bad">Failed</StatusBadge>
        )}
        <span>
          {result.ok
            ? 'The converter runs on this server.'
            : 'The converter cannot run as it should. The failed step says why.'}
        </span>
      </h3>
      <ol className="checklist">
        {result.steps.map((step, index) => (
          <li
            key={`${step.name}-${index}`}
            className={step.ok ? 'checklist__item checklist__item--ok' : 'checklist__item checklist__item--bad'}
          >
            <span className="checklist__mark" aria-hidden="true">
              {step.ok ? '✓' : '✕'}
            </span>
            <div className="checklist__text">
              <p className="checklist__name">
                {STEP_LABELS[step.name] ?? step.name}
                <span className="checklist__verdict">{step.ok ? 'OK' : 'Failed'}</span>
              </p>
              {step.detail && <pre className="checklist__detail">{step.detail}</pre>}
            </div>
          </li>
        ))}
        {notRun.map((name) => (
          <li key={name} className="checklist__item checklist__item--skipped">
            <span className="checklist__mark" aria-hidden="true">
              –
            </span>
            <div className="checklist__text">
              <p className="checklist__name">
                {STEP_LABELS[name] ?? name}
                <span className="checklist__verdict">Not run</span>
              </p>
            </div>
          </li>
        ))}
      </ol>
      {result.ok && !withFile && (
        <p className="hint">
          Name a raw file above to also try a real conversion.
        </p>
      )}
    </section>
  );
}
