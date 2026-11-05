import 'package:venera/foundation/bangumi/bangumi_models.dart';
import 'package:venera/foundation/bangumi/release_lines.dart';

/// A row of a [ReleaseCatalogue]: one torrent, as listed by [source].
final class CatalogueRelease<S> {
  final S source;
  final RssRelease release;

  CatalogueRelease(this.source, this.release);
}

/// A release of a catalogue chosen for one episode.
typedef CatalogueMatch<S> = ({CatalogueRelease<S> row, EpisodeRelease match});

/// The BT releases found for a subject across several sources, one row per
/// torrent, and which of them stand for which episode.
///
/// Feeds overlap (Mikan and its mirrors list the same release). A copy is
/// the same torrent by hash, or by title when it has none (acg.rip). Two
/// different hashes are different torrents, whatever their titles. A row
/// keeps the titles of all its copies, as Mikan converts titles to
/// simplified Chinese while the others keep the original ones; it prefers
/// a .torrent URL, which needs no metadata download, over a magnet.
class ReleaseCatalogue<S> {
  final _rows = <CatalogueRelease<S>>[];
  final _ids = <CatalogueRelease<S>, Set<String>>{};
  final _coverage = <CatalogueRelease<S>, Map<int, EpisodeRelease?>>{};

  /// The rows, in the order their first copy was found.
  List<CatalogueRelease<S>> get releases => List.unmodifiable(_rows);

  /// The release groups of the rows.
  Set<String> get groups =>
      {for (var r in _rows) RssReleaseName.parse(r.release.title).group};

  /// Whether every row is known to have no seeders.
  bool get allWithoutSeeders =>
      _rows.isNotEmpty && _rows.every((r) => r.release.seeders == 0);

  void clear() {
    _rows.clear();
    _ids.clear();
    _coverage.clear();
  }

  /// Adds [release] from [source], merged into the row of the same torrent
  /// if there is one.
  void add(S source, RssRelease release) {
    var item = CatalogueRelease(source, release);
    var mine = _idsOf(release);
    bool hashed(Set<String> set) => set.any((e) => e.startsWith('hash:'));
    bool same(CatalogueRelease<S> row) {
      var theirs = _ids[row]!;
      if (hashed(mine) && hashed(theirs)) {
        return mine.where((e) => e.startsWith('hash:')).any(theirs.contains);
      }
      return mine.any(theirs.contains);
    }
    var matching = _rows.where(same).toList();
    if (matching.isEmpty) {
      _rows.add(item);
      _ids[item] = mine;
      return;
    }
    // A hashed copy can join rows found by hash and by title alike.
    var keep = [...matching, item].firstWhere(
        (e) => !e.release.url.startsWith('magnet:'), orElse: () => matching.first);
    var merged = {...mine, for (var row in matching) ..._ids[row]!};
    var at = _rows.indexOf(matching.first);
    for (var row in matching) {
      _rows.remove(row);
      _ids.remove(row);
      _coverage.remove(row);
    }
    _rows.insert(at, keep);
    _ids[keep] = merged;
  }

  static Set<String> _idsOf(RssRelease r) => {
    if (r.hexInfoHash case var hash?) 'hash:$hash',
    'title:${r.title.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase()}',
  };

  /// What [row] holds of [episode] of [episodes], on its own line; null if
  /// not that episode.
  EpisodeRelease? match(CatalogueRelease<S> row, BangumiEpisode episode,
      List<BangumiEpisode> episodes) =>
      _coverage.putIfAbsent(row, () => matchReleaseLine(
        releases: [row.release], episodes: episodes,
        line: ReleaseLine.of(row.release)))[episode.id];

  /// The rows [accepts] lets through that hold [episode] (any if null),
  /// in order, those known to have no seeders last. Unknown counts keep
  /// their place.
  List<CatalogueRelease<S>> visible({
    required bool Function(RssRelease release) accepts,
    BangumiEpisode? episode,
    required List<BangumiEpisode> episodes,
  }) {
    var shown = [
      for (var r in _rows)
        if (accepts(r.release) &&
            (episode == null || match(r, episode, episodes) != null))
          r,
    ];
    return [
      for (var r in shown) if (r.release.seeders != 0) r,
      for (var r in shown) if (r.release.seeders == 0) r,
    ];
  }

  /// The release of each of [episodes] on the line of [tapped], and for
  /// each episode every row that holds it. [tapped] itself wins for episode
  /// [focused]; the others are ranked on the line as [matchReleaseLine]
  /// does (single episodes first, then revision and date).
  ({
    Map<int, CatalogueMatch<S>> chosen,
    Map<int, List<CatalogueMatch<S>>> alternatives,
  }) lineChoices(CatalogueRelease<S> tapped, List<BangumiEpisode> episodes,
      {int? focused}) {
    var best = matchReleaseLine(releases: _rows.map((r) => r.release),
        episodes: episodes, line: ReleaseLine.of(tapped.release));
    var chosen = <int, CatalogueMatch<S>>{};
    var alternatives = <int, List<CatalogueMatch<S>>>{};
    for (var episode in episodes) {
      if (episode.id == focused) {
        if (match(tapped, episode, episodes) case var m?) {
          chosen[episode.id] = (row: tapped, match: m);
        }
      } else if (best[episode.id] case var m?) {
        var owner = identical(m.release, tapped.release) ? tapped
            : _rows.firstWhere((r) => identical(r.release, m.release));
        chosen[episode.id] = (row: owner, match: m);
      }
      alternatives[episode.id] = [
        for (var row in _rows)
          if (match(row, episode, episodes) case var found?)
            (row: row, match: found),
      ];
    }
    return (chosen: chosen, alternatives: alternatives);
  }
}
