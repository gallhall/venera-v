# Kazumi Rules

venera-v can use the anime rules of [Kazumi](https://github.com/Predidit/Kazumi) as video sources.
A rule is a JSON file that says how to search a site and where the episodes of a result are; see [KazumiRules](https://github.com/Predidit/KazumiRules) for the rules and the format.

## Installing rules

In **Comic Source**:

- **Kazumi Rules** lists the rules of a rule repository, Kazumi's by default (`https://cdn.jsdelivr.net/gh/Predidit/KazumiRules@main/`). Add a rule, or update it when the repository has a newer version.
  Any folder with an `index.json` and `<name>.json` rules works as a repository, e.g. `https://raw.githubusercontent.com/Predidit/KazumiRules/main/`.
- The URL field and **Use a config file** accept a rule as well as a JS source: content starting with `{` is a rule.

An installed rule shows up as a source with a `Kazumi` badge. **Check updates** checks rules against the repository, by version, and **Edit** opens the rule's JSON.
Rules are saved next to the JS sources as `kazumi_<name>.kazumi.json` (`kazumi_<hash>` for names with other characters than letters, digits and `_`), so backups and data sync include them. The key must not change, or the history and favorites of the source are lost: it comes from the rule's `name`.

## How a rule is used

- **Search** sends the rule's search request and lists the results: one page, without covers in the rule, so the app takes the first lazy-loaded image (`data-original`, `data-src`...) or `img` of each result.
- **Details** load the result's page (or API) and list its play lines (`播放线路`) as chapter groups. The title and cover are the search result's, else the page's `og:` tags. An episode url found in several lines is only kept in the first one.
- **Play** opens the episode page in a hidden webview and plays the stream it requests, as [Web page sniffing](video_source.md#web-page-sniffing) does. A response that is an HLS playlist and the source of a `<video>` element count as streams. For rules with `useLegacyParser`, a stream url in the query of the player iframe is taken if the player plays no other stream within a few seconds (Kazumi takes it at once, but players often play a signed url made from it). An episode url that is itself a stream (`.m3u8`, `.mp4`...) is played without sniffing.
- Requests and the hidden webview use the rule's `userAgent`, or a desktop browser one as Kazumi does (some sites send mobile browsers to a page advertising their app), with the site as referer.
- Streams are fetched as Kazumi does: with that user agent and the rule's `referer` if it has one, not with the headers of the page's request (players often send no referer, and their CDNs reject foreign ones).

Downloads, history and favorites work as for other video sources.

## Supported

Rule API levels up to 9, the same as Kazumi at the time of writing:

| Field | |
|---|---|
| `searchURL`, `searchList`, `searchName`, `searchResult`, `chapterRoads`, `chapterResult` | XPath rules, evaluated like Kazumi: under a search result, `//a` means the `a` elements of that result. |
| `usePost` | The search url's query is also posted as a form. |
| `searchMode` / `chapterMode` `"api"` | JSON APIs: `searchApiConfig` and `chapterApiConfig` with requests (GET or POST, JSON or form bodies, `@keyword`, `@source` and other variables), JSONPath (`$`, `.name`, `[0]`, `[*]`, `['name']`), `sourceTemplate`, nested and delimited play lines, `variables` and `episodePage`. |
| `userAgent`, `referer`, `useLegacyParser` | See above. |
| `antiCrawlerConfig` | Captcha pages are recognized and reported, but not solved: verifying in a webview is not supported yet. A Cloudflare challenge shows the same verify button as for JS sources. |
| `adBlocker` | Ads between `#EXT-X-DISCONTINUITY` tags of HLS streams are removed for playback and downloads, with the rules of Kazumi's playlist filter, see [HLS ads](video_source.md#hls-ads). Kazumi plays such streams with a patched FFmpeg that skips the ads by their timestamps while playing; venera-v filters the playlist instead, so that the duration and seeking leave the ads out too. |

Not supported yet: captcha verification. `muliSources`, `useWebview` and `useNativePlayer` are ignored, as in recent Kazumi versions.

On Linux, where web page sniffing is not supported, only episodes whose url is a stream can be played.
