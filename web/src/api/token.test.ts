import { describe, expect, it, vi } from 'vitest';
import { clearToken, loadToken, saveToken, TOKEN_STORAGE_KEY } from './token';

function storageFailure(): never {
  throw new DOMException('Storage is disabled.', 'SecurityError');
}

describe('token storage', () => {
  it('saves, loads and clears the token', () => {
    expect(loadToken()).toBeNull();
    expect(saveToken('abc')).toBe(true);
    expect(window.localStorage.getItem(TOKEN_STORAGE_KEY)).toBe('abc');
    expect(loadToken()).toBe('abc');
    clearToken();
    expect(loadToken()).toBeNull();
  });

  it('treats a blank stored value as no token', () => {
    window.localStorage.setItem(TOKEN_STORAGE_KEY, '   ');
    expect(loadToken()).toBeNull();
  });

  it('survives storage that throws', () => {
    vi.spyOn(Storage.prototype, 'getItem').mockImplementation(storageFailure);
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation(storageFailure);
    vi.spyOn(Storage.prototype, 'removeItem').mockImplementation(storageFailure);

    expect(loadToken()).toBeNull();
    expect(saveToken('abc')).toBe(false);
    expect(() => clearToken()).not.toThrow();
  });
});
