# venera-v
[![flutter](https://img.shields.io/badge/flutter-3.41.4-blue)](https://flutter.dev/)
[![License](https://img.shields.io/github/license/gallhall/venera-v)](https://github.com/gallhall/venera-v/blob/master/LICENSE)
[![Download](https://img.shields.io/github/v/release/gallhall/venera-v)](https://github.com/gallhall/venera-v/releases)

English | [简体中文](README.zh-CN.md)

A comic and video reader that supports local and network content.

venera-v is a fork of [venera](https://github.com/venera-app/venera), which is no longer maintained.
It keeps everything venera does and adds video playback.

## Features
- Read local comics
- Use javascript to create comic sources
- Read comics from network sources
- Manage favorite comics
- Download comics
- View comments, tags, and other information of comics if the source supports
- Login to comment, rate, and other operations if the source supports

### Video (venera-v only)
- Video sources: comic sources with `mediaType = "video"`, plus `video.loadPlayInfo` for playback
- Use [Kazumi](https://github.com/Predidit/Kazumi) anime rules and [Animeko](https://github.com/creamycake-anime/animeko-subs) subscriptions as video sources, see [Kazumi Rules](doc/kazumi_rules.md)
- Video player with episodes, fullscreen, gestures, lock, skips and remembered settings; switch sources and lines inside the player, and switch automatically when one fails
- Playback history and resume from the saved position
- Download episodes (including DASH streams) in a chosen quality, play them offline, and export them as files
- Import local videos and subtitles
- Find streams by opening the web page of a video
- Playback with media_kit on every platform

### Anime (venera-v only)
- [Bangumi](https://bgm.tv): find anime by subject, airing schedule, collections, and sync of watched episodes
- BT: play torrents while they download from RSS sources such as Mikan and Nyaa, with preferred release groups, resolution and subtitles; download them too
- Danmaku: Bilibili first, [DanDanPlay](https://www.dandanplay.com) as fallback
- Bangumi comments of the subject and of each episode, in the player
- [Anime4K](https://github.com/bloc97/Anime4K) upscaling, with presets for phones that step down when frames drop or the device is hot
- Styled ASS/SSA subtitles, and a CJK font on every platform
- Cache management by anime and episode

## Download
Installers for Android, iOS, Windows, macOS and Linux (deb, Arch) are on the [Releases](https://github.com/gallhall/venera-v/releases) page.

venera-v installs as its own app (`com.github.gallhall.venerav` on Android), so it can be installed next to venera.

## Links
- [Releases](https://github.com/gallhall/venera-v/releases): installers of every version
- [venerav-configs](https://github.com/gallhall/venerav-configs): the source list venera-v uses by default
- [Telegram channel](https://t.me/VeneraV_Updates): release announcements
- [venera](https://github.com/venera-app/venera): the project venera-v is based on

## Build from source
1. Clone the repository
2. Install flutter, see [flutter.dev](https://flutter.dev/docs/get-started/install)
3. Install rust, see [rustup.rs](https://rustup.rs/)
4. Build for your platform: e.g. `flutter build apk`

Publishing a GitHub Release runs the `Build ALL` workflow, which builds every platform and uploads the installers to that release.

## Create a new comic source
See [Comic Source](doc/comic_source.md)

## Create a new video source
See [Video Source](doc/video_source.md). [demo_video.js](doc/demo_video.js) is a complete example that plays public test streams.

## Thanks

### venera
[venera](https://github.com/venera-app/venera) by [wgh136](https://github.com/wgh136) and its contributors, which this project is built on.

### Tags Translation
[EhTagTranslation](https://github.com/EhTagTranslation/Database)

The Chinese translation of the manga tags is from this project.

### Kazumi
[Kazumi](https://github.com/Predidit/Kazumi) and [KazumiRules](https://github.com/Predidit/KazumiRules)

venera-v reads the anime rule format of Kazumi.

### Animeko
[Animeko](https://github.com/open-ani/animeko) and [animeko-subs](https://github.com/creamycake-anime/animeko-subs)

venera-v reads Animeko subscription sources, and its BT and RSS playback follows the way Animeko does it.

### Others
- [Bangumi](https://bgm.tv) for subjects, episodes, collections and comments
- [DanDanPlay](https://www.dandanplay.com) and Bilibili for danmaku
- [Anime4K](https://github.com/bloc97/Anime4K) for the upscaling shaders
- [media_kit](https://github.com/media-kit/media-kit) for playback
- [dtorrent_task_v2](https://github.com/atlet99/dtorrent_task_v2), [rhttp](https://codeberg.org/Tienisto/rhttp), [tray_manager](https://github.com/leanflutter/tray_manager) and [connectivity_plus](https://github.com/fluttercommunity/plus_plugins), included in `packages/` with changes

## Headless Mode
See [Headless Doc](doc/headless_doc.md)

## Disclaimer
- venera-v is a free, open-source client for learning and personal use. It does not host, store, upload or distribute any comics, videos, torrents, subtitles or other content.
- Everything shown in the app comes from sources the user adds or chooses (comic and video sources, rules, RSS feeds, BT swarms) and from third-party services. The copyright of that content belongs to its owners. venera-v does not check, endorse or take responsibility for it.
- Users are responsible for what they access, download and share, and for complying with the laws of their country or region and the terms of the services they use. BT downloads also upload to other peers while they run.
- venera-v is not affiliated with Bangumi, DanDanPlay, Bilibili, Kazumi, Animeko or any source it can use.
- The software is provided "as is", without warranty of any kind, under the [GPL-3.0 License](LICENSE). The authors are not liable for any loss or damage arising from its use.
