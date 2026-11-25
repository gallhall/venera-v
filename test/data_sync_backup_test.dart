import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/sync/sync_controller.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/translations.dart';

/// The 完整备份 on WebDAV: only the user restores it, and only automatic
/// backup uploads it on its own.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late int uploads;
  late int downloads;

  DataSync fake() => DataSync.forTest(
    upload: () async {
      uploads++;
      return const Res(true);
    },
    download: () async {
      downloads++;
      return const Res(true);
    },
  );

  setUpAll(() async {
    var dir = await Directory.systemTemp.createTemp('venera_backup');
    App.dataPath = dir.path;
    App.cachePath = '${dir.path}/cache';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => dir.path,
        );
    await appdata.init();
    await AppTranslation.init();
  });

  setUp(() {
    uploads = 0;
    downloads = 0;
    appdata.settings['webdav'] = ['https://dav.invalid/', 'user', 'pass'];
    appdata.implicitData['webdavAutoSync'] = false;
    appdata.settings['language'] = 'en-US';
    DataSync.instance = fake();
  });

  tearDownAll(() => DataSync.instance = null);

  test('saving settings uploads nothing with automatic backup off', () async {
    await appdata.saveData();
    expect(uploads, 0);
  });

  test('saving settings uploads with automatic backup on', () async {
    appdata.implicitData['webdavAutoSync'] = true;
    await appdata.saveData();
    expect(uploads, 1);
  });

  test('saveData(false) never uploads', () async {
    appdata.implicitData['webdavAutoSync'] = true;
    await appdata.saveData(false);
    expect(uploads, 0);
  });

  test('without an account nothing uploads, switch on or not', () async {
    appdata.settings['webdav'] = [];
    appdata.implicitData['webdavAutoSync'] = true;
    DataSync().onDataChanged();
    await appdata.saveData();
    expect(uploads, 0);
    expect(DataSync().isConfigured, isFalse);
    expect(DataSync().isEnabled, isFalse);
  });

  test('a data change uploads only with automatic backup on', () async {
    DataSync().onDataChanged();
    expect(uploads, 0);
    appdata.implicitData['webdavAutoSync'] = true;
    DataSync().onDataChanged();
    expect(uploads, 1);
  });

  test('an old non-bool switch value counts as off', () async {
    appdata.implicitData['webdavAutoSync'] = 'true';
    DataSync().onDataChanged();
    expect(uploads, 0);
  });

  test('starting up restores nothing, even with automatic backup on', () async {
    appdata.implicitData['webdavAutoSync'] = true;
    DataSync.instance = fake();
    await pumpEventQueue();
    expect(downloads, 0);
    expect(uploads, 0);
  });

  test('restoring is the user asking for it', () async {
    await DataSync().restore();
    expect(downloads, 1);
    expect(uploads, 0);
  });

  test('manual controls show for any account, automatic backup or not', () {
    expect(DataSync().isConfigured, isTrue);
    expect(DataSync().isEnabled, isFalse);
  });

  testWidgets(
    'WebDAV settings back up and confirm restore with auto backup off',
    (tester) async {
      final controller = SyncController.forTest();
      SyncController.instance = controller;
      addTearDown(() => SyncController.instance = null);
      await tester.pumpWidget(const MaterialApp(home: WebdavSettings()));
      await tester.pumpAndSettle();
      final upload = find.text('Upload Full Backup');
      final restore = find.widgetWithText(
        OutlinedButton,
        'Restore Full Backup',
      );
      expect(upload, findsOneWidget);
      expect(restore, findsOneWidget);

      await tester.ensureVisible(upload);
      await tester.tap(upload);
      await tester.pumpAndSettle();
      expect(uploads, 1);

      await tester.ensureVisible(restore);
      await tester.tap(restore);
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Replace the data on this device with the full backup on WebDAV?',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(downloads, 0);
      expect(uploads, 1);

      await tester.tap(restore);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(downloads, 1);
      expect(uploads, 1);
      expect(DataSync().isEnabled, isFalse);
      expect(controller.enabled, isTrue);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    },
  );
}
