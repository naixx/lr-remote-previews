/**
 * Runs requests side by side under a signal of their own. If one fails the others are
 * cancelled, so a failed refresh leaves nothing in flight behind it; aborting `signal` aborts
 * them all. `start` gets the shared signal and usually returns a `Promise.all` of the requests.
 */
export async function loadTogether<T>(
  signal: AbortSignal,
  start: (signal: AbortSignal) => Promise<T>,
): Promise<T> {
  const controller = new AbortController();
  const forwardAbort = () => controller.abort(signal.reason);
  if (signal.aborted) forwardAbort();
  else signal.addEventListener('abort', forwardAbort, { once: true });

  try {
    return await start(controller.signal);
  } catch (error) {
    controller.abort();
    throw error;
  } finally {
    signal.removeEventListener('abort', forwardAbort);
  }
}
