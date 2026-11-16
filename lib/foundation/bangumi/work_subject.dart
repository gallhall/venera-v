import 'package:venera/foundation/bangumi/bangumi.dart';
import 'package:venera/foundation/comic_type.dart';

/// The 绑定 of work [id] of source [sourceKey], if any.
typedef BindingLookup = BangumiBinding? Function(String sourceKey, String id);

/// A 代表条目: the Bangumi subject that stands for a work.
class RepresentingSubject {
  const RepresentingSubject(this.id, {required this.isBook, this.binding});

  /// The subject id.
  final int id;

  /// Whether the subject is a book: the work is a comic, read from its own
  /// page, never from the subject page.
  final bool isBook;

  /// The 绑定 it comes from; null when the work is the subject itself.
  final BangumiBinding? binding;
}

/// Where opening a work goes.
sealed class WorkRoute {
  const WorkRoute();
}

/// The subject page of anime: its sources are picked there.
final class SubjectRoute extends WorkRoute {
  const SubjectRoute(this.subjectId, {this.title});

  final int subjectId;

  /// The subject's name, when it is known from the 绑定.
  final String? title;
}

/// The work's own details page.
final class DetailsRoute extends WorkRoute {
  const DetailsRoute();
}

/// 代表条目 of works, wherever a work stands for its subject: 稍后看,
/// 时长记录, statistics and opening a work from a list.
///
/// A work is given as its source key and id; a Bangumi subject itself is
/// source `bangumi` with id `bangumi:<subject>` (or the bare number).
class WorkSubject {
  WorkSubject({BindingLookup? bindings})
    : _bindings = bindings ?? BangumiManager().bindingOf;

  final BindingLookup _bindings;

  /// [id] as it is kept: a bare subject number of source `bangumi` becomes
  /// `bangumi:<subject>`; any other id stays.
  static String canonicalId(String sourceKey, String id) {
    if (!ComicType.fromKey(sourceKey).isBangumi ||
        bangumiSubjectIdFromHistory(id) != null) {
      return id;
    }
    var number = int.tryParse(id);
    return number != null && number > 0 ? bangumiHistoryId(number) : id;
  }

  /// The 代表条目 of the work: the subject itself, or the anime or book it
  /// is bound to; null when it has none.
  RepresentingSubject? of(String sourceKey, String id) {
    if (ComicType.fromKey(sourceKey).isBangumi) {
      var subject = bangumiSubjectIdFromHistory(canonicalId(sourceKey, id));
      return subject == null
          ? null
          : RepresentingSubject(subject, isBook: false);
    }
    var binding = _bindings(sourceKey, id);
    if (binding == null) return null;
    return RepresentingSubject(
      binding.subjectId,
      isBook: binding.isBook,
      binding: binding,
    );
  }

  /// The identity the work is kept under in 稍后看: anime as their
  /// subject, anything else as itself.
  (String id, ComicType type) key(String sourceKey, String id) {
    var subject = of(sourceKey, id);
    if (subject != null && !subject.isBook) {
      return (bangumiHistoryId(subject.id), ComicType.bangumi);
    }
    return (canonicalId(sourceKey, id), ComicType.fromKey(sourceKey));
  }

  /// Where opening the work goes: anime to its subject page, comics (bound
  /// to a book or not) and unbound works to their own page.
  WorkRoute route(String sourceKey, String id) {
    var subject = of(sourceKey, id);
    if (subject == null || subject.isBook) return const DetailsRoute();
    var name = subject.binding?.displayName;
    return SubjectRoute(
      subject.id,
      title: name == null || name.isEmpty ? null : name,
    );
  }
}
