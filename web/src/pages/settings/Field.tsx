import { useId } from 'react';

interface FieldProps {
  /** The visible label, with the unit: «Interval (minutes)». */
  label: string;
  value: string;
  onChange: (value: string) => void;
  hint: string;
  /** Shown under the hint, and marks the input invalid. */
  error?: string;
  /** `decimal` takes text such as `12.5`; `numeric` is a whole number input. */
  kind?: 'numeric' | 'decimal';
  min?: number;
  max?: number;
  /** Shown while the input is empty: what empty means. */
  placeholder?: string;
}

/** One labelled number input of a settings form, with its hint and its error. */
export function Field({
  label,
  value,
  onChange,
  hint,
  error,
  kind = 'numeric',
  min,
  max,
  placeholder,
}: FieldProps) {
  const id = useId();
  const hintId = useId();
  const errorId = useId();
  return (
    <div className="settings-field">
      <label className="field-label" htmlFor={id}>
        {label}
      </label>
      <input
        id={id}
        className="input input--short"
        // A decimal is plain text, so `12,5` reaches the check instead of being emptied by the
        // browser; whole numbers use the number input the rest of the page uses.
        type={kind === 'decimal' ? 'text' : 'number'}
        inputMode={kind}
        min={kind === 'numeric' ? min : undefined}
        max={kind === 'numeric' ? max : undefined}
        step={kind === 'numeric' ? 1 : undefined}
        autoComplete="off"
        placeholder={placeholder}
        value={value}
        aria-invalid={error ? true : undefined}
        aria-describedby={error ? `${hintId} ${errorId}` : hintId}
        onChange={(event) => onChange(event.target.value)}
      />
      <p className="field-hint" id={hintId}>
        {hint}
      </p>
      {error && (
        <p className="field-error" id={errorId}>
          {error}
        </p>
      )}
    </div>
  );
}
