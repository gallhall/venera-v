import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/favorite_tables.dart';
import 'package:venera/foundation/sync/engine/restore_points.dart';
import 'package:venera/foundation/sync/engine/sync_engine.dart';
import 'package:venera/foundation/sync/local/favorites_hooks.dart';
import 'package:venera/foundation/sync/local/source_keys.dart';
import 'package:venera/foundation/sync/local/sync_hooks.dart';
import 'package:venera/foundation/sync/remote/dav.dart';
import 'package:venera/foundation/sync/remote/remote_store.dart';
import 'package:venera/foundation/sync/sync_store.dart';

import 'support/memory_dav.dart';

const _source = 'simulation-source';
final _type = localType(_source);
const _epoch = 1789000000000;
const _seedFile = 'test/sync/regression_seeds.txt';

enum _Kind { history, later, favorite, sync, restart, crash }

enum _Fault {
  scanTransaction('issue:commit'),
  scanCommitted('scan:after'),
  planTransaction('plan:before-commit'),
  planCommitted('plan:after-commit'),
  businessTransaction('apply:before-commit'),
  businessCommitted('apply:after-commit'),
  beforeMark('apply:before-mark'),
  afterMark('apply:after-mark'),
  betweenDatabases('apply:between-dbs'),
  beforeStatePut(),
  afterStatePut(),
  beforeManifestPut(),
  afterManifestPut(),
  publishCommitted('publish:after');

  const _Fault([this.point]);
  final String? point;
}

class _Crash implements Exception {
  const _Crash(this.fault);
  final _Fault fault;
}

class _Step {
  const _Step(this.kind, this.device, [this.slot = 0, this.value = 0]);

  final _Kind kind;
  final int device;
  final int slot;
  // Zero is an explicit delete on an edit step.
  final int value;

  List<Object> toJson() => [kind.name, device, slot, value];

  static _Step fromJson(List<Object?> row) => _Step(
    _Kind.values.byName(row[0] as String),
    row[1] as int,
    row[2] as int,
    row[3] as int,
  );

  String get id => slot == -1 ? 'shared' : '$device-$slot';
}

class _Scenario {
  const _Scenario(this.seed, this.deviceCount, this.fault, this.steps);

  final int seed;
  final int deviceCount;
  final _Fault fault;
  final List<_Step> steps;

  factory _Scenario.generate(int seed) {
    final random = Random(seed);
    final count = 3 + random.nextInt(3);
    final order = List.generate(count, (i) => i)..shuffle(random);
    final receiver = order.first;
    final sender = order.last;
    final steps = <_Step>[];
    for (final d in order) {
      steps.addAll([
        _Step(_Kind.history, d, 0, 1),
        _Step(_Kind.later, d, 0, 2),
        _Step(_Kind.favorite, d, 0, 3),
        _Step(_Kind.sync, d),
      ]);
    }
    final edits = [
      for (var i = 0; i < 12; i++)
        _Step(
          _Kind.values[random.nextInt(5)],
          random.nextInt(count),
          random.nextInt(3),
          random.nextInt(9),
        ),
    ];
    final crashAt = random.nextInt(edits.length + 1);
    steps.addAll(edits.take(crashAt));
    // Two clients edit the same item before either receives the other edit.
    steps.addAll([
      _Step(_Kind.later, receiver, -1, 11),
      _Step(_Kind.later, sender, -1, 12),
      _Step(_Kind.history, sender, 90, 7),
      _Step(_Kind.favorite, sender, 90, 8),
      _Step(_Kind.sync, sender),
      _Step(_Kind.history, receiver, 91, 9),
      _Step(_Kind.crash, receiver),
    ]);

    steps.addAll(edits.skip(crashAt));

    // Each valid write reaches the server in the first pass. The second
    // pass gives peers the same state and the third checks idempotence.
    final settle = List.of(order)..shuffle(random);
    for (var pass = 0; pass < 2; pass++) {
      steps.addAll(settle.map((d) => _Step(_Kind.sync, d)));
    }
    final faults = _Fault.values.toList()
      ..shuffle(Random(seed ~/ _Fault.values.length));
    return _Scenario(seed, count, faults[seed % faults.length], steps);
  }

  Map<String, Object?> toJson() => {
    'seed': seed,
    'devices': deviceCount,
    'fault': fault.name,
    'steps': steps.map((step) => step.toJson()).toList(),
  };

  static _Scenario fromJson(Map<String, Object?> json) => _Scenario(
    json['seed'] as int,
    json['devices'] as int,
    _Fault.values.byName(json['fault'] as String),
    (json['steps'] as List)
        .map((row) => _Step.fromJson((row as List).cast<Object?>()))
        .toList(),
  );
}

class _Device extends LocalSide {
  _Device(this.index, this.dir, this.dav, this.now) {
    open();
    historyDb.execute('''
      CREATE TABLE history (
        id TEXT PRIMARY KEY, title TEXT, subtitle TEXT, cover TEXT, time INT,
        type INT, ep INT, page INT, readEpisode TEXT, max_page INT,
        chapter_group INT
      );
      CREATE TABLE "__watch_later" (
        id TEXT, type INT, title TEXT, subtitle TEXT, cover TEXT, time INT,
        PRIMARY KEY(id, type)
      );
    ''');
    favoritesDb.execute('''
      CREATE TABLE folder_order (folder_name TEXT PRIMARY KEY, order_value INT);
      CREATE TABLE folder_sync (
        folder_name TEXT PRIMARY KEY, source_key TEXT, source_folder TEXT
      );
    ''');
    createFavoriteTable(favoritesDb, folder);
  }

  final int index;
  final Directory dir;
  final MemoryDav dav;
  final int Function() now;
  late SyncStore store;
  @override
  late Database historyDb;
  @override
  late Database favoritesDb;
  int _remoteNonce = 0;
  String get folder => 'Favorites $index';
  String get _storePath => '${dir.path}/$syncDbName';

  @override
  Map<String, String> get databasePaths => {
    'history': '${dir.path}/history.db',
    'favorites': '${dir.path}/local_favorite.db',
  };

  @override
  bool get ready => true;

  @override
  List<String> installedKeys() => const [_source];

  @override
  void reload() {}

  void open() {
    store =
        SyncStore.openIfExists(_storePath, now: now, durable: false) ??
        _createStore();
    historyDb = sqlite3.open(databasePaths['history']!);
    favoritesDb = sqlite3.open(databasePaths['favorites']!);
  }

  SyncStore _createStore() {
    // Deterministic fixture identities make the protocol and HLC tie
    // breaks comparable between the control and crash runs.
    SyncStore.create(_storePath, now: now, durable: false).dispose();
    final db = sqlite3.open(_storePath);
    try {
      final id = '00000000-0000-4000-8000-${index.toString().padLeft(12, '0')}';
      db.execute('UPDATE identity SET device_id = ?, instance_id = ?', [
        id,
        id,
      ]);
    } finally {
      db.dispose();
    }
    return SyncStore.openIfExists(_storePath, now: now, durable: false)!;
  }

  void reopen() {
    close();
    open();
  }

  void close() {
    store.dispose();
    historyDb.dispose();
    favoritesDb.dispose();
  }

  void edit(_Step step) {
    final id = step.id;
    final value = step.value;
    final time = now();
    SyncHooks.store = store.meta(SyncMeta.joined) == null ? null : store;
    SyncHooks.installedKeys = installedKeys;
    try {
      switch (step.kind) {
        case _Kind.history:
          if (value == 0) {
            historyDb.execute('DELETE FROM history WHERE id = ?', [id]);
            if (historyDb.updatedRows > 0) {
              SyncHooks.historyDeleted([(id, _type)]);
            }
          } else {
            historyDb.execute(
              'INSERT OR REPLACE INTO history VALUES (?,?,?,?,?,?,?,?,?,?,?)',
              [
                id,
                'History $id',
                '',
                'cover',
                time,
                _type,
                value,
                1,
                '$value',
                20,
                null,
              ],
            );
          }
        case _Kind.later:
          if (value == 0) {
            historyDb.execute('DELETE FROM "__watch_later" WHERE id = ?', [id]);
            if (historyDb.updatedRows > 0) {
              SyncHooks.watchLaterRemoved([(id, _type)]);
            }
          } else {
            final title = '$value';
            historyDb.execute(
              'INSERT OR REPLACE INTO "__watch_later" VALUES (?,?,?,?,?,?)',
              [id, _type, title, '', 'cover', time],
            );
            SyncHooks.watchLaterWritten([
              (
                id: id,
                type: _type,
                title: title,
                subtitle: '',
                cover: 'cover',
                time: time,
              ),
            ]);
          }
        case _Kind.favorite:
          final table = favoriteTable(folder);
          if (value == 0) {
            favoritesDb.execute('DELETE FROM $table WHERE id = ?', [id]);
            if (favoritesDb.updatedRows > 0) {
              FavoritesHooks.itemsRemoved(favoritesDb, {
                folder: [(id, _type)],
              });
            }
          } else {
            final old = favoritesDb.select(
              'SELECT time FROM $table WHERE id = ?',
              [id],
            ).firstOrNull;
            favoritesDb.execute(
              'INSERT OR REPLACE INTO $table VALUES (?,?,?,?,?,?,?,?,?)',
              [
                id,
                '$value',
                'Author',
                _type,
                'tag',
                'cover',
                old?['time'] ??
                    DateTime.fromMillisecondsSinceEpoch(
                      time,
                      isUtc: true,
                    ).toIso8601String(),
                0,
                '',
              ],
            );
            FavoritesHooks.itemsWritten(favoritesDb, folder, [
              (id, _type),
            ], inserted: old == null);
          }
        case _Kind.sync || _Kind.restart || _Kind.crash:
          throw StateError('expected a business edit');
      }
    } finally {
      SyncHooks.reset();
    }
  }

  SyncEngine engine({void Function(String)? fault}) => SyncEngine(
    store: store,
    local: this,
    inIsolate: false,
    fault: fault,
    restorePoints: RestorePoints(
      store,
      dir: '${dir.path}/restore',
      inIsolate: false,
      databases: {
        'history.db': databasePaths['history']!,
        'local_favorite.db': databasePaths['favorites']!,
      },
    ),
    remote: (cancel) => RemoteStore(
      DavClient(
        dav,
        dav.root,
        isCancelled: cancel.check,
        sleep: (_) async {},
        now: () => DateTime.fromMillisecondsSinceEpoch(now(), isUtc: true),
      ),
      now: () => DateTime.fromMillisecondsSinceEpoch(now(), isUtc: true),
      random: () =>
          '$index${(_remoteNonce++).toRadixString(36).padLeft(7, '0')}',
    ),
  );

  Map<String, int> projection() => {
    for (final row in historyDb.select('SELECT id, ep FROM history'))
      'history/${row['id']}': row['ep'] as int,
    for (final row in historyDb.select('SELECT id, title FROM "__watch_later"'))
      'later/${row['id']}': int.parse(row['title'] as String),
    for (final name in favoriteTableNames(favoritesDb))
      for (final row in favoritesDb.select(
        'SELECT id, name FROM ${favoriteTable(name)}',
      ))
        'favorite/$name/${row['id']}': int.parse(row['name'] as String),
  };
}

class _Run {
  _Run(this.scenario, {required this.inject, required this.log});

  final _Scenario scenario;
  final bool inject;
  final List<String> log;
  final _dav = MemoryDav();
  final _devices = <_Device>[];
  final _expected = <String, int>{};
  int _now = _epoch;

  Future<Map<String, int>> play() async {
    final root = Directory.systemTemp.createTempSync('sync-e2e-');
    try {
      for (var i = 0; i < scenario.deviceCount; i++) {
        _devices.add(
          _Device(
            i,
            Directory('${root.path}/$i')..createSync(),
            _dav,
            () => _now,
          ),
        );
      }
      for (final step in scenario.steps) {
        _now += 1000;
        final device = _devices[step.device];
        log.add('${inject ? 'crash' : 'control'} ${step.toJson()}');
        switch (step.kind) {
          case _Kind.sync:
            await _sync(device);
          case _Kind.restart:
            device.reopen();
          case _Kind.crash:
            if (inject) await _inject(device, scenario.fault);
            await _sync(device);
          case _Kind.history || _Kind.later || _Kind.favorite:
            device.edit(step);
            final entity = step.kind == _Kind.favorite
                ? 'favorite/${device.folder}/${step.id}'
                : '${step.kind.name}/${step.id}';
            if (step.value == 0) {
              _expected.remove(entity);
            } else {
              _expected[entity] = step.value;
            }
        }
      }
      final state = _devices.first.store.load().canonical;
      for (final device in _devices) {
        expect(
          device.store.load().canonical,
          state,
          reason: 'protocol convergence on device ${device.index}',
        );
        expect(
          device.projection(),
          _expected,
          reason: 'authored edits and deletes on device ${device.index}',
        );
        log.add(
          '${inject ? 'crash' : 'control'} idempotence sync ${device.index}',
        );
        final report = await _sync(device);
        expect(
          report.applied,
          0,
          reason: 'no repeated writes on device ${device.index}',
        );
        expect(device.store.load().canonical, state);
        expect(device.store.openPlan(), isNull);
      }
      return _devices.first.projection();
    } finally {
      for (final device in _devices) {
        device.close();
      }
      root.deleteSync(recursive: true);
    }
  }

  Future<SyncReport> _sync(_Device device) async {
    final report = await device.engine().run(SyncTrigger.manual);
    expect(
      report.outcome,
      SyncOutcome.done,
      reason: 'device ${device.index} $report',
    );
    return report;
  }

  Future<void> _inject(_Device device, _Fault fault) async {
    var reached = false;
    void crash() {
      reached = true;
      log.add('device ${device.index} hit ${fault.name}');
      throw _Crash(fault);
    }

    final engine = device.engine(
      fault: (point) {
        if (point == fault.point) crash();
      },
    );
    if (fault == _Fault.scanTransaction) {
      device.store.faultHook = (point) {
        if (engine.stage.value == SyncStage.scan && point == fault.point) {
          crash();
        }
      };
    }

    String? statePath;
    String? manifestPath;
    _dav.intercept = (_, method, path, _, _) {
      if (engine.stage.value != SyncStage.publish) return null;
      if (method == 'PUT' && path.contains('/state-')) {
        if (fault == _Fault.beforeStatePut) crash();
        statePath = path;
      } else if (method == 'PROPFIND' && path == statePath) {
        if (fault == _Fault.afterStatePut) crash();
      } else if (method == 'PUT' && path.contains('/manifest-')) {
        if (fault == _Fault.beforeManifestPut) crash();
        manifestPath = path;
      } else if (method == 'GET' && path == manifestPath) {
        if (fault == _Fault.afterManifestPut) crash();
      }
      return null;
    };
    try {
      await expectLater(engine.run(SyncTrigger.manual), throwsA(isA<_Crash>()));
      expect(reached, isTrue, reason: 'fault checkpoint ${fault.name}');
    } finally {
      _dav.intercept = null;
      device.store.faultHook = null;
    }
    device.reopen();
  }
}

Future<void> _check(_Scenario scenario) async {
  final log = <String>[];
  try {
    final control = await _Run(scenario, inject: false, log: log).play();
    final restarted = await _Run(scenario, inject: true, log: log).play();
    expect(restarted, control, reason: 'crash run matches the control');
  } catch (error, stack) {
    final dir = Directory('build/sync-simulation-failures')
      ..createSync(recursive: true);
    final trace = File('${dir.path}/seed-${scenario.seed}.json');
    trace.writeAsStringSync(
      const JsonEncoder.withIndent(
        '  ',
      ).convert({...scenario.toJson(), 'executed': log, 'error': '$error'}),
    );
    final seeds = File(_seedFile);
    final line = 'e2e:${scenario.seed}';
    if (!seeds.readAsLinesSync().contains(line)) {
      seeds.writeAsStringSync('$line\n', mode: FileMode.append);
    }
    print(
      'Reproduce with SYNC_E2E_SEED=${scenario.seed} or SYNC_E2E_TRACE=${trace.path}',
    );
    print(jsonEncode(scenario.toJson()));
    print(log.join('\n'));
    Error.throwWithStackTrace(error, stack);
  }
}

void main() {
  final env = Platform.environment;
  final seed = env['SYNC_E2E_SEED'];
  final tracePath = env['SYNC_E2E_TRACE'];
  final regression = File(_seedFile)
      .readAsLinesSync()
      .map((line) => line.trim())
      .where((line) => line.startsWith('e2e:'))
      .map((line) => int.parse(line.substring(4)))
      .toSet();
  final count = int.parse(env['SYNC_E2E_COUNT'] ?? '500');
  final scenarios = tracePath != null
      ? [
          _Scenario.fromJson(
            (jsonDecode(File(tracePath).readAsStringSync()) as Map)
                .cast<String, Object?>(),
          ),
        ]
      : seed != null
      ? [_Scenario.generate(int.parse(seed))]
      : [
          for (final n in {...regression, for (var i = 0; i < count; i++) i})
            _Scenario.generate(n),
        ];
  test(
    '${scenarios.length} SQLite and WebDAV crash scenarios',
    () async {
      // Fail CI if SQLite is unavailable. A skipped suite would not
      // establish the required number of end-to-end seeds.
      sqlite3.version;
      for (var i = 0; i < scenarios.length; i++) {
        final scenario = scenarios[i];
        final replay = i == 0
            ? _Scenario.fromJson(
                (jsonDecode(jsonEncode(scenario.toJson())) as Map)
                    .cast<String, Object?>(),
              )
            : scenario;
        expect(replay.toJson(), scenario.toJson());
        await _check(replay);
        if ((i + 1) % 100 == 0) print('Verified ${i + 1} crash scenarios');
      }
      print('Verified ${scenarios.length} seeds against a no-crash control');
    },
    timeout: const Timeout(Duration(minutes: 22)),
  );
}
