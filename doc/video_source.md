# Video Source

> venera-v only. Video sources need app version 2.0.0 or later.

## Introduction

A video source is a [comic source](comic_source.md) with `mediaType = "video"`.
It is written, installed and updated the same way, and reuses most of the comic source APIs:

| Feature | API | Notes |
|---|---|---|
| Explore pages | `explore` | Return videos as `Comic` objects |
| Category pages | `category`, `categoryComics` | Same as comic sources |
| Search | `search` | Same as comic sources |
| Account / Favorites / Comments | `account`, `favorites`, `comic.loadComments`... | Same as comic sources |
| Details | `comic.loadInfo` | `chapters` are the **episodes** |
| Playback | `video.loadPlayInfo` | **New**, required for video sources |

APIs that only make sense for images (`comic.loadEp`, `comic.onImageLoad`, `comic.loadThumbnails`, `comic.archive`) are not used for video sources.

A complete example is [demo_video.js](demo_video.js).
It plays public test streams, so it can be installed as is to try the protocol.

## Basic information

```javascript
class DemoVideoSource extends ComicSource {
    name = "Demo Video"

    // unique id of the source, only letters, numbers and `_`
    key = "demo_video"

    version = "1.0.0"

    // Set it to 2.0.0 or later, so that apps without video support
    // refuse to install the source.
    minAppVersion = "2.0.0"

    url = ""

    // "comic" (default) or "video"
    mediaType = "video"

    // ...
}
```

A source without `mediaType`, or with `mediaType = "comic"`, is a comic source.
Installing a source with any other `mediaType`, or a video source without `video.loadPlayInfo`, fails.

## Lists

Explore, category, ranking, search and favorites pages return videos as `Comic` objects,
exactly like comic sources:

```javascript
new Comic({
    id: "12345",
    title: "Title",
    subtitle: "24 episodes",   // shown under the title, e.g. episode count or duration
    cover: "https://...",
    tags: ["Action", "2024"],
    description: "Updated to episode 12",
})
```

## Details and episodes

Video details are loaded with `comic.loadInfo` and returned as a `ComicDetails` object.
`chapters` holds the episodes:

```javascript
comic = {
    loadInfo: async (id) => {
        return new ComicDetails({
            title: "Title",
            cover: "https://...",
            description: "...",
            tags: {"Genre": ["Action"], "Year": ["2024"]},
            // episode id -> episode title
            chapters: {
                "ep1": "Episode 1",
                "ep2": "Episode 2",
            },
        })
    },
}
```

- For a video without episodes (e.g. a movie), leave `chapters` empty. `loadPlayInfo` then receives `null` as `epId`.
- Many sites offer the same episodes on several lines (mirrors).
  Use grouped chapters for that, the group name is the line name:

  ```javascript
  chapters: {
      "Line A": {"a1": "Episode 1", "a2": "Episode 2"},
      "Line B": {"b1": "Episode 1", "b2": "Episode 2"},
  }
  ```

  Episode ids must be unique across all groups.
- JavaScript objects put integer-like keys first, in numeric order. Use ids like `"ep1"` to keep the order you wrote.

## Playback

```javascript
video = {
    /**
     * Load the streams of an episode.
     * Called every time an episode is played, so returned urls may expire.
     * @param id {string} - video id
     * @param epId {string?} - episode id, null if the video has no episodes
     * @returns {Promise<VideoPlayInfo | {url: string} | string>}
     */
    loadPlayInfo: async (id, epId) => {
        let res = await Network.get(`https://example.com/api/play?id=${id}&ep=${epId}`)
        let data = JSON.parse(res.body)
        return new VideoPlayInfo({
            sources: data.streams.map((s) => new VideoPlaySource({
                name: s.quality,          // e.g. "1080P"
                url: s.url,
                type: "hls",
            })),
            subtitles: [
                new VideoSubtitle({name: "English", language: "en", url: data.subtitle}),
            ],
            headers: {
                "Referer": "https://example.com/",
            },
        })
    },
}
```

### VideoPlayInfo

| Field | Type | Description |
|---|---|---|
| `sources` | `VideoPlaySource[]` | Required, at least one. Different qualities or mirrors of the episode. The player starts with the **first** one, so put the preferred one first. |
| `subtitles` | `VideoSubtitle[]?` | External subtitle files. |
| `headers` | `object?` | Request headers sent with every stream and subtitle. |
| `skips` | `VideoSkip[]?` | Parts the player offers to skip, e.g. the opening and the ending. |

### VideoPlaySource

| Field | Type | Description |
|---|---|---|
| `url` | `string` | Required. Stream url: MP4, HLS (`.m3u8`), DASH (`.mpd`) or anything else libmpv can play. |
| `name` | `string?` | Label in the source picker, e.g. `"1080P"`, `"Line 2"`. Defaults to `"Source n"`. |
| `type` | `string?` | `"auto"` (default), `"mp4"`, `"hls"`, `"dash"`, or `"web"` for a web page with a player, see [Web page sniffing](#web-page-sniffing). Other values are hints only: the player detects the format by itself. |
| `headers` | `object?` | Request headers for this stream. Merged over `VideoPlayInfo.headers`, a header set here wins (names are case-insensitive). An empty value removes the shared header, e.g. `{"Referer": ""}` sends no Referer for this stream. |
| `audioUrl` | `string?` | External audio stream, for sites that serve audio and video separately. |

A source can also be just a url string.

### VideoSubtitle

| Field | Type | Description |
|---|---|---|
| `url` | `string` | Required. WebVTT, SRT, ASS... |
| `name` | `string?` | Label in the subtitle picker. |
| `language` | `string?` | e.g. `"en"`, `"zh-CN"`. |

A subtitle can also be just a url string.

### VideoSkip

| Field | Type | Description |
|---|---|---|
| `start` | `number` | Required. Start of the part, in seconds. |
| `end` | `number` | Required. End of the part, in seconds, after `start`. |
| `type` | `string?` | `"intro"`, `"outro"` or `"other"` (default). Decides the button label, e.g. "Skip intro". |

While the position is inside a part, the player shows a skip button.
If the user turned on automatic skipping in the player settings, it jumps to `end` directly, once per episode.

```javascript
skips: [
    new VideoSkip({start: 0, end: 90, type: "intro"}),
    new VideoSkip({start: 1350, end: 1440, type: "outro"}),
]
```

### Shorthands

When there is only one stream, `loadPlayInfo` can return less:

```javascript
// a url
return "https://example.com/video.m3u8"

// a single stream, with optional headers
return {
    url: "https://example.com/video.mp4",
    headers: {"Referer": "https://example.com/"},
}
```

### Requests made by the player

- If `User-Agent` is not set, the app's default browser User-Agent is used.
- If `Cookie` is not set, the cookies stored by the app for that domain (e.g. from `Network` requests or a webview login) are sent.
- The app's proxy setting applies to playback.
- Headers are handed to libmpv for the whole stream, so HLS segments and DASH fragments are requested with them too.

### Errors

Throw an error from `loadPlayInfo` to show it to the user, e.g. `throw "This episode needs VIP"`.

## Web page sniffing

Some sites build the stream url in the page: the player script decrypts it, calls an API with a signature, or runs in an iframe from another domain.
Instead of reproducing that in the source, the app can open the page in a hidden browser and catch the stream the player requests.

### Video.sniff

```javascript
loadPlayInfo: async (id, epId) => {
    // returns {url, headers, type}, which loadPlayInfo can return as is
    return await Video.sniff(`https://example.com/play/${id}-${epId}.html`, {
        match: "\\.m3u8",
    })
}
```

| Option | Type | Description |
|---|---|---|
| `match` | `string?` | Regular expression a stream url must match (the whole url). Defaults to urls whose path ends with `.m3u8`, `.mpd`, `.mp4`, `.m4v`, `.webm`, `.mkv`, `.mov` or `.flv`. HLS and DASH segments (`.ts`, `.m4s`) never match the default. |
| `exclude` | `string?` | Regular expression of urls to ignore, e.g. ads played before the video. |
| `timeout` | `number?` | In seconds, 20 by default. `Video.sniff` throws when no stream shows up in time. |
| `headers` | `object?` | Headers used to load the page. |
| `userAgent` | `string?` | User-Agent of the hidden browser. |
| `script` | `string?` | JavaScript run in the page after it loads, e.g. to click a play button: `"document.querySelector('.play-btn').click()"`. |
| `embedded` | `boolean?` | Also take a stream url found in the query of a request or an iframe, e.g. `https://player.example.com/?url=https://cdn.example.com/a.m3u8`, if the page plays no other stream within 8 seconds (players often play a signed url made from it). `false` by default. |

Without `match`, a response whose content is an HLS playlist (`#EXTM3U`) and the source of a `<video>` element count as streams even without a stream extension.

The result is the **first** matching request:

```javascript
{
    url: "https://cdn.example.com/hls/index.m3u8",
    // what the page sent with that request, to fetch the stream the same way
    // (no Referer if the page sends none, see "Referer" below)
    headers: {"Referer": "https://player.example.com/embed/1", "User-Agent": "...", "Cookie": "..."},
    type: "hls",  // from the extension, "auto" if unknown
}
```

Use it as a whole play info, or put it in a `VideoPlaySource` among others.

### type: "web"

Without any code, a source can set `type: "web"` on a `VideoPlaySource` whose `url` is a page.
After `loadPlayInfo` returns, the app sniffs each such page with the default patterns, using the source's headers to load it, and replaces the source with the stream it found and the page's headers.
If the page sent no Referer, the stream is played without one, even if `VideoPlayInfo.headers` has one.
Pages are opened in parallel; a page without a stream is dropped, and loading fails if no source is left.
Use `Video.sniff` for anything else, e.g. a `match` pattern or a script.

### How it works

- The page runs in a hidden webview (WebView2 on Windows, the system webview on Android, WKWebView on iOS and macOS) with the app's proxy and its own cookies, shared with webview logins.
- Requests are intercepted natively on Android and Windows, including the ones of iframes and media elements. On iOS and macOS, a script in every frame reports `fetch`, `XMLHttpRequest` and `<video>` urls instead.
- Videos in the page are started muted, as many players only request the stream on play.
- The result has the Referer the page sent, as many CDNs answer 403 to a Referer from another site, including to a page that sends none. On Android it is read from the intercepted request. Elsewhere, and for streams the script reports before they are intercepted, it follows the frame's referrer policy from `<meta name="referrer">` (legacy values such as `never` included) or the `fetch` call: none for `no-referrer`, the page's origin for `origin` (or for a stream on another site with `strict-origin`, `origin-when-cross-origin`...), and the page's url otherwise. A `Referrer-Policy` response header is only seen on Android. `referrerpolicy` on a `<video>` element changes nothing, in browsers neither.
- Sniffing takes seconds, and `loadPlayInfo` is called every time an episode is played or downloaded. Prefer reading the stream url from the page or an API when you can.
- Not available on Linux: `Video.sniff` throws.

You can try a page in **Settings > Debug > Video Player Test > Web Page Sniffing**.

## Downloads

Users can download episodes from the details page, after picking a quality among the ones the first episode offers (resolutions of HLS variants, DASH video tracks, and sources named like `"720P"`). The app calls `video.loadPlayInfo` for each episode, sniffing `"web"` sources as for playback, and saves the first source it can download, with the same request headers as playback:

- MP4 and other direct files, resumed after a pause or a restart;
- HLS: the variant of a master playlist at the picked quality (the highest one below it, or the lowest), with its segments, AES-128 keys and init segments;
- DASH: the video representation at the picked quality and the highest bandwidth audio one, preferring MP4 ones. Segment templates (`$Number$`, `$Time$` with a `SegmentTimeline`), segment lists with byte ranges and single files are supported;
- `audioUrl` and the subtitles.

Video and audio in separate fragmented MP4 tracks (DASH, or a direct video with an `audioUrl` serving fragmented MP4) are merged into one MP4 file, without re-encoding. Other separate tracks, e.g. WebM, are kept as two files and played together.

Live streams (HLS without `#EXT-X-ENDLIST`, DASH `type="dynamic"`), DRM-protected DASH and DASH manifests with several periods cannot be downloaded: the app tries the next source.

Downloaded episodes play from their files, without calling `loadPlayInfo`, and the skips returned at download time are kept.

## Testing a video source

Open a video from the source's pages and tap **Play** or an episode: the player page loads the play info and starts the first stream.
If a stream fails before it starts, the player switches to the next source; when all sources fail it shows the error with a retry button, which calls `loadPlayInfo` again.
After an episode ends, the next one starts.

To see the raw play info, use **Settings > Debug > Video Player Test > Video Source**:
choose the source, enter a video id, load it and tap an episode.
The returned play info is printed to the log on that page.

## Helpers

`init.js` provides constructors for the objects above.
Plain objects with the same fields work as well.

```javascript
new VideoPlayInfo({sources, subtitles, headers, skips})
new VideoPlaySource({url, name, type, headers, audioUrl})
new VideoSubtitle({url, name, language})
new VideoSkip({start, end, type})

// see Web page sniffing
await Video.sniff(url, {match, exclude, timeout, headers, userAgent, script, embedded})
```
