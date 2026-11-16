import 'package:flutter/widgets.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/bangumi/work_subject.dart';
import 'package:venera/pages/bangumi/bangumi_subject_page.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';

/// Opens work [id] of source [sourceKey] from a list (history, 稍后看,
/// statistics) where [WorkSubject.route] says: anime on its subject page,
/// anything else on its own page.
///
/// [animeSubject] is the subject already known to stand for the anime, such
/// as the one a 时长记录 kept: it is opened whatever the work's current
/// 绑定, or even when its source is gone.
void openWork({
  required String sourceKey,
  required String id,
  required String title,
  String cover = '',
  ImageProvider? coverProvider,
  int? heroID,
  int? animeSubject,
  WorkSubject? subjects,
}) {
  var context = App.mainNavigatorKey?.currentContext;
  var route = animeSubject != null
      ? SubjectRoute(animeSubject)
      : (subjects ?? WorkSubject()).route(sourceKey, id);
  switch (route) {
    case SubjectRoute(:var subjectId, title: var subjectTitle):
      context?.to(
        () => BangumiSubjectPage(
          subjectId: subjectId,
          heroID: heroID,
          initialCover: cover,
          initialCoverProvider: coverProvider,
          initialTitle: subjectTitle ?? title,
        ),
      );
    case DetailsRoute():
      context?.to(
        () => ComicPage(
          id: id,
          sourceKey: sourceKey,
          cover: cover,
          coverProvider: coverProvider,
          title: title,
          heroID: heroID,
        ),
      );
  }
}
