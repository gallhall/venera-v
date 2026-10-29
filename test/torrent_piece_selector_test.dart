import 'dart:typed_data';

import 'package:dtorrent_task_v2/dtorrent_task_v2.dart';
import 'package:flutter_test/flutter_test.dart';

const mb = 1024 * 1024;

TorrentModel torrent(List<int> lengths, int pieceLength) {
  var offset = 0;
  var files = <TorrentFileModel>[];
  for (var length in lengths) {
    files.add(TorrentFileModel(path: '${files.length}.mp4',
      length: length, offset: offset));
    offset += length;
  }
  return TorrentModel(name: 'test', files: files,
    infoHashBuffer: Uint8List(20), pieceLength: pieceLength,
    pieces: List.generate((offset / pieceLength).ceil(), (_) => Uint8List(20)),
    announces: [], nodes: [], version: TorrentVersion.v1);
}

class TestPeer implements Peer {
  @override
  final List<int> remoteCompletePieces;
  TestPeer(int count) : remoteCompletePieces = List.generate(count, (i) => i);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestPieces implements PieceProvider {
  @override
  final pieces = <int, Piece>{};
  TestPieces(TorrentModel model) {
    for (var i = 0; i < model.pieces!.length; i++) {
      pieces[i] = Piece('', i, model.pieceLength, i * model.pieceLength);
    }
  }
  void complete(int i) {
    var piece = pieces[i]!;
    pieces[i] = Piece('', i, piece.byteLength, piece.offset, isComplete: true);
  }
  @override
  Piece? operator [](int index) => pieces[index];
  @override
  int get length => pieces.length;
  @override
  Set<int> get downloadingPieces => {};
}

AdvancedSequentialPieceSelector selector(TorrentModel model) =>
    AdvancedSequentialPieceSelector(const SequentialConfig(
      lookAheadSize: 8, adaptiveStrategy: false, enablePeerPriority: false))
      ..initialize(model.pieces!.length, model.pieceLength);

void main() {
  test('only focused critical pieces and the current window are urgent', () {
    var model = torrent([12 * mb, 20 * mb, 12 * mb], mb);
    var selected = selector(model)..setCriticalPieces({0, 43});
    expect(selected.isUrgent(0), isFalse);
    expect(selected.isUrgent(1), isFalse);
    selected.setStreamFile(12 * mb, 20 * mb);
    expect(selected.isUrgent(12), isTrue);
    expect(selected.isUrgent(31), isTrue);
    expect(selected.isUrgent(13), isTrue);
    expect(selected.isUrgent(19), isTrue);
    expect(selected.isUrgent(20), isFalse);
    expect(selected.isUrgent(0), isFalse);
    expect(selected.isUrgent(32), isFalse);

    selected.setPlaybackPosition(22 * mb, mb);
    expect(selected.isUrgent(12), isTrue);
    expect(selected.isUrgent(13), isFalse);
    expect(selected.isUrgent(22), isTrue);
    expect(selected.isUrgent(29), isTrue);
    expect(selected.isUrgent(30), isFalse);
    expect(selected.isUrgent(31), isTrue);
    selected.setPlaybackPosition(31 * mb, mb);
    expect(selected.isUrgent(31), isTrue);
    expect(selected.isUrgent(32), isFalse);
  });

  test('urgent timeouts release immediately; other pieces wait for three resends', () {
    var selected = selector(torrent([12 * mb, 20 * mb, 12 * mb], mb))
      ..setStreamFile(12 * mb, 20 * mb);
    for (var piece in [12, 13, 31]) {
      expect(shouldReleaseTimedOutRequest(0, urgent: selected.isUrgent(piece)),
        isTrue);
    }
    for (var piece in [0, 20, 32]) {
      for (var count in [0, 1, 2]) {
        expect(shouldReleaseTimedOutRequest(count,
          urgent: selected.isUrgent(piece)), isFalse);
      }
      for (var count in [3, 4]) {
        expect(shouldReleaseTimedOutRequest(count,
          urgent: selected.isUrgent(piece)), isTrue);
      }
    }
    var ordinary = selector(torrent([20 * mb], mb));
    expect(shouldReleaseTimedOutRequest(0, urgent: ordinary.isUrgent(0)), isFalse);
  });

  test('batch selects the focused head, tail and window, skipping other files', () {
    var model = torrent([12 * mb, 20 * mb, 12 * mb], mb);
    var focus = model.files[1];
    var priorities = FilePriorityManager(model)..setPriorities({
      0: FilePriority.skip, 1: FilePriority.high, 2: FilePriority.skip,
    });
    var pieces = TestPieces(model);
    var peer = TestPeer(pieces.length);
    var selected = selector(model)
      ..setStreamFile(focus.offset, focus.length)
      ..setSkippedPieces(priorities.getSkippedPieces());
    expect(selected.criticalPieces, {12, 31});
    expect(selected.lookAheadPieces, {12, 13, 14, 15, 16, 17, 18, 19});
    expect(selected.selectPiece(peer, pieces)?.index, 12);
    pieces.complete(12);
    expect(selected.selectPiece(peer, pieces)?.index, 31);
    pieces.complete(31);
    for (var i = 13; i < 31; i++) {
      // Peer suggestions must not bypass the focused critical/window order.
      expect(selected.selectPiece(peer, pieces, false, {0})?.index, i);
      pieces.complete(i);
    }
    expect(selected.selectPiece(peer, pieces), isNull);
  });

  test('200 MB stream only makes its head and tail critical', () {
    var selected = selector(torrent([200 * mb], 4 * mb))
      ..setCriticalPieces({1, 2, 3, 47, 48})
      ..setStreamFile(0, 200 * mb);
    expect(selected.criticalPieces, {0, 49});
    selected.setStreamFile(mb, mb);
    expect(selected.criticalPieces, {0});
  });

  test('head and tail ranges include every overlapping piece', () {
    var selected = selector(torrent([8 * mb], mb))
      ..setStreamFile(mb - 64 * 1024, 2 * mb + 128 * 1024);
    expect(selected.criticalPieces, {0, 1, 2, 3});
    expect(selected.currentPlaybackPiece, 0);
    expect(selected.lookAheadPieces, {0, 1, 2, 3});
    selected.setStreamFile(mb + 100, 200);
    expect(selected.criticalPieces, {1});
    expect(selected.lookAheadPieces, {1});
  });

  test('seek window stays inside the file and can be completely buffered', () {
    var model = torrent([12 * mb, 20 * mb, 12 * mb], mb);
    var selected = selector(model)..setStreamFile(12 * mb, 20 * mb);
    var pieces = TestPieces(model);
    selected.setPlaybackPosition(22 * mb, mb);
    expect(selected.currentPlaybackPiece, 22);
    expect(selected.lookAheadPieces, {22, 23, 24, 25, 26, 27, 28, 29});
    selected.setPlaybackPosition(29 * mb, mb);
    expect(selected.lookAheadPieces, {29, 30, 31});
    for (var i in selected.lookAheadPieces) {
      pieces.complete(i);
    }
    expect(selected.getStats(pieces).bufferHealth, 100);
    expect(selected.getStats(pieces).bufferedPieces, 3);
    selected.setPlaybackPosition(43 * mb, mb);
    expect(selected.lookAheadPieces, {31});
    expect(selected.getStats(pieces).bufferHealth, 100);
    selected.setPlaybackPosition(0, mb);
    expect(selected.currentPlaybackPiece, 12);
  });

  test('file priority pieces cannot reset a focused playback window', () {
    var model = torrent([12 * mb, 20 * mb, 12 * mb], mb);
    var selected = selector(model)
      ..setStreamFile(12 * mb, 20 * mb)
      ..setPlaybackPosition(29 * mb, mb);
    var priorities = FilePriorityManager(model)..setPriority(1, FilePriority.high);
    selected.setPriorityPieces(priorities.getHighPriorityPieces());
    expect(selected.currentPlaybackPiece, 29);
    expect(selected.lookAheadPieces, {29, 30, 31});
    var ordinary = selector(model)..setPriorityPieces({7, 8});
    expect(ordinary.currentPlaybackPiece, 7);
    expect(ordinary.lookAheadPieces, {7, 8});
  });

  test('sequential scan ends at the file while peer fallback remains available', () {
    var model = torrent([12 * mb, 20 * mb, 12 * mb], mb);
    var selected = selector(model)
      ..setStreamFile(12 * mb, 20 * mb)
      ..setPlaybackPosition(31 * mb, mb);
    var pieces = TestPieces(model)..complete(12)..complete(31);
    // If priority 3 ran past the selected file, it would return piece 32.
    expect(selected.selectPiece(TestPeer(pieces.length), pieces)?.index, 0);
    selected.setSkippedPieces({0});
    expect(selected.selectPiece(TestPeer(pieces.length), pieces)?.index, 1);
  });

  test('task accepts file focus and priorities before start', () async {
    var task = TorrentTask.newTask(torrent([mb, 2 * mb, mb], mb),
      'build/unused-stream-test', true, null, null,
      SequentialConfig.forVideoStreaming());
    task.setStreamFile(1);
    task.setFilePriority(0, FilePriority.skip);
    task.setFilePriority(1, FilePriority.high);
    task.setFilePriorities({2: FilePriority.skip});
    expect(task.getFilePriority(0), FilePriority.skip);
    expect(task.getFilePriority(1), FilePriority.high);
    expect(task.getFilePriority(2), FilePriority.skip);
    expect(task.pieceManager, isNull);
    await task.dispose();
  });
}
