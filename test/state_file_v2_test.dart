import 'dart:io';
import 'dart:typed_data';

import 'package:dtorrent_task_v2/dtorrent_task_v2.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<StateFileV2> stateFile() async {
    await Directory('build').create(recursive: true);
    var directory = await Directory('build').createTemp('state-file-v2-');
    var model = TorrentModel(name: 'test',
      files: [TorrentFileModel(path: 'test.mp4', length: 256, offset: 0)],
      infoHashBuffer: Uint8List(20), pieceLength: 256,
      pieces: [Uint8List(20)], announces: [], nodes: [],
      version: TorrentVersion.v1);
    var state = await StateFileV2.getStateFile(directory.path, model);
    addTearDown(() async {
      await state.close();
      await directory.delete(recursive: true);
    });
    // Ensure the controller exists before exercising shutdown.
    await state.getAccess();
    return state;
  }

  test('updates after state file close return without throwing or reopening', () async {
    var state = await stateFile();
    await state.close();
    expect(state.isClosed, isTrue);
    expect(await state.update(0).timeout(const Duration(seconds: 1)), isFalse);
    expect(await state.update(-1, uploaded: 100)
      .timeout(const Duration(seconds: 1)), isFalse);
    expect(await state.updateBitfield(0).timeout(const Duration(seconds: 1)),
      isFalse);
    expect(await state.updateUploaded(100).timeout(const Duration(seconds: 1)),
      isFalse);
    expect(state.bitfield.getBit(0), isFalse);
    expect(state.uploaded, 0);
  });

  test('close during update access await prevents enqueueing on the controller', () async {
    var state = await stateFile();
    var update = state.update(0);
    // update has yielded at getAccess; close marks the state closed immediately.
    var closing = state.close();
    expect(await update.timeout(const Duration(seconds: 1)), isFalse);
    await closing;
    expect(state.bitfield.getBit(0), isFalse);
  });
}
