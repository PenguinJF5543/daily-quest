# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

@AGENTS.md

## Project

Daily Quest is a daily-mission tracker built as an installable PWA. The UI language is Spanish (`<html lang="es">`, manifest description). It is at an early stage: `src/app/page.tsx` is still the create-next-app placeholder.

Stack: Next.js 16 (App Router, `src/app/`), React 19, TypeScript (strict), Tailwind CSS v4 (configured in CSS via `@import "tailwindcss"` / `@theme` in `globals.css`, no `tailwind.config`), Serwist for the service worker. Import alias `@/*` → `src/*`. The package is ESM (`"type": "module"`).

## Commands

- `npm run dev` — runs `serwist build --watch` and `next dev` in parallel (via `concurrently`)
- `npm run build` — `next build`, then `serwist build`
- `npm run start` — serve the production build
- `npm run lint` — ESLint 9 flat config (`eslint.config.mjs`, extends `eslint-config-next` core-web-vitals + typescript)

No test framework is set up yet.

## PWA / service worker architecture

The service worker is built by the **Serwist CLI** as a separate step from Next's build, not by a Next webpack/turbopack plugin (`next.config.ts` has no Serwist wrapper). The pieces:

- `src/app/sw.ts` — service worker source. Uses `Serwist` with `self.__SW_MANIFEST` (injected precache list) and `defaultCache` runtime caching from `@serwist/next/worker`.
- `serwist.config.js` — `@serwist/next/config` build config: compiles `src/app/sw.ts` → `public/sw.js`. Because it reads Next's build output to generate the precache manifest, `serwist build` must run after `next build`.
- `src/app/layout.tsx` — wraps the app in `SerwistProvider` (`@serwist/next/react`) with `swUrl="/sw.js"` to register the worker; `metadata.manifest` points to `public/manifest.json`.
- `public/manifest.json` — web app manifest. It references `/icon-192.png` and `/icon-512.png`, which do not exist in `public/` yet.

Generated worker files in `public/` (`sw.js`, `swe-worker-*.js`) are build artifacts; `public/sw*` is gitignored. Don't edit them by hand.
