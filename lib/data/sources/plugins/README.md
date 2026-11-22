# Scraper plugins

A plugin is **one JavaScript file** that finds playable streams for a film or an episode. VyseTV
downloads it from a *repository* (a `repo.json` on any web host, for example a GitHub raw URL), runs it in
a sandbox and lists it in Settings → Sources next to the built-in sources. The app ships no plugins.

* Engine and bridge: [`js_plugins.dart`](js_plugins.dart) (QuickJS through `flutter_js`, run in a separate isolate).
* Title helpers every plugin can call: [`assets/plugins/helpers.js`](../../../../assets/plugins/helpers.js).
* A working example: [`example/`](example).
* Tests: `test/js_plugins_test.dart`, `test/js_plugins_update_test.dart`, `test/source_order_test.dart`.

## For users

Settings → Plugins → add a repository URL (the address of its `repo.json`). Plugins appear in Sources, where they can be
reordered and switched off like any source. *Update automatically* checks the repositories once a day when the app
starts and downloads the plugins whose `version` changed. A repository whose `repo.json` was deleted (HTTP 404/410) is
dropped together with its plugins; one that is only unreachable is kept. Everything a plugin reports is kept in the
plugin log at the bottom of the Plugins section (on Android also written to a file).

Plugins run arbitrary code from the repository you add: only add repositories you trust. See *Sandbox* below.

## repo.json

```json
{
  "name": "My plugins",
  "plugins": [
    { "id": "mysite", "name": "MySite", "version": "1", "note": "Films and shows",
      "types": ["movie", "tv"], "url": "plugins/mysite.js" }
  ]
}
```

`id` is unique and stable, `version` is any string (a change triggers an update), `url` is relative to the
`repo.json` or absolute. `types` is `movie`, `tv` or both.

## The plugin contract

Define a global `getStreams(query)` (it may be `async`).

```js
// query
{
  tmdbId: 872585, imdbId: 'tt15398776',   // imdbId can be null
  type: 'movie' | 'tv', isTv: false,
  title: 'Oppenheimer', originalTitle: 'Oppenheimer', year: 2023,
  titles: ['Oppenheimer', /* every name TMDB knows it by */],
  isAnime: false,
  season: null, episode: null             // numbers for 'tv'
}

// return an array, empty when the title is not on the site
[{
  url: 'https://…',             // required, http(s) only
  type: 'hls' | 'dash' | 'mp4', // 'mp4' also for mkv/webm; guessed from the URL when left out
  quality: '1080p',             // shown in the list
  server: 'MySite Fast',        // shown in the list
  label: undefined,             // optional extra text
  audio: 'Hindi',               // optional: the language this link is dubbed in
  headers: { Referer: '…' }     // optional: sent with every request for this stream
}]
```

Return `[]` when the title is not found; do not throw for that. Put the best links first: auto-play tries at most 3
links per source, in your order.

### What the script can use

| Global | |
|---|---|
| `http(url, {method, headers, body, timeout})` | `Promise<{status, url, headers, text}>`. **Never throws**: on a network error `status` is `0` and `error` says why. Response header names are lower-case. `body` is a string or an object (sent as JSON). Up to 5 redirects are followed. `timeout` in ms, capped at 20000. |
| `JSON`, `RegExp`, `Promise`, `Math`, `Date`, `setTimeout`, `btoa`, `atob` | the language |
| `parseHtml(html)`, `unescapeHtml(s)` | a small HTML tree with CSS selectors (`select`, `selectFirst`, `attr`, `text`, `data`, `html`) |
| title helpers | `searchQueries`, `searchBest`, `searchByImdb`, `bestMatch`, `rankMatches`, `parseTitle`, `titleScore`, `imdbMatches`, `normTitle` |
| `console.log` | goes to the plugin log |

Not available: a browser DOM, `fetch`, `XMLHttpRequest`, `require`/`import`, Node APIs, `crypto`, WebAssembly, cookies
between calls (send them in `headers`).

### Sandbox

* The script has no access to the app, its files or its settings; only `http()` and the globals above.
* `http()` refuses `localhost`, loopback, private ranges (`10.x`, `172.16–31.x`, `192.168.x`), link-local and `*.local`,
  also after a redirect, so a plugin cannot reach the user's own network.
* Every call starts a fresh engine: nothing is cached between calls.

### Limits

* A source gets 30 s. The engine stops a script after 20 s of computation. Aim for under 10 s and run independent
  requests with `Promise.all`.
* QuickJS is an interpreter: CPU-heavy code (pure-JS crypto with many rounds) is 20–50× slower than in Node, more on a TV.

### What the app does with the links

Before playing, the app checks that a link serves video and skips it otherwise:

* `hls`: the playlist must contain `#EXTM3U`, then its first variant and first media piece must answer.
* `dash`: the manifest must contain `<MPD`.
* `mp4`/file: a ranged `GET` of the first bytes must return `200` or `206`.

So return direct stream URLs (not pages with a player), set `type` correctly, and drop expired signed URLs.

## Matching titles

Do not write your own matching. `searchBest(query, search, get)` runs the site's search with each string from
`searchQueries(query)` until a listing matches; matching ignores case and punctuation, checks a film's year, and for a
show prefers the right season. `imdbMatches(pageText, query)` confirms a page is the right film by its IMDb id.

```js
var hit = await searchBest(q, async function (text) {
  var r = await http(BASE + '/search?q=' + encodeURIComponent(text));
  return parseListings(r.text);               // [{ name: 'Dune Part Two (2024) 1080p', url: '…' }, …]
}, function (l) { return l.name; });
if (!hit) return [];
```

## Try a plugin without the app

The helpers file is plain JavaScript, so a plugin can be run in Node with a small stand-in for `http()` (see
`example/demo.js`, which only prints what it would return):

```
node lib/data/sources/plugins/example/run.mjs
```
