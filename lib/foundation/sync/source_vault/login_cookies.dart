import 'dart:convert';
import 'dart:io';

const sourceLoginCookies = '_veneraSyncLoginCookies';
const sourceLoginInputs = '_veneraSyncLoginInputs';
const sourceLoginNeedsValidation = '_veneraSyncLoginNeedsValidation';

/// The old .venera archive retains its previous contents and schema. The
/// additional credential copies collected for encrypted sync go elsewhere.
String? legacySourceData(String data) {
  const privateFields = [
    sourceLoginCookies,
    sourceLoginInputs,
    sourceLoginNeedsValidation,
  ];
  if (!privateFields.any((field) => data.contains('"$field"'))) return null;
  try {
    final decoded = jsonDecode(data) as Map;
    for (final field in privateFields) {
      decoded.remove(field);
    }
    return jsonEncode(decoded);
  } catch (_) {
    // FormatException may include credential values in its source snippet.
    throw StateError('A source data file could not be safely backed up.');
  }
}

/// Only cookies supplied by a successful source login are eligible. In
/// particular, do not export the shared CookieJar or challenge cookies.
List<Map<String, Object?>> captureSourceLoginCookies(
  Uri origin,
  Iterable<Cookie> cookies,
) {
  if (origin.scheme != 'https' || origin.host.isEmpty) return [];
  final result = <Map<String, Object?>>[];
  for (final cookie in cookies) {
    final domain = cookie.domain ?? origin.host;
    if (domain.replaceFirst(RegExp(r'^\.'), '') != origin.host ||
        !canSyncLoginCookie(cookie.name)) {
      continue;
    }
    result.add({
      'name': cookie.name,
      'value': cookie.value,
      'domain': domain,
      'path': cookie.path ?? '/',
      'expires': cookie.expires?.millisecondsSinceEpoch,
      'secure': cookie.secure,
      'httpOnly': cookie.httpOnly,
    });
  }
  return result;
}

bool canSyncLoginCookie(String name) {
  final lower = name.toLowerCase();
  return lower != 'cf_clearance' &&
      !lower.startsWith('__cf') &&
      !lower.startsWith('cf_chl_');
}
