# Vega providers in VyseTV

A repository link in Settings → Plugins can be a [Vega](https://github.com/Zenda-Cross/vega-providers) `manifest.json`: a JSON list of
providers, each built into `dist/<value>/{posts,meta,stream,episodes}.js` next to it. Every enabled provider becomes a source named
`vega-<value>`. (`disabled` ones, and the torrent/live/YouTube ones, are left out.)

Vega providers browse a site, so the app adapts them to the plugin contract `getStreams(query)`:

1. search the site with the title (`getSearchPosts`) and keep the listings that match (title, year; "Download …" prefixes are ignored),
2. read the page (`getMeta`; a listing naming another IMDb id is skipped) and pick the film's links, or the season and episode
   (`getEpisodes` when a season is loaded separately),
3. resolve each link to video files (`getStream`); DRM streams are dropped.

They run in the same sandbox, with the same time budget (17 s) and one retry for reset connections, as other plugins, on
`assets/plugins/vega_runtime.js`: the real axios (its transport replaced by the plugin `http()`), the real cheerio, polyfills for
`URL`, `URLSearchParams`, `TextEncoder`/`TextDecoder` and `AbortController`, a `fetch`, and the adapter. The domain a provider asks
`getBaseUrl` for is read from the repository's `urls.json`.

Not supported: `openWebView` (a browser challenge: those providers find nothing), cookies kept between calls, multipart bodies.

## Files

* `polyfills.js`, `adapter.js`: the sources. `package.json` pins axios, cheerio and esbuild.
* `node build.mjs` (after `npm install`): writes `assets/plugins/vega_runtime.js`. Rebuild after editing a source file.
* `node try.mjs <base-url> <provider> movie|tv "<title>" <year> <tmdbId> <imdbId> [season episode]`: runs one provider in Node and
  lists the streams, e.g.
  `node try.mjs https://raw.githubusercontent.com/Zenda-Cross/vega-providers/refs/heads/main moviezwap movie "Oppenheimer" 2023 872585 tt15398776`.
* `test/vega_plugins_test.dart` runs a provider with no network in the real QuickJS engine (it needs `build/linux/x64/release/bundle`).
