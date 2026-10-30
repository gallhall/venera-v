import 'package:venera/utils/translations.dart';

/// A loaded item has no playable episodes, including after release filtering.
class AnimekoEpisodesUnavailable implements Exception {
  @override
  String toString() => 'No episodes found'.tl;
}
