import { next, rewrite } from '@vercel/functions';

/**
 * Markdown content negotiation, per acceptmarkdown.com.
 *
 * Every page on this site exists twice: `about.html` for browsers and `about.md` for agents. The
 * canonical URL is the one without an extension, and this picks which of the two it returns from
 * the request's `Accept` header. `Vary` goes on both answers, because without it the first
 * response a CDN caches for a URL is the one every later client gets, whichever audience it was
 * meant for.
 *
 * The `.md` twins stay reachable on their own paths too. They cost nothing and some agents look
 * for them before they try negotiation.
 */

/** The two representations this site can produce, best first. */
const CAN_PRODUCE = ['text/markdown', 'text/html'];

/** What to send when the client expressed no preference. */
const DEFAULT_TYPE = 'text/html';

/** Canonical path to the file that holds each representation. */
const PAGES = {
  '/': { 'text/html': '/index.html', 'text/markdown': '/index.md' },
  '/about': { 'text/html': '/about.html', 'text/markdown': '/about.md' },
  '/contact': { 'text/html': '/contact.html', 'text/markdown': '/contact.md' },
  '/privacy': { 'text/html': '/privacy.html', 'text/markdown': '/privacy.md' },
};

export const config = {
  matcher: ['/', '/index.html', '/about', '/about.html', '/contact', '/contact.html', '/privacy', '/privacy.html'],
};

/**
 * Parse one `Accept` header into its entries. A fully specified type outranks a subtype wildcard,
 * which outranks the catch-all wildcard, when two entries carry the same q.
 */
function parseAccept(header) {
  return header
    .split(',')
    .map((entry) => {
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
      return { type, q, specificity };
    })
    .filter(Boolean);
}

/**
 * What an Accept list says about one concrete media type: the q-value from the most specific entry
 * that matches it, and whether that entry rejected it outright.
 */
function scoreFor(mediaType, entries) {
  const [group] = mediaType.split('/');
  let best = null;
  for (const entry of entries) {
    const matches =
      entry.type === mediaType || entry.type === `${group}/*` || entry.type === '*/*';
    if (!matches) continue;
    if (!best || entry.specificity > best.specificity) best = entry;
  }
  return { q: best ? best.q : 0, rejected: Boolean(best) && best.q === 0 };
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
  if (!header || !header.trim()) return DEFAULT_TYPE;
  const entries = parseAccept(header);
  if (entries.length === 0) return DEFAULT_TYPE;

  const scored = CAN_PRODUCE.map((type) => ({ type, ...scoreFor(type, entries) }));
  const best = Math.max(...scored.map((s) => s.q));

  if (best === 0) {
    // Nothing scored. If the client named anything it does want, it wants a type this site has
    // never heard of, and 406 is the honest answer.
    if (entries.some((entry) => entry.q > 0)) return null;
    const allowed = scored.filter((s) => !s.rejected).map((s) => s.type);
    if (allowed.length === 0) return null;
    return allowed.includes(DEFAULT_TYPE) ? DEFAULT_TYPE : allowed[0];
  }

  // Ties go to the site's default, so a browser sending `text/html` alongside a wildcard still
  // gets HTML.
  const winners = scored.filter((s) => s.q === best).map((s) => s.type);
  return winners.includes(DEFAULT_TYPE) ? DEFAULT_TYPE : winners[0];
}

/** `/about.html` and `/about` are the same page as far as negotiation is concerned. */
function canonicalPath(pathname) {
  if (pathname === '/index.html') return '/';
  const stripped = pathname.replace(/\.html$/, '');
  return PAGES[stripped] ? stripped : pathname;
}

const VARY = 'Accept, Accept-Encoding';

export default function middleware(request) {
  const url = new URL(request.url);
  const page = PAGES[canonicalPath(url.pathname)];
  if (!page) return next();

  const chosen = negotiate(request.headers.get('accept'));

  if (chosen === null) {
    return new Response(
      [
        'Not Acceptable.',
        '',
        `${url.pathname} is available as:`,
        '  text/html',
        '  text/markdown',
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
    // A rewrite, not a sub-request back to our own URL. Fetching ourselves would go out through
    // the edge, which on a protected preview deployment means fetching the SSO login page and
    // serving it as if it were the Markdown.
    return rewrite(new URL(page['text/markdown'], url.origin), {
      headers: {
        link: `<${page['text/markdown']}>; rel="alternate"; type="text/markdown"`,
        vary: VARY,
      },
    });
  }

  return next({
    headers: {
      link: `<${page['text/markdown']}>; rel="alternate"; type="text/markdown"`,
      vary: VARY,
    },
  });
}
