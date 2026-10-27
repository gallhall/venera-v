/// Types of Bangumi subjects that venera-v links to.
abstract final class BangumiSubjectType {
  /// Books, which comics are on Bangumi.
  static const book = 1;

  static const anime = 2;
}

/// How a subject is in a user's collection on Bangumi.
abstract final class BangumiCollectionType {
  static const wish = 1;

  static const done = 2;

  static const doing = 3;

  static const onHold = 4;

  static const dropped = 5;

  static const values = [wish, doing, done, onHold, dropped];
}

/// How an episode is in a user's collection on Bangumi.
abstract final class BangumiEpisodeStatus {
  static const none = 0;

  static const watched = 2;
}

String _https(Object? url) {
  if (url is! String) return '';
  if (url.startsWith('//')) return 'https:$url';
  return url.startsWith('http://') ? url.replaceFirst('http', 'https') : url;
}

int _int(Object? value) => value is num ? value.toInt() : 0;

String _string(Object? value) => value is String ? value : '';

class BangumiSubject {
  final int id;

  /// See [BangumiSubjectType].
  final int type;

  final String name;

  /// The Chinese name, empty if there is none.
  final String nameCn;

  /// The cover, empty if there is none.
  final String image;

  /// 0 if not rated.
  final double score;

  /// 0 if not ranked.
  final int rank;

  /// Episodes, or chapters of a book. 0 if unknown.
  final int eps;

  final int volumes;

  /// Air or release date, `YYYY-MM-DD`, empty if unknown.
  final String date;

  final String summary;

  /// E.g. TV, 剧场版, 漫画.
  final String platform;

  const BangumiSubject({
    required this.id,
    required this.type,
    required this.name,
    this.nameCn = '',
    this.image = '',
    this.score = 0,
    this.rank = 0,
    this.eps = 0,
    this.volumes = 0,
    this.date = '',
    this.summary = '',
    this.platform = '',
  });

  String get displayName => nameCn.isNotEmpty ? nameCn : name;

  String get url => 'https://bgm.tv/subject/$id';

  /// A subject of the v0 API or of the old calendar API.
  static BangumiSubject? fromJson(Object? json) {
    if (json is! Map || json['id'] is! int) return null;
    var images = json['images'];
    var image = images is Map
        ? images['common'] ?? images['large'] ?? images['medium']
        : json['image'];
    var rating = json['rating'];
    return BangumiSubject(
      id: json['id'],
      type: _int(json['type']),
      name: _string(json['name']),
      nameCn: _string(json['name_cn']),
      image: _https(image),
      score: rating is Map && rating['score'] is num
          ? (rating['score'] as num).toDouble()
          : 0,
      rank: _int(
        rating is Map && rating['rank'] is num ? rating['rank'] : json['rank'],
      ),
      eps: _int(json['eps'] ?? json['total_episodes']),
      volumes: _int(json['volumes']),
      date: _string(json['date'] ?? json['air_date']),
      summary: _string(json['summary']),
      platform: _string(json['platform']),
    );
  }
}

class BangumiEpisode {
  final int id;

  /// 0 for the main story, others for SP, OP, ED and so on.
  final int type;

  /// The number of the episode in its subject, from 1. Null if unknown.
  final int? ep;

  /// The number of the episode over the whole series.
  final double sort;

  final String name;

  final String nameCn;

  /// `YYYY-MM-DD`, empty if unknown.
  final String airdate;

  const BangumiEpisode({
    required this.id,
    this.type = 0,
    this.ep,
    required this.sort,
    this.name = '',
    this.nameCn = '',
    this.airdate = '',
  });

  /// The number it is shown with.
  int get number => ep ?? sort.toInt();

  static BangumiEpisode? fromJson(Object? json) {
    if (json is! Map || json['id'] is! int) return null;
    var ep = json['ep'];
    var sort = json['sort'];
    return BangumiEpisode(
      id: json['id'],
      type: _int(json['type']),
      // Bangumi sends 0 for episodes without a number.
      ep: ep is num && ep > 0 && ep == ep.toInt() ? ep.toInt() : null,
      sort: sort is num ? sort.toDouble() : 0,
      name: _string(json['name']),
      nameCn: _string(json['name_cn']),
      airdate: _string(json['airdate']),
    );
  }
}

/// A subject in a user's collection.
class BangumiCollection {
  /// See [BangumiCollectionType].
  final int type;

  /// 0 if not rated.
  final int rate;

  /// Episodes watched, or chapters read.
  final int epStatus;

  final int volStatus;

  const BangumiCollection({
    required this.type,
    this.rate = 0,
    this.epStatus = 0,
    this.volStatus = 0,
  });

  static BangumiCollection? fromJson(Object? json) {
    if (json is! Map || json['type'] is! int) return null;
    return BangumiCollection(
      type: json['type'],
      rate: _int(json['rate']),
      epStatus: _int(json['ep_status']),
      volStatus: _int(json['vol_status']),
    );
  }
}

class BangumiUser {
  final String username;

  final String nickname;

  final String avatar;

  const BangumiUser({
    required this.username,
    this.nickname = '',
    this.avatar = '',
  });

  String get displayName => nickname.isNotEmpty ? nickname : username;

  static BangumiUser? fromJson(Object? json) {
    if (json is! Map) return null;
    var username = json['username'];
    if (username is! String || username.isEmpty) return null;
    var avatar = json['avatar'];
    return BangumiUser(
      username: username,
      nickname: _string(json['nickname']),
      avatar: _https(
        avatar is Map
            ? avatar['large'] ?? avatar['medium'] ?? avatar['small']
            : avatar,
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'username': username,
    'nickname': nickname,
    'avatar': avatar,
  };
}

class BangumiComment {
  final int id;

  final BangumiUser user;

  final int type;

  final int rate;

  final String comment;

  final DateTime? time;

  const BangumiComment({
    required this.id,
    required this.user,
    this.type = 0,
    this.rate = 0,
    this.comment = '',
    this.time,
  });

  static BangumiComment? fromJson(Object? json) {
    if (json is! Map || json['id'] is! int) return null;
    var time = json['updatedAt'];
    return BangumiComment(
      id: json['id'],
      user:
          BangumiUser.fromJson(json['user']) ?? const BangumiUser(username: ''),
      type: _int(json['type']),
      rate: _int(json['rate']),
      comment: _string(json['comment']),
      time: time is num && time > 0 && time < 8640000000000
          ? DateTime.fromMillisecondsSinceEpoch(
              time.toInt() * 1000,
              isUtc: true,
            )
          : null,
    );
  }
}

class BangumiCommentPage {
  final List<BangumiComment> data;

  final int total;

  /// Includes malformed entries so the next offset still follows the API.
  final int count;

  const BangumiCommentPage({
    required this.data,
    required this.total,
    required this.count,
  });
}

/// The Bangumi subject a comic or video of a source is linked to.
class BangumiBinding {
  final int subjectId;

  /// See [BangumiSubjectType].
  final int type;

  final String name;

  final String nameCn;

  final String image;

  /// Added to the number of an episode of the source to get its number on
  /// Bangumi, for sources that number a season differently.
  final int offset;

  const BangumiBinding({
    required this.subjectId,
    required this.type,
    required this.name,
    this.nameCn = '',
    this.image = '',
    this.offset = 0,
  });

  factory BangumiBinding.fromSubject(BangumiSubject subject) {
    return BangumiBinding(
      subjectId: subject.id,
      type: subject.type,
      name: subject.name,
      nameCn: subject.nameCn,
      image: subject.image,
    );
  }

  bool get isBook => type == BangumiSubjectType.book;

  String get displayName => nameCn.isNotEmpty ? nameCn : name;

  String get url => 'https://bgm.tv/subject/$subjectId';

  String coverFor(String sourceCover, {bool sourceFailed = false}) {
    return image.isNotEmpty && (sourceCover.isEmpty || sourceFailed)
        ? image
        : sourceCover;
  }

  BangumiBinding copyWith({int? offset}) {
    return BangumiBinding(
      subjectId: subjectId,
      type: type,
      name: name,
      nameCn: nameCn,
      image: image,
      offset: offset ?? this.offset,
    );
  }

  Map<String, dynamic> toJson() => {
    'subjectId': subjectId,
    'type': type,
    'name': name,
    'nameCn': nameCn,
    'image': image,
    'offset': offset,
  };

  static BangumiBinding? fromJson(Object? json) {
    if (json is! Map || json['subjectId'] is! int) return null;
    return BangumiBinding(
      subjectId: json['subjectId'],
      type: _int(json['type']),
      name: _string(json['name']),
      nameCn: _string(json['nameCn']),
      image: _string(json['image']),
      offset: _int(json['offset']),
    );
  }
}

/// Numbers of the episodes and chapters of sources, to find them on
/// Bangumi.
abstract final class BangumiEpisodeNumber {
  /// Extras, which do not count as episodes on Bangumi.
  static final _extra = RegExp(
    r'(^|[^a-z])(pv|cm|sp|ova|oad|op|ed|ncop|nced|trailer|preview)($|[^a-z])'
    r'|预告|預告|特别篇|特別篇|番外|总集篇|總集篇|花絮|彩蛋|特典',
    caseSensitive: false,
  );

  static final _numbered = RegExp(
    r'第\s*(\d+(?:\.\d+)?)\s*[集话話回章]'
    r'|(?:^|[^a-z])(?:ep|e|episode|ch|chapter)\.?\s*(\d+(?:\.\d+)?)',
    caseSensitive: false,
  );

  static final _volume = RegExp(
    r'第\s*\d+\s*[卷册冊]|(?:^|[^a-z])vol(?:ume)?\.?\s*\d+',
    caseSensitive: false,
  );

  /// Numbers that are not the episode's: resolutions, codecs, years,
  /// seasons and versions such as the 2 of 01v2.
  static final _noise = RegExp(
    r'\d{3,4}\s*[pP]|[xXhH]\.?26[45]|\d+\s*[kK](?![a-zA-Z])|\d{4}\s*年'
    r'|第\s*\d+\s*[季期部]|(?:^|[^a-zA-Z])[sS]\d+|(?<=\d)[vV]\d+',
  );

  static final _number = RegExp(r'\d+(?:\.\d+)?');

  /// The number of the episode or chapter titled [title]: the number in the
  /// title, or [position] if it has none. Null for extras such as PV, SP
  /// and OVA, for volumes and for numbers such as 12.5, as these are not
  /// counted on Bangumi.
  static int? of(String title, int position) {
    var t = _halfWidth(title).trim();
    if (_extra.hasMatch(t)) return null;
    var numbered = _numbered.firstMatch(t);
    if (numbered != null) {
      return _whole(numbered.group(1) ?? numbered.group(2)!);
    }
    if (_volume.hasMatch(t)) return null;
    var numbers = _number.allMatches(t.replaceAll(_noise, ' ')).toList();
    if (numbers.isEmpty) return position;
    // A range such as 01-02: the episode watched last.
    return _whole(numbers.last.group(0)!);
  }

  static int? _whole(String number) {
    if (number.contains('.')) return null;
    var value = int.parse(number);
    return value > 0 ? value : null;
  }

  static String _halfWidth(String s) {
    return String.fromCharCodes(
      s.runes.map((c) => c >= 0xFF10 && c <= 0xFF19 ? c - 0xFF10 + 0x30 : c),
    );
  }

  /// The main episode numbered [number] in [episodes]: by its number in the
  /// subject, then by its number over the series, as sources number the
  /// episodes of a later season either way.
  static BangumiEpisode? match(List<BangumiEpisode> episodes, int number) {
    var main = episodes.where((e) => e.type == 0);
    return main.where((e) => e.ep == number).firstOrNull ??
        main.where((e) => e.sort == number).firstOrNull;
  }
}
