#!/usr/bin/env node
/**
 * Renders about.html, contact.html, privacy.html and sitemap.xml from pages.js and the `.md` file
 * beside each page, so every page's prose lives in exactly one file. The output is committed, and
 * `--check` re-renders into memory and exits non-zero when what is committed no longer matches.
 */
import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { marked } from 'marked';

import { ORIGIN, PAGES } from '../pages.js';
import { config } from '../middleware.js';

const SITE = fileURLToPath(new URL('..', import.meta.url));

function layout(page, body) {
  const canonical = ORIGIN + page.path;
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${page.title}</title>
<meta name="description" content="${page.description}">
<meta property="og:title" content="${page.title}">
<meta property="og:description" content="${page.description}">
<meta property="og:url" content="${canonical}">
<meta property="og:image" content="${ORIGIN}/assets/og.png">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:site" content="@31carlton7">
<meta name="twitter:image" content="${ORIGIN}/assets/og.png">
<link rel="icon" type="image/png" href="/assets/icon.png">
<link rel="canonical" href="${canonical}">
<link rel="alternate" type="text/markdown" href="${page.markdown}">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Geist:wght@400;500&family=Geist+Mono:wght@400&display=swap" rel="stylesheet">
<link rel="stylesheet" href="/assets/site.css">
</head>
<body>

<header class="rail">
  <a href="/"><img src="/assets/icon.png" alt=""></a>
  <span>MCP Manager</span>
</header>

<main class="doc rail">
${body}
</main>

<footer class="rail">
  <a class="btn primary" href="https://github.com/31Carlton7/mcp-manager/releases/latest">
    Download the dmg
    <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M3 8h9M8.5 4.5 12 8l-3.5 3.5"/></svg>
  </a>
  <p class="fine">MCP Manager is free and <a href="https://github.com/31Carlton7/mcp-manager/blob/master/LICENSE">MIT licensed</a>, made by <a href="https://carltonaikins.com">Carlton Aikins</a> &middot; <a href="https://github.com/31Carlton7/mcp-manager">GitHub</a> &middot; Requires macOS 26</p>
  <p class="fine"><a href="/">Home</a> &middot; <a href="/about">About</a> &middot; <a href="/contact">Contact</a> &middot; <a href="/privacy">Privacy</a> &middot; <a href="/llms.txt">llms.txt</a></p>
</footer>

</body>
</html>
`;
}

/**
 * The Markdown carries absolute links so an agent that fetched only the `.md` can still follow
 * them; the HTML wants them relative so a preview deployment links to itself.
 *
 * marked escapes quotes everywhere; only an attribute needs that, so they are put back between
 * tags rather than leaving `&#39;` in every contraction of committed, diffed output.
 */
function renderBody(markdown) {
  return marked
    .parse(markdown)
    .replaceAll(`href="${ORIGIN}`, 'href="')
    .replace(/>([^<]*)</g, (_, text) => `>${text.replaceAll('&#39;', "'").replaceAll('&quot;', '"')}<`)
    .trimEnd()
    .replace(/^<li>/gm, '  <li>')
    .split('\n')
    .map((line) => (line ? `  ${line}` : line))
    .join('\n');
}

function renderSitemap() {
  const urls = PAGES.map(
    (page) => `  <url>
    <loc>${ORIGIN}${page.path}</loc>
    <lastmod>${page.lastmod}</lastmod>
    <changefreq>${page.changefreq}</changefreq>
    <priority>${page.priority}</priority>
    <xhtml:link rel="alternate" type="text/markdown" href="${ORIGIN}${page.markdown}"/>
  </url>`,
  );
  return `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"
        xmlns:xhtml="http://www.w3.org/1999/xhtml">
${urls.join('\n')}
</urlset>
`;
}

async function build() {
  const files = new Map();
  for (const page of PAGES.filter((p) => p.rendered)) {
    const markdown = await readFile(join(SITE, page.markdown.slice(1)), 'utf8');
    files.set(page.html.slice(1), layout(page, renderBody(markdown)));
  }
  files.set('sitemap.xml', renderSitemap());
  return files;
}

function uncoveredPaths() {
  const matched = new Set(config.matcher);
  return PAGES.flatMap((page) => [page.path, page.html]).filter((path) => !matched.has(path));
}

const checking = process.argv.includes('--check');
const files = await build();
const stale = [];

for (const [name, expected] of files) {
  const path = join(SITE, name);
  if (!checking) {
    await writeFile(path, expected);
    continue;
  }
  const actual = await readFile(path, 'utf8').catch(() => null);
  if (actual !== expected) stale.push(name);
}

const uncovered = uncoveredPaths();

if (stale.length || uncovered.length) {
  for (const name of stale) console.error(`site/${name} does not match its source. Run: npm run build`);
  for (const path of uncovered) console.error(`${path} is in pages.js but not in the middleware matcher.`);
  process.exit(1);
}

console.log(checking ? 'Site pages are up to date.' : `Wrote ${[...files.keys()].join(', ')}.`);
