// Initial sub-route of an open:// page.
//
// C++ opens pages at sub-paths (browser/INTEGRATION.md "Track 7"):
//   open://library/spaces/<space id>, open://library/history,
//   open://boosts/new?host=<host>, open://settings/shortcuts,
//   open://welcome/help.
// Each host serves <host>.html for every path, so the page reads the route
// from location.pathname + location.search. Outside Chromium (Vite dev and
// preview serve only /<host>.html) the same route works as a hash:
//   /library.html#/spaces/<id>, /boosts.html#/new?host=example.com.

export interface PageRoute {
  /** Path segments after the host, decoded ("spaces", "<id>"). */
  segments: string[];
  /** Query parameters of the route (hash query wins over location.search). */
  params: URLSearchParams;
}

function decodeSegment(segment: string): string {
  try {
    return decodeURIComponent(segment);
  } catch {
    return segment;
  }
}

export function parsePageRoute(pathname: string, search: string, hash: string): PageRoute {
  const hashRoute = hash.replace(/^#\/?/, '');
  let path = pathname;
  const params = new URLSearchParams(search);
  if (hashRoute) {
    const queryAt = hashRoute.indexOf('?');
    path = queryAt >= 0 ? hashRoute.slice(0, queryAt) : hashRoute;
    if (queryAt >= 0) {
      new URLSearchParams(hashRoute.slice(queryAt + 1)).forEach((value, key) => params.set(key, value));
    }
  }
  const segments = path.split('/').filter(Boolean).map(decodeSegment);
  // Vite serves the page itself at /<host>.html: not part of the route.
  if (segments[0]?.endsWith('.html')) segments.shift();
  return { segments, params };
}

export function currentPageRoute(): PageRoute {
  if (typeof window === 'undefined') return { segments: [], params: new URLSearchParams() };
  const { pathname, search, hash } = window.location;
  return parsePageRoute(pathname, search, hash);
}

/**
 * Replaces the current route without a navigation (after a one-shot route
 * such as /spaces/<id> was handled, so a reload does not repeat it). Uses the
 * hash form when the page was opened that way (Vite).
 */
export function replacePageRoute(path: string): void {
  if (typeof window === 'undefined') return;
  const clean = path.replace(/^\/+/, '');
  const { pathname, hash } = window.location;
  const useHash = Boolean(hash) || pathname.endsWith('.html');
  try {
    if (useHash) {
      window.history.replaceState(null, '', `${pathname}${window.location.search}#/${clean}`);
    } else {
      window.history.replaceState(null, '', `/${clean}`);
    }
  } catch {
    // Some embedders refuse history changes; the route only repeats on reload.
  }
}
