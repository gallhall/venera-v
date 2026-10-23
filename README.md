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
- Video player with episodes, fullscreen, gestures, lock, skips and remembered settings
- Playback history and resume from the saved position
- Download episodes (including DASH streams) in a chosen quality, play them offline, and export them as files
- Import local videos and subtitles
- Find streams by opening the web page of a video
- On iOS, playback in the system player, with lock screen controls

## Download
Installers for Android, iOS, Windows, macOS and Linux (deb, Arch) are on the [Releases](https://github.com/gallhall/venera-v/releases) page.

venera-v installs as its own app (`com.github.gallhall.venerav` on Android), so it can be installed next to venera.

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

## Headless Mode
See [Headless Doc](doc/headless_doc.md)
