// Typed calls for the Library drawer. In Chromium WebUI every method goes
// through the shared open.rpc channel; outside it (vite dev / preview) the
// library.* methods run against preview.ts and the rest against the shared
// preview adapter.

import { isNativeWebUI, rpc, subscribeEvent, type RpcEventName, type RpcMethod } from '../shared/bridge';
import { previewCall } from './preview';
import type { LibraryMethod, LibReq, LibRes } from './types';

// The host opens the drawer with ?window_id=<id>; window-scoped methods act
// on that window instead of the active one.
const WINDOW_ID = (() => {
  try {
    const id = new URLSearchParams(window.location.search).get('window_id');
    return id && /^[0-9a-f-]{8,64}$/i.test(id) ? id : null;
  } catch {
    return null;
  }
})();

const WINDOW_SCOPED: ReadonlySet<string> = new Set([
  'library.close',
  'library.theme.get',
  'library.archive.restore',
  'library.archive.peek',
  'library.spaces.list',
  'library.spaces.switch',
  'library.openUrl',
]);

export async function call<M extends LibraryMethod>(method: M, payload: LibReq<M>): Promise<LibRes<M>> {
  if (WINDOW_ID && WINDOW_SCOPED.has(method) && !(payload as { window_id?: string }).window_id) {
    payload = { ...(payload as object), window_id: WINDOW_ID } as LibReq<M>;
  }
  if (isNativeWebUI()) {
    // The shared RpcMethod union predates the drawer's methods; the C++
    // domain registers them by name (open_library_ui.cc).
    return (await rpc(method as unknown as RpcMethod, payload as never)) as LibRes<M>;
  }
  return previewCall(method, payload);
}

/** Push events, including names outside the shared RPC_EVENTS list. */
export function onEvent(name: string, listener: (payload: unknown) => void): () => void {
  return subscribeEvent(name as RpcEventName, listener);
}

export function errorText(err: unknown, fallback: string): string {
  if (err instanceof Error && err.message) {
    const m = err.message;
    return m.charAt(0).toUpperCase() + m.slice(1).replace(/\.?$/, '.');
  }
  return fallback;
}

export const LIBRARY_EVENTS = {
  setSpaceTheme: 'library.setSpaceTheme',
  closeRequested: 'open.libraryCloseRequested',
} as const;
