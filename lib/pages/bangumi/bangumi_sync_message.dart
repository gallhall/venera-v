import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/utils/translations.dart';

/// Tells the user how syncing progress to Bangumi went. Shown on the app's
/// root, as the sync may finish after the page that started it is gone.
void showBangumiSyncResult(BangumiSyncResult result) {
  var message = switch (result) {
    BangumiSyncMarked(:var number, :var isBook) => (isBook
            ? 'Marked chapter @n on Bangumi'
            : 'Marked episode @n on Bangumi')
        .tlParams({'n': number}),
    BangumiSyncFailed(:var error) =>
      '${'Failed to sync with Bangumi'.tl}: $error',
    BangumiSyncSkipped() => null,
  };
  if (message == null) return;
  try {
    App.rootContext.showMessage(message: message);
  } catch (_) {
    // No app, e.g. in tests.
  }
}
