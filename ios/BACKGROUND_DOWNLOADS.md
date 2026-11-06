# iOS background downloads

The app uses option B: a native `URLSessionConfiguration.background` transport
in `Runner/AppDelegate.swift`, reached through `venera/ios_downloads`.

`background_downloader` was evaluated. It supports headers, background transfers,
progress, cancellation and notifications, but would introduce another task and
file tracking layer alongside this app's existing queue. The native bridge keeps
the existing task models, paths, source hooks and notification coordinator. No
package or entitlement was added, and no extra Swift build registration is needed.

References:

- [background_downloader documentation](https://pub.dev/packages/background_downloader)
- [Apple: downloading files in the background](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)

Changed files:

- Native and notes: `ios/Runner/AppDelegate.swift`, `ios/BACKGROUND_DOWNLOADS.md`.
- Platform: `lib/foundation/platform/platform_capabilities.dart`,
  `ios_background_download.dart`, `ios_download_lifecycle.dart`, `ios_download_policy.dart`.
- BT: `lib/foundation/torrent/torrent_downloader.dart`, `torrent_metadata.dart`,
  `torrent_streamer.dart`.
- HTTP/tasks: `lib/network/download.dart`, `download_notification.dart`,
  `file_downloader.dart`, `images.dart`, `ios_http_downloads.dart`, `video_download.dart`.
- UI/locales: `lib/pages/video/video_cache_widgets.dart`, `assets/translation.json`.
- Tests: `test/ios_download_policy_test.dart`.

## Transfer ownership

- iOS always uses the native transport for offline comic image HTTP requests,
  direct video files, HLS/DASH resources and archive files. Playback HTTP and
  ordinary thumbnail loading retain their existing transport.
- HLS filtering, playlist localization and key references remain in Dart. All
  localized resources, including AES keys, are handed to native code in messages
  of at most 32 jobs. Native code persists the pending list and keeps at most four
  URLSession tasks submitted; it refills on native completion, without Dart timers.
- Comic request configurations are resolved ahead of image consumption. Dio still
  encodes request bodies and applies the app's cookie interceptors. Native raw
  image files are private staging files; `onResponse`, `onLoadFailed`, image scripts,
  ugoira packing, type detection and final image names remain with the image loader.
- Video resource jobs carry source headers, app cookies, Referer and explicit byte
  ranges. Explicit ranges require a matching 206 Content-Range. Native resume data
  handles a paused transfer; if it is unusable, a fresh download is attempted.
- Completed destinations are published only after URLSession has finished writing.
  Stable job identities and native snapshots reconnect Dart waiters without making
  new writers. Existing complete HLS files are skipped. Native work is cancelled
  and acknowledged before an episode source switch deletes its old directory.
- Progress/completion events update the existing tasks. While suspended, native
  code owns bytes and destinations; Flutter reconciles counts when it executes.

## Lifecycle and notifications

The iOS foreground gate pauses BT download and streaming engines on hidden/paused,
and resumes registered engines on resumed. Inactive system dialogs do not pause BT.
Metadata discovery is stopped and retried after foregrounding; its foreground wait
does not consume the peer timeout. Released handles unregister, so foregrounding
cannot revive user-cancelled work. HTTP never registers with this gate.

The BT cache row shows the translated foreground requirement. Notification
permission is requested with the first active download and remembered natively,
including a denial. The existing queue coordinator posts completion when its
queue drains and failure when a task enters its error state. Native background
session completion waits for Dart's notification-state acknowledgement, with a
25-second fallback, before returning Apple's completion handler.

## Boundaries and device verification

Source scripts and playlist discovery must run before their resources can be
handed off. Arbitrary JavaScript, image transforms, merges, extraction and library
updates cannot run indefinitely while Flutter is suspended. Raw files stay on disk
until Flutter can finish this bookkeeping. The native bridge reconnects transfers
on an OS relaunch; the app retains its existing policy of restoring Dart tasks
paused, and resuming a task consumes its completed files. Force-quitting the app
is outside iOS's background-transfer guarantee. URLSession uses the iOS network
stack rather than the Rust/ECH client. Android and desktop retain their transports.

No Flutter SDK or Xcode was available during implementation. The pure tests in
`test/ios_download_policy_test.dart` were added but could not be run. Required
device checks before release:

1. Start a large direct file with source cookies/Referer, lock the screen, verify
   byte progress on return, then pause/resume and cancel during an active transfer.
2. Download a large filtered HLS playlist with AES keys and separate audio. Leave
   it backgrounded through several native refills; check the localized playback,
   completed segment reuse, bounded task count and source-switch cancellation.
3. Test comic sources with URL rewriting, POST bodies, response scripts and ugoira;
   background after preparation and compare final files with foreground downloads.
4. Background BT during discovery and during transfer/streaming. Verify automatic
   resume, unchanged HTTP progress, and no revival of a manually cancelled lease.
5. Verify permission allowed/denied, a fast cached queue drain, ordinary queue drain,
   task failure, and OS relaunch delivery with the Flutter engine starting cold.
