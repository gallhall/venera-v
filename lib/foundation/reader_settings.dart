/// Where a 阅读器设置 is stored.
enum ReaderSettingLayer {
  /// This comic only, while its own settings are enabled.
  comic,

  /// This device only, while device settings are enabled.
  device,

  /// Every comic on every synced device.
  global,
}

/// The 阅读器设置 of one comic: each setting in [overridable] is taken from
/// the comic's own settings, then this device's, then the global ones, the
/// first layer that is enabled and has it.
///
/// Readers ask the typed getters; the settings page reads and writes one
/// [ReaderSettingLayer] at a time. Settings outside [overridable] are global
/// only and are not read here.
class ReaderSettings {
  /// The settings a comic or a device may override.
  static const overridable = {
    'autoPageTurningInterval',
    'enableClockAndBatteryInfoInReader',
    'enableCustomImageProcessing',
    'enableDoubleTapToZoom',
    'enableLongPressToZoom',
    'enablePageAnimation',
    'enableTapToTurnPages',
    'enableTurnPageByVolumeKey',
    'limitImageWidth',
    'longPressZoomPosition',
    'preloadImageCount',
    'quickCollectImage',
    'readerMode',
    'readerScreenPicNumberForLandscape',
    'readerScreenPicNumberForPortrait',
    'readerScrollSpeed',
    'reverseTapToTurnPages',
    'seamlessChapters',
    'showChapterComments',
    'showChapterCommentsAtEnd',
    'showPageNumberInReader',
    'showSingleImageOnFirstPage',
    'showSystemStatusBar',
  };

  final Map<String, dynamic> _data;
  final String? comicId;
  final String? sourceKey;
  final String Function() _deviceId;
  final void Function() _changed;

  /// The settings of comic [comicId] of [sourceKey] (none for the settings
  /// of no comic) in the app settings [data]. [deviceId] gives this
  /// device's id, creating it if needed; [changed] is called after writes.
  ReaderSettings(this._data, {
    this.comicId,
    this.sourceKey,
    required String Function() deviceId,
    void Function()? changed,
  }) : _deviceId = deviceId, _changed = changed ?? _nothing;

  static void _nothing() {}

  String? get _comicKey =>
      comicId == null || sourceKey == null ? null : '$comicId@$sourceKey';

  Map? get _comic {
    var key = _comicKey;
    var all = _data['comicSpecificSettings'];
    return key != null && all is Map ? all[key] as Map? : null;
  }

  Map? get _device {
    var id = _data['deviceId'];
    var all = _data['deviceSpecificSettings'];
    return id is String && id.isNotEmpty && all is Map ? all[id] as Map? : null;
  }

  /// Whether this comic's own settings are used.
  bool get comicEnabled => _comic?['enabled'] == true;

  set comicEnabled(bool value) => set(ReaderSettingLayer.comic, 'enabled', value);

  /// Whether this device's settings are used.
  bool get deviceEnabled => _device?['enabled'] == true;

  set deviceEnabled(bool value) =>
      set(ReaderSettingLayer.device, 'enabled', value);

  /// The layer the settings page edits: the most specific enabled one.
  ReaderSettingLayer get editing => comicEnabled ? ReaderSettingLayer.comic
      : deviceEnabled ? ReaderSettingLayer.device : ReaderSettingLayer.global;

  /// Setting [key] as it applies to this comic.
  dynamic operator [](String key) => valueAt(ReaderSettingLayer.comic, key);

  /// Setting [key] as seen from [layer]: that layer's value if it is
  /// enabled and has one, else the next layer's.
  dynamic valueAt(ReaderSettingLayer layer, String key) {
    assert(overridable.contains(key), '$key is not a reader setting');
    if (layer == ReaderSettingLayer.comic && comicEnabled) {
      var value = _comic?[key];
      if (value != null) return value;
    }
    if (layer != ReaderSettingLayer.global && deviceEnabled) {
      var value = _device?[key];
      if (value != null) return value;
    }
    return _data[key];
  }

  /// Stores [value] for [key] in [layer].
  void set(ReaderSettingLayer layer, String key, dynamic value) {
    assert(key == 'enabled' || overridable.contains(key),
        '$key is not a reader setting');
    switch (layer) {
      case ReaderSettingLayer.comic:
        var comicKey = _comicKey;
        if (comicKey == null) {
          throw StateError('No comic to store $key for');
        }
        (_data['comicSpecificSettings'] as Map<String, dynamic>)
            .putIfAbsent(comicKey, () => <String, dynamic>{})[key] = value;
      case ReaderSettingLayer.device:
        (_data['deviceSpecificSettings'] as Map<String, dynamic>)
            .putIfAbsent(_deviceId(), () => <String, dynamic>{})[key] = value;
      case ReaderSettingLayer.global:
        _data[key] = value;
    }
    _changed();
  }

  /// Forgets [layer]'s values, which also turns it off. The global
  /// settings are never reset here.
  void reset(ReaderSettingLayer layer) {
    switch (layer) {
      case ReaderSettingLayer.comic:
        (_data['comicSpecificSettings'] as Map).remove(_comicKey);
      case ReaderSettingLayer.device:
        var id = _data['deviceId'];
        if (id is String && id.isNotEmpty) {
          (_data['deviceSpecificSettings'] as Map).remove(id);
        }
      case ReaderSettingLayer.global:
        return;
    }
    _changed();
  }

  int get autoPageTurningInterval => this['autoPageTurningInterval'];
  bool get enableClockAndBatteryInfoInReader =>
      this['enableClockAndBatteryInfoInReader'];
  bool get enableCustomImageProcessing => this['enableCustomImageProcessing'];
  bool get enableDoubleTapToZoom => this['enableDoubleTapToZoom'];
  bool get enableLongPressToZoom => this['enableLongPressToZoom'];
  bool get enablePageAnimation => this['enablePageAnimation'];
  bool get enableTapToTurnPages => this['enableTapToTurnPages'];
  bool get enableTurnPageByVolumeKey => this['enableTurnPageByVolumeKey'];
  bool get limitImageWidth => this['limitImageWidth'];

  /// `press` or `center`.
  String get longPressZoomPosition => this['longPressZoomPosition'];
  int get preloadImageCount => this['preloadImageCount'];

  /// `No`, `DoubleTap` or `Swipe`.
  String get quickCollectImage => this['quickCollectImage'];

  /// A key of `ReaderMode`.
  String get readerMode => this['readerMode'];
  int get readerScreenPicNumberForLandscape =>
      this['readerScreenPicNumberForLandscape'];
  int get readerScreenPicNumberForPortrait =>
      this['readerScreenPicNumberForPortrait'];
  double get readerScrollSpeed => (this['readerScrollSpeed'] as num).toDouble();
  bool get reverseTapToTurnPages => this['reverseTapToTurnPages'];
  bool get seamlessChapters => this['seamlessChapters'];
  bool get showChapterComments => this['showChapterComments'];
  bool get showChapterCommentsAtEnd => this['showChapterCommentsAtEnd'];
  bool get showPageNumberInReader => this['showPageNumberInReader'];
  bool get showSingleImageOnFirstPage => this['showSingleImageOnFirstPage'];
  bool get showSystemStatusBar => this['showSystemStatusBar'];
}
