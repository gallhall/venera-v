import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/translations.dart';

import 'bangumi_api.dart';
import 'bangumi_models.dart';

export 'bangumi_api.dart';
export 'bangumi_models.dart';

/// Marks episodes and chapters as watched or read in the Bangumi
/// collection of a user.
class BangumiProgress {
  BangumiProgress(this.api, this.username);

  final BangumiApi api;

  final String username;

  final _episodes = <int, List<BangumiEpisode>>{};

  /// The main episodes of a subject, loaded once.
  Future<List<BangumiEpisode>> episodes(
    int subjectId, {
    bool refresh = false,
  }) async {
    var episodes = _episodes[subjectId];
    if (episodes == null || refresh) {
      episodes = _episodes[subjectId] = await api.episodes(subjectId);
    }
    return episodes;
  }

  /// Records that episode [number] of the source of [binding] was watched,
  /// or chapter [number] of a book read. Returns the number of the episode
  /// or chapter marked on Bangumi, null if there is none to mark.
  ///
  /// A subject not yet watched becomes one that is; once every episode of
  /// an anime is watched, it becomes watched.
  Future<int?> markFinished(BangumiBinding binding, int number) async {
    var n = number + binding.offset;
    if (n < 1) return null;
    var subjectId = binding.subjectId;
    if (binding.isBook) {
      var collection = await api.collection(username, subjectId);
      var read = collection?.epStatus ?? 0;
      var start = _shouldStart(collection);
      if (n <= read && !start) return null;
      await api.updateCollection(
        subjectId,
        type: start ? BangumiCollectionType.doing : null,
        epStatus: math.max(n, read),
      );
      return n;
    }
    var all = await episodes(subjectId);
    var episode = BangumiEpisodeNumber.match(all, n);
    if (episode == null) return null;
    var collection = await api.collection(username, subjectId);
    if (_shouldStart(collection)) {
      await api.updateCollection(subjectId, type: BangumiCollectionType.doing);
    }
    await api.markEpisodes(subjectId, [
      episode.id,
    ], BangumiEpisodeStatus.watched);
    var main = all.where((e) => e.type == 0).toList();
    var isLast = main.every((e) => e.sort <= episode.sort);
    if (isLast && collection?.type != BangumiCollectionType.done) {
      var statuses = await api.episodeStatuses(subjectId);
      if (main.every((e) => statuses[e.id] == BangumiEpisodeStatus.watched)) {
        await api.updateCollection(subjectId, type: BangumiCollectionType.done);
      }
    }
    return episode.number;
  }

  /// Sets how far the subject of [binding] is watched or read: the
  /// episodes up to [number] (as numbered on Bangumi) are watched and those
  /// after it not, or [number] chapters of a book are read.
  Future<void> setProgress(BangumiBinding binding, int number) async {
    var subjectId = binding.subjectId;
    var collection = await api.collection(username, subjectId);
    var start = number > 0 && _shouldStart(collection);
    if (collection == null && number == 0) return;
    if (binding.isBook) {
      await api.updateCollection(
        subjectId,
        type: start ? BangumiCollectionType.doing : null,
        epStatus: number,
      );
      return;
    }
    if (start) {
      await api.updateCollection(subjectId, type: BangumiCollectionType.doing);
    }
    var main = (await episodes(subjectId)).where((e) => e.type == 0);
    var statuses = await api.episodeStatuses(subjectId);
    bool watched(BangumiEpisode e) =>
        statuses[e.id] == BangumiEpisodeStatus.watched;
    var mark = [
      for (var e in main)
        if (e.number <= number && !watched(e)) e.id,
    ];
    var clear = [
      for (var e in main)
        if (e.number > number && watched(e)) e.id,
    ];
    if (mark.isNotEmpty) {
      await api.markEpisodes(subjectId, mark, BangumiEpisodeStatus.watched);
    }
    if (clear.isNotEmpty) {
      await api.markEpisodes(subjectId, clear, BangumiEpisodeStatus.none);
    }
  }

  /// Whether the subject becomes one being watched once its progress is
  /// marked: if it is not in the collection, only wished for or on hold.
  static bool _shouldStart(BangumiCollection? collection) {
    return collection == null ||
        collection.type == BangumiCollectionType.wish ||
        collection.type == BangumiCollectionType.onHold;
  }
}

/// Links comics and videos of sources to Bangumi subjects and keeps the
/// progress on Bangumi, with the user's access token.
///
/// The token, its user and the links are settings, so that backups and
/// data sync include them. Links are keyed `<id>@<source key>` like
/// comic specific reader settings.
class BangumiManager with ChangeNotifier {
  factory BangumiManager() => instance;

  BangumiManager._();

  static final instance = BangumiManager._();

  String? get token {
    var token = appdata.settings['bangumiToken'];
    return token is String && token.isNotEmpty ? token : null;
  }

  BangumiUser? get user =>
      BangumiUser.fromJson(appdata.settings['bangumiUser']);

  bool get isLoggedIn => token != null && user != null;

  /// Whether finished episodes and chapters are marked on Bangumi.
  bool get autoSync => appdata.settings['bangumiAutoSync'] != false;

  set autoSync(bool value) {
    appdata.settings['bangumiAutoSync'] = value;
    appdata.saveData();
    notifyListeners();
  }

  BangumiApi? _api;

  BangumiProgress? _progress;

  /// The API with the current token.
  BangumiApi get api {
    if (_api == null || _api!.token != token) {
      _api = BangumiApi(token: token);
      _progress = null;
    }
    return _api!;
  }

  /// Progress of the logged in user. Only while logged in.
  BangumiProgress get progress {
    var api = this.api;
    return _progress ??= BangumiProgress(api, user!.username);
  }

  /// Checks [token] and keeps it.
  Future<BangumiUser> login(String token) async {
    var user = await BangumiApi(token: token).me();
    appdata.settings['bangumiToken'] = token;
    appdata.settings['bangumiUser'] = user.toJson();
    await appdata.saveData();
    _marked.clear();
    _watching = null;
    notifyListeners();
    return user;
  }

  void logout() {
    appdata.settings['bangumiToken'] = '';
    appdata.settings['bangumiUser'] = null;
    appdata.saveData();
    _marked.clear();
    _watching = null;
    notifyListeners();
  }

  static String _key(String sourceKey, String id) => '$id@$sourceKey';

  Map<String, dynamic> get _bindings {
    var bindings = appdata.settings['bangumiBindings'];
    if (bindings is! Map<String, dynamic>) {
      bindings = <String, dynamic>{
        if (bindings is Map)
          for (var e in bindings.entries) e.key.toString(): e.value,
      };
      appdata.settings['bangumiBindings'] = bindings;
    }
    return bindings;
  }

  BangumiBinding? bindingOf(String sourceKey, String id) {
    return BangumiBinding.fromJson(_bindings[_key(sourceKey, id)]);
  }

  void bind(String sourceKey, String id, BangumiBinding binding) {
    _bindings[_key(sourceKey, id)] = binding.toJson();
    appdata.saveData();
    notifyListeners();
  }

  void unbind(String sourceKey, String id) {
    _bindings.remove(_key(sourceKey, id));
    appdata.saveData();
    notifyListeners();
  }

  /// Episodes and chapters marked in this run, by subject and number on
  /// Bangumi (`<subject>:<number>`), so that each is marked once.
  final _marked = <String>{};

  /// Marks the episode or chapter titled [title] of a comic or video as
  /// finished on Bangumi if the comic or video is linked to a subject.
  /// [position] is its position in its group, from 1, used if the title
  /// has no number.
  Future<void> onFinished({
    required String sourceKey,
    required String id,
    required String title,
    required int position,
  }) async {
    if (!autoSync || !isLoggedIn) return;
    var binding = bindingOf(sourceKey, id);
    if (binding == null) return;
    var number = BangumiEpisodeNumber.of(title, position);
    if (number == null) return;
    // The number on Bangumi, as sources linked to a subject may number it
    // differently.
    var key = '${binding.subjectId}:${number + binding.offset}';
    if (!_marked.add(key)) return;
    try {
      var marked = await progress.markFinished(binding, number);
      if (marked == null) {
        Log.info('Bangumi', 'Nothing to mark for $title in $key');
        // No such episode: tried again, e.g. once the offset is fixed. A
        // chapter already read stays done.
        if (!binding.isBook) _marked.remove(key);
        return;
      }
      Log.info('Bangumi', 'Marked $marked of ${binding.subjectId}');
      _showMessage(
        (binding.isBook
                ? 'Marked chapter @n on Bangumi'
                : 'Marked episode @n on Bangumi')
            .tlParams({'n': marked}),
      );
    } catch (e, s) {
      // Tried again the next time it is finished.
      _marked.remove(key);
      Log.error('Bangumi', 'Failed to mark $key: $e', s);
      _showMessage('${'Failed to sync with Bangumi'.tl}: $e');
    }
  }

  void _showMessage(String message) {
    try {
      App.rootContext.showMessage(message: message);
    } catch (_) {
      // No app, e.g. in tests.
    }
  }

  List<List<BangumiSubject>>? _calendar;

  DateTime? _calendarTime;

  /// The anime airing this season by weekday, Monday first. Loaded at most
  /// once an hour.
  Future<List<List<BangumiSubject>>> calendar({bool refresh = false}) async {
    var time = _calendarTime;
    if (_calendar != null &&
        !refresh &&
        time != null &&
        DateTime.now().difference(time) < const Duration(hours: 1)) {
      return _calendar!;
    }
    _calendar = await api.calendar();
    _calendarTime = DateTime.now();
    return _calendar!;
  }

  Set<int>? _watching;

  /// Anime being watched by the user, empty if not logged in.
  Future<Set<int>> watching({bool refresh = false}) async {
    var user = this.user;
    if (!isLoggedIn || user == null) return {};
    if (_watching != null && !refresh) return _watching!;
    return _watching = await api.collectedSubjects(
      user.username,
      subjectType: BangumiSubjectType.anime,
      type: BangumiCollectionType.doing,
    );
  }
}
