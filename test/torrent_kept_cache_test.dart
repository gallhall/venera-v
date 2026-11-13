import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dtorrent_task_v2/dtorrent_task_v2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/torrent/torrent_streamer.dart';

const _pieceLength = 256 * 1024;

/// A torrent of one file of [pieces] pieces under [root], and its bytes.
Future<(TorrentModel, List<int>, String)> _torrent(
    Directory root, int pieces) async {
  var sep = Platform.pathSeparator;
  var seedPath = '${root.path}${sep}seed';
  var batch = await Directory('$seedPath${sep}show').create(recursive: true);
  var random = Random(7);
  var bytes = List.generate(pieces * _pieceLength, (_) => random.nextInt(256));
  await File('${batch.path}${sep}01.mkv').writeAsBytes(bytes);
  var model = await TorrentCreator.createTorrent(
      batch.path, TorrentCreationOptions(pieceLength: _pieceLength));
  return (model, bytes, seedPath);
}

Future<Directory> _root() async {
  await Directory('build').create(recursive: true);
  var root = await Directory('build').createTemp('torrent-kept-');
  addTearDown(() => root.delete(recursive: true));
  return root;
}

void main() {
  test('keeping torrent data is turned on once, and respected afterwards', () {
    var data = <String, dynamic>{};
    var settings = <String, Object>{'btKeepFiles': false};
    void set(String key, Object value) => settings[key] = value;
    expect(migrateKeptTorrents(data, set), isTrue);
    expect(settings['btKeepFiles'], isTrue);
    settings['btKeepFiles'] = false;
    expect(migrateKeptTorrents(data, set), isFalse);
    expect(settings['btKeepFiles'], isFalse);
  });

  test('kept data is gone on from only when its state and file agree',
      () async {
    var root = await _root();
    var (model, _, _) = await _torrent(root, 2);
    var file = model.files.first;
    var kept = await Directory('${root.path}/kept').create();
    // Nothing fetched yet.
    expect(await DartTorrentStreamer.keptUsable(kept, model, file), isTrue);
    // Files nothing says anything about.
    var data = File('${kept.path}/${file.path}');
    await data.create(recursive: true);
    await data.writeAsBytes(List.filled(file.length, 0));
    expect(await DartTorrentStreamer.keptUsable(kept, model, file), isFalse);
    // The state and the whole file.
    var state = File('${kept.path}/${model.infoHash}.bt.state');
    await state.writeAsBytes([1]);
    expect(await DartTorrentStreamer.keptUsable(kept, model, file), isTrue);
    // A file cut short.
    await data.writeAsBytes(List.filled(file.length - 1, 0));
    expect(await DartTorrentStreamer.keptUsable(kept, model, file), isFalse);
    // The state before the first write.
    await data.delete();
    expect(await DartTorrentStreamer.keptUsable(kept, model, file), isTrue);
  });

  test('episodes of a batch watched before count for the one that uses '
      'their directory', () async {
    var root = await _root();
    var sep = Platform.pathSeparator;
    var batch = await Directory('${root.path}${sep}seed${sep}batch')
        .create(recursive: true);
    for (var name in ['01.mkv', '02.mkv', '03.mkv']) {
      await File('${batch.path}$sep$name')
          .writeAsBytes(List.filled(4 * _pieceLength, 1));
    }
    var model = await TorrentCreator.createTorrent(
        batch.path, TorrentCreationOptions(pieceLength: _pieceLength));
    var second = model.files.firstWhere((f) => f.name == '02.mkv');
    var kept = await Directory('${root.path}/kept').create();
    expect(await DartTorrentStreamer.keptBeyond(kept, model, second), 0);
    // The first episode was watched before; the second is what is played.
    for (var f in model.files.where((f) => f.name != '03.mkv')) {
      var file = File('${kept.path}/${f.path}');
      await file.create(recursive: true);
      await file.writeAsBytes(List.filled(f.length, 0));
    }
    expect(await DartTorrentStreamer.keptBeyond(kept, model, second,
        sparse: true), 4 * _pieceLength);
    // The files are whole pieces here, so the first is no neighbour of the
    // second and counts the same where neighbours are reserved whole.
    expect(await DartTorrentStreamer.keptBeyond(kept, model, second,
        sparse: false), 4 * _pieceLength);
  });

  test('an episode of a batch fits a limit its neighbours would not', () {
    const mb = 1024 * 1024;
    var lengths = [411 * mb + 7, 622 * mb + 5, 519 * mb + 3];
    var offset = 0;
    var files = <TorrentFileModel>[];
    for (var length in lengths) {
      files.add(TorrentFileModel(path: 'batch/0${files.length + 1}.mp4',
          length: length, offset: offset));
      offset += length;
    }
    var model = TorrentModel(name: 'batch', files: files,
        infoHashBuffer: Uint8List(20), pieceLength: 4 * mb,
        pieces: List.generate((offset / (4 * mb)).ceil(), (_) => Uint8List(20)),
        announces: [], nodes: [], version: TorrentVersion.v1);
    // The middle one shares a piece with each of the others.
    expect(DartTorrentStreamer.writtenFiles(model, files[1]).length, 3);
    expect(DartTorrentStreamer.reservedBytes(model, files[1], sparse: true),
        lessThan(1024 * mb));
    expect(DartTorrentStreamer.reservedBytes(model, files[1], sparse: true),
        lessThanOrEqualTo(lengths[1] + 2 * 4 * mb + 16 * mb));
    expect(DartTorrentStreamer.reservedBytes(model, files[1], sparse: false),
        greaterThan(1024 * mb));
  });

  test('a torrent opened again in its directory needs no peer for what it has',
      () async {
    InternetAddress? local;
    for (var interface in await NetworkInterface.list(
        type: InternetAddressType.IPv4)) {
      for (var address in interface.addresses) {
        if (!address.isLoopback && !address.isLinkLocal) {
          local ??= address;
        }
      }
    }
    if (local == null) {
      markTestSkipped('No IPv4 address besides loopback');
      return;
    }
    var root = await _root();
    var (model, bytes, seedPath) = await _torrent(root, 16);
    var file = model.files.first;
    var tasks = <TorrentTask>[];
    addTearDown(() async {
      for (var task in tasks) {
        await task.stop();
      }
    });
    var seedState = await StateFileV2.getStateFile(seedPath, model);
    for (var i = 0; i < model.pieces!.length; i++) {
      await seedState.updateBitfield(i);
    }
    await seedState.close();
    var seeder = TorrentTask.newTask(model, seedPath);
    tasks.add(seeder);
    var port = (await seeder.start())['tcp_socket'] as int;

    var kept = '${root.path}${Platform.pathSeparator}kept';
    TorrentTask open() {
      var task = TorrentTask.newTask(model, kept, true, null, null,
          const SequentialConfig(lookAheadSize: 8, autoDetectMoovAtom: false));
      task.setFilePriority(0, FilePriority.high);
      task.setStreamFile(0);
      return task;
    }

    var first = open();
    tasks.add(first);
    await first.start();
    first.addPeer(CompactAddress(local, port),
        PeerSource.manual, type: PeerType.tcp);
    var read = await first.createStream(
            filePosition: 0, endPosition: file.length, fileName: file.path)!
        .fold<List<int>>([], (a, b) => a..addAll(b))
        .timeout(const Duration(seconds: 60));
    expect(read, bytes);
    await first.stop();
    tasks.remove(first);
    await seeder.stop();
    tasks.remove(seeder);

    expect(await DartTorrentStreamer.keptUsable(
        Directory(kept), model, file), isTrue);
    // No peer at all this time.
    var second = open();
    tasks.add(second);
    await second.start();
    var again = await second.createStream(
            filePosition: 0, endPosition: file.length, fileName: file.path)!
        .fold<List<int>>([], (a, b) => a..addAll(b))
        .timeout(const Duration(seconds: 20));
    expect(again, bytes);
  }, timeout: const Timeout(Duration(seconds: 120)));
}
