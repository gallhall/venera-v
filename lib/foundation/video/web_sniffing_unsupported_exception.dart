import 'package:venera/utils/translations.dart';
import '../platform/platform_capabilities.dart';

class WebSniffingUnsupportedException implements Exception {
  const WebSniffingUnsupportedException();

  static const messageKey =
      'Web page sniffing is not supported on Linux; this source is unavailable';

  String get message => messageKey.tl;

  /// JS promise rejections may append a JS stack to the original message.
  static String describe(Object error) {
    var text = error.toString();
    if (!PlatformCapabilities.instance.webSniffing.isSupported) {
      var unsupported = const WebSniffingUnsupportedException();
      if (error is WebSniffingUnsupportedException ||
          text.contains(unsupported.message) || text.contains(messageKey)) {
        return unsupported.message;
      }
    }
    return text;
  }

  @override
  String toString() => message;
}
