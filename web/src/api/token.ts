/**
 * Keeps the access token in localStorage. Storage can be missing or throw (private windows,
 * blocked site data, quota), so every access is guarded and failures degrade to "no token".
 */

export const TOKEN_STORAGE_KEY = 'lr-remote-previews.token';

export function loadToken(): string | null {
  try {
    const value = window.localStorage.getItem(TOKEN_STORAGE_KEY);
    return value?.trim() ? value.trim() : null;
  } catch {
    return null;
  }
}

/** Returns false when the browser refused to store the token. */
export function saveToken(token: string): boolean {
  try {
    window.localStorage.setItem(TOKEN_STORAGE_KEY, token);
    return true;
  } catch {
    return false;
  }
}

export function clearToken(): void {
  try {
    window.localStorage.removeItem(TOKEN_STORAGE_KEY);
  } catch {
    // Nothing stored, or storage unavailable: either way there is nothing left to clear.
  }
}
