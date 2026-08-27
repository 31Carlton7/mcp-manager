import { next, rewrite } from '@vercel/functions';
import { PAGES } from './pages.js';

/**
 * Markdown content negotiation, per acceptmarkdown.com.
 *
 * Every page here exists twice, `about.html` for browsers and `about.md` for agents, under one
 * canonical extensionless URL. `Vary` goes on both answers, because without it the first response
 * a CDN caches for a URL is the one every later client gets, whichever audience it was meant for.
 */

const PRODUCIBLE = ['text/html', 'text/markdown'];
const DEFAULT_TYPE = 'text/html';
const VARY = 'Accept, Accept-Encoding';

const BY_PATH = new Map(PAGES.flatMap((page) => [[page.path, page], [page.html, page]]));

export const config = {
  // Vercel reads this by static analysis at build time, so it cannot be derived from PAGES.
  // `npm run check` fails when it stops covering every path in the table.
  matcher: ['/', '/index.html', '/about', '/about.html', '/contact', '/contact.html', '/privacy', '/privacy.html'],
};

/**
 * Split an `Accept` header into entries. Specificity is RFC 9110's ranking: a full type outranks a
 * subtype wildcard, which outranks the catch-all, when two entries carry the same q.
 */
function parseAccept(header) {
  return header
    .split(',')
    .map((entry, order) => {
      const [rawType, ...params] = entry.split(';');
      const type = rawType.trim().toLowerCase();
      if (!type) return null;
      let q = 1;
      for (const param of params) {
        const [name, value] = param.split('=');
        if (name?.trim().toLowerCase() !== 'q') continue;
        const parsed = Number.parseFloat(value);
        q = Number.isFinite(parsed) ? Math.min(Math.max(parsed, 0), 1) : 1;
      }
      const specificity = type === '*/*' ? 0 : type.endsWith('/*') ? 1 : 2;
      return { type, q, specificity, order };
    })
    .filter(Boolean);
}

/** The entry that governs one media type: most specific match, highest q among equally specific. */
function scoreFor(mediaType, entries) {
  const [group] = mediaType.split('/');
  let best = null;
  for (const entry of entries) {
    if (entry.type !== mediaType && entry.type !== `${group}/*` && entry.type !== '*/*') continue;
    const better =
      !best ||
      entry.specificity > best.specificity ||
      (entry.specificity === best.specificity && entry.q > best.q);
    if (better) best = entry;
  }
  return { q: best ? best.q : 0, order: best ? best.order : Infinity, rejected: best?.q === 0 };
}

/**
 * Pick a representation, or `null` when the client has ruled all of them out.
 *
 * A missing or wildcard-only Accept is no constraint at all, so it gets the default. The two cases
 * that earn a 406 are the ones acceptmarkdown.com names: the client asked for something real that
 * this site cannot produce, or it rejected every representation this site has. An Accept made
 * entirely of `q=0` exclusions means "anything but these", so a type it did not name still wins.
 */
function negotiate(header) {
  if (!header?.trim()) return DEFAULT_TYPE;
  const entries = parseAccept(header);
  if (entries.length === 0) return DEFAULT_TYPE;

  const scored = PRODUCIBLE.map((type) => ({ type, ...scoreFor(type, entries) }));
  const best = Math.max(...scored.map((s) => s.q));

  if (best === 0) {
    if (entries.some((entry) => entry.q > 0)) return null;
    const allowed = scored.filter((s) => !s.rejected);
    if (allowed.length === 0) return null;
    return allowed.some((s) => s.type === DEFAULT_TYPE) ? DEFAULT_TYPE : allowed[0].type;
  }

  // A q tie is the server's to break, and header order is the only preference left inside one: an
  // agent sending `text/markdown, text/html` gets Markdown. One wildcard matches both types
  // through the same entry, so `*/*` from a browser or curl still lands on the default.
  const winners = scored.filter((s) => s.q === best);
  const firstNamed = Math.min(...winners.map((s) => s.order));
  const preferred = winners.filter((s) => s.order === firstNamed);
  return preferred.some((s) => s.type === DEFAULT_TYPE) ? DEFAULT_TYPE : preferred[0].type;
}

export default function middleware(request) {
  const url = new URL(request.url);
  const page = BY_PATH.get(url.pathname);
  if (!page) return next();

  const alternate = `<${page.markdown}>; rel="alternate"; type="text/markdown"`;
  const chosen = negotiate(request.headers.get('accept'));

  if (chosen === null) {
    return new Response(
      [
        'Not Acceptable.',
        '',
        `${url.pathname} is available as:`,
        ...PRODUCIBLE.map((type) => `  ${type}`),
        '',
        `You sent: Accept: ${request.headers.get('accept')}`,
      ].join('\n'),
      {
        status: 406,
        headers: {
          'content-type': 'text/plain; charset=utf-8',
          'cache-control': 'no-store',
          vary: VARY,
        },
      },
    );
  }

  if (chosen === 'text/markdown') {
    // A rewrite, not a sub-request back to our own URL: fetching this origin from inside a
    // protected preview deployment returns the SSO login page, which we would then serve as
    // Markdown.
    return rewrite(new URL(page.markdown, url.origin), {
      headers: { link: alternate, vary: VARY },
    });
  }

  return next({ headers: { link: alternate, vary: VARY } });
}
