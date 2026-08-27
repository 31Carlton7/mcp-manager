export const ORIGIN = 'https://mcpmanager.space';

/**
 * Every canonical URL this site serves. The middleware negotiates against this table, the sitemap
 * is generated from it, and the pages marked `rendered` have their HTML generated from the
 * Markdown beside them, so a page's path is written down once.
 */
export const PAGES = [
  {
    path: '/',
    html: '/index.html',
    markdown: '/index.md',
    // The landing page is hand-built and index.md is a shorter summary written for agents, so
    // neither is generated from the other.
    rendered: false,
    lastmod: '2026-08-27',
    changefreq: 'weekly',
    priority: '1.0',
  },
  {
    path: '/about',
    html: '/about.html',
    markdown: '/about.md',
    rendered: true,
    title: 'About MCP Manager',
    description:
      'MCP Manager keeps one library of MCP servers and writes the config file for Claude Code, Claude Desktop, Cursor and Codex. What it does, how it is built, and who made it.',
    lastmod: '2026-08-27',
    changefreq: 'monthly',
    priority: '0.6',
  },
  {
    path: '/contact',
    html: '/contact.html',
    markdown: '/contact.md',
    rendered: true,
    title: 'Contact MCP Manager',
    description:
      'GitHub issues is the channel for bugs, feature requests and patches. Security problems go through GitHub security advisories.',
    lastmod: '2026-08-27',
    changefreq: 'monthly',
    priority: '0.5',
  },
  {
    path: '/privacy',
    html: '/privacy.html',
    markdown: '/privacy.md',
    rendered: true,
    title: 'Privacy for MCP Manager',
    description:
      'No analytics, no cookies, no account, no telemetry. Where your data lives, what the app connects to, and what the website does not collect.',
    lastmod: '2026-08-27',
    changefreq: 'monthly',
    priority: '0.5',
  },
];
