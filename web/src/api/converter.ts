import { asArray, asBoolean, asObject, asString, fieldPath } from './validate';

/** The steps of a self-test, in the order the server runs them. */
export const SELF_TEST_STEPS = ['installed', 'display', 'warm-up', 'conversion'] as const;

export interface SelfTestStep {
  /** One of SELF_TEST_STEPS; a newer server may add others. */
  name: string;
  ok: boolean;
  /** What was found, or why the step failed with the last lines of the converter's output. */
  detail: string;
}

/** Response of `POST /api/v1/converter/selftest`. */
export interface SelfTestResult {
  ok: boolean;
  /** The steps that ran; the ones after a failed step are left out. */
  steps: SelfTestStep[];
}

/** The optional body: a raw file to convert as the last step. */
export interface SelfTestFile {
  root: string;
  path: string;
}

function parseStep(value: unknown, path: string): SelfTestStep {
  const obj = asObject(value, path);
  return {
    name: asString(obj.name, fieldPath(path, 'name')),
    ok: asBoolean(obj.ok, fieldPath(path, 'ok')),
    detail: asString(obj.detail, fieldPath(path, 'detail')),
  };
}

/** Checks the shape of a self-test response; throws a ShapeError naming the first bad field. */
export function parseSelfTest(data: unknown): SelfTestResult {
  const obj = asObject(data, '');
  return {
    ok: asBoolean(obj.ok, 'ok'),
    steps: asArray(obj.steps, 'steps', parseStep),
  };
}
