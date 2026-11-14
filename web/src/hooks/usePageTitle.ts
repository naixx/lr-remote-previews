import { useEffect } from 'react';

export const APP_TITLE = 'LR Remote Previews';

/** Sets the document title to `<title> · LR Remote Previews` while the page is shown. */
export function usePageTitle(title: string | null): void {
  useEffect(() => {
    document.title = title ? `${title} · ${APP_TITLE}` : APP_TITLE;
  }, [title]);
}
