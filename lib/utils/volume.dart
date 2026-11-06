import 'dart:async';

import 'package:venera/foundation/platform/platform_capabilities.dart';

class VolumeListener {
  void Function()? onUp;

  void Function()? onDown;

  VolumeListener({this.onUp, this.onDown});

  StreamSubscription? stream;

  void listen() {
    stream = PlatformCapabilities.instance.volumeKeys.events.listen(onEvent);
  }

  void onEvent(event) {
    if (event == 1) {
      onUp!();
    } else if (event == 2) {
      onDown!();
    }
  }

  void cancel() {
    stream?.cancel();
  }
}