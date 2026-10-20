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

### VideoPlaySource

| Field | Type | Description |
|---|---|---|
| `url` | `string` | Required. Stream url: MP4, HLS (`.m3u8`), DASH (`.mpd`) or anything else libmpv can play. |
| `name` | `string?` | Label in the source picker, e.g. `"1080P"`, `"Line 2"`. Defaults to `"Source n"`. |
| `type` | `string?` | `"auto"` (default), `"mp4"`, `"hls"` or `"dash"`. A hint only: the player detects the format by itself. |
| `headers` | `object?` | Request headers for this stream. Merged over `VideoPlayInfo.headers`, a header set here wins (names are case-insensitive). |
| `audioUrl` | `string?` | External audio stream, for sites that serve audio and video separately. |

A source can also be just a url string.

### VideoSubtitle

| Field | Type | Description |
|---|---|---|
| `url` | `string` | Required. WebVTT, SRT, ASS... |
| `name` | `string?` | Label in the subtitle picker. |
| `language` | `string?` | e.g. `"en"`, `"zh-CN"`. |

A subtitle can also be just a url string.

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
new VideoPlayInfo({sources, subtitles, headers})
new VideoPlaySource({url, name, type, headers, audioUrl})
new VideoSubtitle({url, name, language})
```
