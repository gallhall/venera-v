import 'package:dtorrent_task_v2/src/standalone/dtorrent_common.dart';
import 'package:dtorrent_task_v2/src/peer/protocol/peer.dart';

import 'piece.dart';
import 'piece_provider.dart';
import 'piece_selector.dart';

///
/// Basic piece selector.
///
/// The basic strategy is:
///
/// - Choose the rarest available piece, finishing partial pieces on ties.
/// - Skipped pieces must never re-enter through peer suggestions or tie breaks.
class BasePieceSelector implements PieceSelector {
  final Set<int> _priorityPieces = {};
  final Set<int> _skippedPieces = {};

  @override
  void setPriorityPieces(Iterable<int> pieces) {
    _priorityPieces.clear();
    _priorityPieces.addAll(pieces);
  }

  @override
  void setSkippedPieces(Iterable<int> pieces) {
    _skippedPieces.clear();
    _skippedPieces.addAll(pieces);
  }

  @override
  Piece? selectPiece(Peer peer, PieceProvider provider,
      [bool random = false, Set<int>? suggestPieces]) {
    bool eligible(Piece? piece) => piece != null &&
        !_skippedPieces.contains(piece.index) && !piece.isCompleted &&
        piece.haveAvailableSubPiece() && piece.containsAvailablePeer(peer);

    if (suggestPieces != null) {
      for (var index in suggestPieces) {
        var piece = provider[index];
        if (eligible(piece)) {
          return piece;
        }
      }
    }
    var partial = provider.downloadingPieces
        .map((i) => provider[i]).where(eligible).cast<Piece>().toList();
    var candidates = partial.isNotEmpty ? partial : peer.remoteCompletePieces
        .map((i) => provider[i]).where(eligible).cast<Piece>().toList();
    var best = <Piece>[];
    for (var piece in candidates) {
      if (best.isEmpty ||
          piece.availablePeersCount < best.first.availablePeersCount ||
          piece.availablePeersCount == best.first.availablePeersCount &&
            piece.availableSubPieceCount < best.first.availableSubPieceCount) {
        best = [piece];
      } else if (piece.availablePeersCount == best.first.availablePeersCount &&
          piece.availableSubPieceCount == best.first.availableSubPieceCount) {
        best.add(piece);
      }
    }
    if (best.isEmpty) {
      return null;
    }
    return best[random ? randomInt(best.length) : 0];
  }
}
