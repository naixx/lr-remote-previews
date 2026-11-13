/** Three stacked frames: the app's mark. Decorative, so hidden from assistive technology. */
export function BrandMark({ className }: { className?: string }) {
  return (
    <svg className={className} viewBox="0 0 32 32" width="24" height="24" aria-hidden="true">
      <rect x="9" y="3" width="20" height="16" rx="3" fill="currentColor" opacity="0.35" />
      <rect x="6" y="8" width="20" height="16" rx="3" fill="currentColor" opacity="0.6" />
      <rect x="3" y="13" width="20" height="16" rx="3" fill="currentColor" />
      <path d="M7 25l4.5-5 3 3.2 2-2.2 3.5 4z" fill="var(--color-surface)" />
    </svg>
  );
}
