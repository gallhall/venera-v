import 'package:yaml/yaml.dart';

/// pubspec.yaml of master, through jsDelivr.
///
/// CI writes a version into master only after the installers of its release
/// are uploaded, so the version here can always be installed.
const latestPubspecUrl =
    "https://cdn.jsdelivr.net/gh/gallhall/venera-v@master/pubspec.yaml";

/// Whether [pubspec], the content of pubspec.yaml, has a newer version than
/// [currentVersion].
bool hasNewerVersion(String pubspec, String currentVersion) {
  var version = loadYaml(pubspec)?["version"];
  if (version is! String) {
    return false;
  }
  return compareVersion(version.split("+")[0], currentVersion);
}

/// return true if version1 > version2
bool compareVersion(String version1, String version2) {
  var v1 = version1.split(".");
  var v2 = version2.split(".");
  for (var i = 0; i < v1.length || i < v2.length; i++) {
    var a = i < v1.length ? int.tryParse(v1[i]) ?? 0 : 0;
    var b = i < v2.length ? int.tryParse(v2[i]) ?? 0 : 0;
    if (a > b) {
      return true;
    }
    if (a < b) {
      return false;
    }
  }
  return false;
}
