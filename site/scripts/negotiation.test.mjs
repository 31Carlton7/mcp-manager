import assert from 'node:assert/strict';
import { test } from 'node:test';

import middleware from '../middleware.js';

/** What the middleware did with one `Accept`: the chosen representation, or `406`. */
async function answerFor(accept) {
  const headers = accept === null ? {} : { accept };
  const response = await middleware(new Request('https://mcpmanager.space/about', { headers }));
  if (response.status === 406) return '406';
  return response.headers.get('x-middleware-rewrite') ? 'markdown' : 'html';
}

const cases = [
  ['no Accept at all', null, 'html'],
  ['a browser', 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8', 'html'],
  ['curl and anything else sending only a wildcard', '*/*', 'html'],
  ['a whole-group wildcard', 'text/*', 'html'],
  ['Markdown alone', 'text/markdown', 'markdown'],
  ['Markdown named first, no q values', 'text/markdown, text/html', 'markdown'],
  ['HTML named first, no q values', 'text/html, text/markdown', 'html'],
  ['Markdown at the higher q', 'text/html;q=0.9, text/markdown;q=1.0', 'markdown'],
  ['HTML excluded', 'text/html;q=0', 'markdown'],
  ['Markdown excluded', 'text/markdown;q=0', 'html'],
  ['an exclusion alongside a wildcard', '*/*;q=0.5, text/markdown;q=0', 'html'],
  ['a type this site cannot produce', 'application/json', '406'],
  ['everything excluded', '*/*;q=0', '406'],
  ['a real want this site cannot meet, plus an exclusion', 'text/plain;q=0.5, text/markdown;q=0', '406'],
];

for (const [scenario, accept, expected] of cases) {
  test(`${scenario} gets ${expected}`, async () => {
    assert.equal(await answerFor(accept), expected);
  });
}

test('every answer carries Vary, so a CDN cannot serve one audience the other one', async () => {
  for (const accept of ['text/html', 'text/markdown', 'application/json']) {
    const response = await middleware(new Request('https://mcpmanager.space/about', { headers: { accept } }));
    assert.equal(response.headers.get('vary'), 'Accept, Accept-Encoding', accept);
  }
});

test('both representations advertise the Markdown alternate', async () => {
  for (const accept of ['text/html', 'text/markdown']) {
    const response = await middleware(new Request('https://mcpmanager.space/about', { headers: { accept } }));
    assert.equal(response.headers.get('link'), '</about.md>; rel="alternate"; type="text/markdown"', accept);
  }
});

test('the .html path is the same page as the canonical one', async () => {
  const response = await middleware(
    new Request('https://mcpmanager.space/about.html', { headers: { accept: 'text/markdown' } }),
  );
  assert.equal(response.headers.get('x-middleware-rewrite'), 'https://mcpmanager.space/about.md');
});
