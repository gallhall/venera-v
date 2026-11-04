import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dtorrent_task_v2/dtorrent_task_v2.dart';
import 'package:dtorrent_task_v2/src/piece/base_piece_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/torrent/torrent_downloader.dart';
import 'package:venera/foundation/torrent/torrent_metadata.dart';
import 'package:venera/utils/translations.dart';

import 'torrent_piece_selector_test.dart' show TestPeer, TestPieces;

TorrentModel batch() {
  // Shared pieces at both ends of episode 02, with one wholly skipped piece.
  var bytes = List.generate(512, (i) => i % 251);
  return TorrentModel(name: 'batch', files: [
    TorrentFileModel(path: 'batch/01.mkv', length: 100, offset: 0),
    TorrentFileModel(path: 'batch/02.mkv', length: 200, offset: 100),
    TorrentFileModel(path: 'batch/03.mkv', length: 212, offset: 300),
  ], infoHashBuffer: Uint8List(20), pieceLength: 128,
    pieces: [for (var i = 0; i < 512; i += 128)
      Uint8List.fromList(sha1.convert(bytes.sublist(i, i + 128)).bytes)],
    announces: [], nodes: [], version: TorrentVersion.v1);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);
  test('only two torrents acquire slots, released slots serve FIFO once', () async {
    var queue = TorrentDownloadQueue();
    var first = await queue.acquire();
    var second = await queue.acquire();
    var started = <int>[];
    var third = queue.acquire().then((release) { started.add(3); return release; });
    var fourth = queue.acquire().then((release) { started.add(4); return release; });
    await Future<void>.delayed(Duration.zero);
    expect(queue.active, 2);
    expect(queue.queued, 2);
    expect(started, isEmpty);
    first();
    first(); // A double release must not admit a third active torrent.
    var releaseThird = await third;
    expect(started, [3]);
    expect(queue.active, 2);
    second();
    var releaseFourth = await fourth;
    expect(started, [3, 4]);
    releaseThird();
    releaseFourth();
    expect(queue.active, 0);
  });

  test('cancelling a queued torrent does not consume or release a slot', () async {
    var queue = TorrentDownloadQueue(limit: 1);
    var first = await queue.acquire();
    var cancelled = Completer<void>();
    var queued = queue.acquire(cancelled: cancelled.future);
    var rejected = expectLater(queued, throwsStateError);
    cancelled.complete();
    await rejected;
    expect(queue.active, 1);
    expect(queue.queued, 0);
    first();
    expect(queue.active, 0);
  });

  test('batch magnets share a slot and wait for Wi-Fi without opening files', () async {
    await Directory('build').create(recursive: true);
    var root = await Directory('build').createTemp('bt-wifi-');
    addTearDown(() => root.delete(recursive: true));
    var downloader = TorrentDownloader(wifiOnly: () => true,
      isWifi: () async => false);
    const magnet = 'magnet:?xt=urn:btih:0123456789012345678901234567890123456789';
    var first = downloader.download(magnet, TorrentDownloadFile(
      path: '01.mkv', directory: Directory('${root.path}/01')));
    var second = downloader.download('$magnet&dn=batch', TorrentDownloadFile(
      path: '02.mkv', directory: Directory('${root.path}/02')));
    var firstResult = expectLater(first.done, throwsA(isA<TorrentDownloadException>()));
    var secondResult = expectLater(second.done, throwsA(isA<TorrentDownloadException>()));
    var waiting = Completer<void>();
    second.addListener(() {
      if (second.value.phase == TorrentDownloadPhase.waitingForWifi &&
          !waiting.isCompleted) {
        waiting.complete();
      }
    });
    await waiting.future.timeout(const Duration(seconds: 5));
    expect(downloader.queue.active, 1);
    expect(first.value.phase, TorrentDownloadPhase.waitingForWifi);
    first.retry();
    expect(downloader.queue.active, 1);
    expect(await root.list().toList(), isEmpty);
    await first.cancel();
    expect(downloader.queue.active, 1);
    await second.cancel();
    await Future.wait([firstResult, secondResult]);
    expect(downloader.queue.active, 0);
    first.dispose();
    second.dispose();
  });

  test('peer deadline hints at 30 seconds, clears on peers, fails at 30 minutes', () {
    var at = DateTime.utc(2026);
    var deadline = TorrentPeerDeadline(clock: () => at);
    deadline.observe(0);
    at = at.add(const Duration(seconds: 29));
    deadline.observe(0);
    expect(deadline.hint, isFalse);
    at = at.add(const Duration(seconds: 1));
    deadline.observe(0);
    expect(deadline.hint, isTrue);
    expect(deadline.expired, isFalse);
    deadline.observe(1);
    expect(deadline.hint, isFalse);
    at = at.add(const Duration(minutes: 29, seconds: 59));
    // A connected peer at the previous observation resets the consecutive span.
    deadline.observe(1);
    deadline.observe(0);
    at = at.add(const Duration(minutes: 29, seconds: 59));
    deadline.observe(0);
    expect(deadline.expired, isFalse);
    at = at.add(const Duration(seconds: 1));
    deadline.observe(0);
    expect(deadline.expired, isTrue);
  });

  test('queue/Wi-Fi waiting time does not advance a peer deadline', () {
    var at = DateTime.utc(2026);
    var deadline = TorrentPeerDeadline(clock: () => at);
    deadline.observe(0);
    at = at.add(const Duration(seconds: 29));
    deadline.observe(0);
    deadline.observe(0, waiting: true);
    at = at.add(const Duration(hours: 2));
    deadline.observe(0, waiting: true);
    deadline.observe(0);
    expect(deadline.hint, isFalse);
    at = at.add(const Duration(seconds: 1));
    deadline.observe(0);
    expect(deadline.hint, isTrue);
    expect(deadline.expired, isFalse);
  });

  test('path mapping is exact, supports separators and rejects missing episodes', () {
    var model = batch();
    var directory = Directory('unused');
    expect(selectedTorrentFile(model, TorrentDownloadFile(
      path: r'batch\02.mkv', directory: directory)), 1);
    expect(selectedTorrentFile(model, TorrentDownloadFile(
      episode: 2, directory: directory)), 1);
    for (var file in [
      TorrentDownloadFile(path: '02.mkv', directory: directory),
      TorrentDownloadFile(path: '../02.mkv', directory: directory),
      TorrentDownloadFile(episode: 9, directory: directory),
    ]) {
      expect(() => selectedTorrentFile(model, file), throwsA(
        isA<TorrentDownloadException>().having((e) => e.reason, 'reason',
          TorrentDownloadFailure.fileNotFound)));
    }
    expect(() => validateTorrentPaths(TorrentModel(name: 'batch', files: [
      TorrentFileModel(path: '../escape.mkv', length: 1, offset: 0),
    ], infoHashBuffer: Uint8List(20), pieceLength: 1, pieces: [Uint8List(20)],
      announces: [], nodes: [], version: TorrentVersion.v1)), throwsFormatException);
  });

  test('a missing batch episode cannot fall back to its only video', () {
    var model = batch();
    var singleFile = TorrentModel(name: model.name, files: [model.files.first],
      infoHashBuffer: model.infoHashBuffer, pieceLength: model.pieceLength,
      pieces: model.pieces, announces: [], nodes: [], version: TorrentVersion.v1);
    var directory = Directory('unused');
    expect(() => selectedTorrentFile(singleFile, TorrentDownloadFile(
      episode: 2, isBatch: true, directory: directory)), throwsA(
        isA<TorrentDownloadException>().having((e) => e.reason, 'reason',
          TorrentDownloadFailure.fileNotFound)));
    // The valid sibling remains selectable after the missing episode failed.
    expect(selectedTorrentFile(singleFile, TorrentDownloadFile(
      episode: 1, isBatch: true, directory: directory)), 0);
    expect(selectedTorrentFile(singleFile, TorrentDownloadFile(
      episode: 2, directory: directory)), 0);
  });

  test('rarest-first selection never selects skipped pieces or suggestions', () {
    var model = batch();
    var pieces = TestPieces(model);
    var peer = TestPeer(4);
    for (var piece in pieces.pieces.values) {
      piece.addAvailablePeer(peer);
    }
    // Piece 3 is even rarer, but belongs only to the skipped third file.
    pieces[0]!.addAvailablePeer(TestPeer(4));
    pieces[0]!.addAvailablePeer(TestPeer(4));
    pieces[1]!.addAvailablePeer(TestPeer(4));
    var selector = BasePieceSelector()..setSkippedPieces({3});
    expect(selector.selectPiece(peer, pieces, false, {3})?.index, 2);
    pieces.complete(2);
    expect(selector.selectPiece(peer, pieces)?.index, 1);
  });

  test('selected storage writes no unselected files and resumes verified data', () async {
    await Directory('build').create(recursive: true);
    var root = await Directory('build').createTemp('bt-selected-');
    addTearDown(() => root.delete(recursive: true));
    var model = batch();
    var directory = '${root.path}/episode/.bt-resume/${model.infoHash}';
    var target = '${root.path}/episode/video.mkv';
    var bytes = List.generate(512, (i) => i % 251);
    var storage = SelectedFileStorage(model, directory);
    await storage.addFiles({1: target});
    expect(storage.selectedPieces, {0, 1, 2});
    // Deliberately out of order, like a real swarm. Piece 1 is still absent.
    await storage.writePiece(2, bytes.sublist(256, 384));
    await storage.writePiece(0, bytes.sublist(0, 128));
    await storage.close();
    expect(await File('${root.path}/episode/batch/01.mkv').exists(), isFalse);
    expect(await File('${root.path}/episode/batch/03.mkv').exists(), isFalse);
    var videos = await root.list(recursive: true).where((f) =>
      f.path.endsWith('.mkv')).toList();
    expect(videos, hasLength(1));

    // A fresh storage and state file simulate restart, including loss of the
    // original state file. Actual piece hashes, not file length, drive recovery.
    var resumed = SelectedFileStorage(model, directory);
    await resumed.addFiles({1: target});
    var state = await StateFileV2.getStateFile(directory, model);
    await resumed.recover(state);
    expect(state.bitfield.completedPieces.toSet(), {0, 2});
    await resumed.writePiece(1, bytes.sublist(128, 256));
    await resumed.recover(state);
    expect(state.bitfield.completedPieces.toSet(), {0, 1, 2});
    expect(await File(target).readAsBytes(), bytes.sublist(100, 300));
    await state.close();

    // Corruption of an interior piece invalidates its saved bit on restart.
    var access = await File(target).open(mode: FileMode.writeOnlyAppend);
    await access.setPosition(50);
    await access.writeByte(255);
    await access.close();
    var restartedState = await StateFileV2.getStateFile(directory, model);
    await resumed.recover(restartedState);
    expect(restartedState.bitfield.completedPieces.toSet(), {0, 2});
    await restartedState.close();
    await resumed.close();
  });

  test('later batch selection materializes shared pieces in its own directory', () async {
    await Directory('build').create(recursive: true);
    var root = await Directory('build').createTemp('bt-batch-');
    addTearDown(() => root.delete(recursive: true));
    var model = batch();
    var bytes = List.generate(512, (i) => i % 251);
    var storage = SelectedFileStorage(model, '${root.path}/state');
    await storage.addFiles({1: '${root.path}/02/video.mkv'});
    await storage.writePiece(0, bytes.sublist(0, 128));
    await storage.addFiles({0: '${root.path}/01/video.mkv'});
    expect(await File('${root.path}/01/video.mkv').readAsBytes(), bytes.sublist(0, 100));
    await storage.close();
  });

  test('file manager uses selective storage for boundary writes and reads', () async {
    await Directory('build').create(recursive: true);
    var root = await Directory('build').createTemp('bt-manager-');
    var model = batch();
    var storage = SelectedFileStorage(model, '${root.path}/state');
    var target = '${root.path}/02/video.mkv';
    await storage.addFiles({1: target});
    var state = await StateFileV2.getStateFile(storage.directory, model);
    await storage.recover(state);
    var pieces = List.generate(4, (i) => Piece('', i, 128, i * 128));
    var manager = await DownloadFileManager.createFileManager(
      model, storage.directory, state, pieces, selectedStorage: storage);
    addTearDown(() async {
      await manager.close();
      await root.delete(recursive: true);
    });
    var bytes = List.generate(128, (i) => i);
    expect(await manager.writeFile(0, 0, bytes), isTrue);
    await manager.updateBitfield(0);
    await manager.flushFiles({0});
    expect(await manager.readFile(0, 0, 128), bytes);
    expect(await File(target).readAsBytes(), bytes.sublist(100));
    expect(await Directory('${storage.directory}/batch').exists(), isFalse);
    expect(manager.localHave(0), isTrue);
  });
}
