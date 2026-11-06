const _proxyVariables = [
  'https_proxy',
  'HTTPS_PROXY',
  'http_proxy',
  'HTTP_PROXY',
  'all_proxy',
  'ALL_PROXY',
];

/// An HTTP proxy authority suitable for rhttp, mpv and `HttpClient.findProxy`.
/// Credentials are discarded: findProxy's PROXY directive cannot carry them.
String? proxyFromEnvironment(Map<String, String> env) =>
    parseProxyEnvironment(env).proxy;

/// Keeps diagnostics separate from parsing so callers can log without secrets.
({String? proxy, bool skippedSocks}) parseProxyEnvironment(
    Map<String, String> env) {
  var skippedSocks = false;
  for (final key in _proxyVariables) {
    final value = env[key]?.trim() ?? '';
    if (value.isEmpty) {
      continue;
    }
    final uri = Uri.tryParse(value.contains('://') ? value : 'http://$value');
    if (uri == null) {
      continue;
    }
    if (uri.scheme.toLowerCase().startsWith('socks')) {
      skippedSocks = true;
      continue;
    }
    // The shared findProxy/mpv path supports HTTP proxies, not TLS to a proxy.
    if (uri.scheme != 'http' || uri.host.isEmpty ||
        uri.hasQuery || uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      continue;
    }
    try {
      final port = uri.port;
      if (port < 1 || port > 65535) {
        continue;
      }
      var host = uri.host;
      if (host.contains(':') && !host.startsWith('[')) {
        host = '[$host]';
      }
      return (proxy: '$host:$port', skippedSocks: skippedSocks);
    } on FormatException {
      continue;
    }
  }
  return (proxy: null, skippedSocks: skippedSocks);
}

/// Lowercase takes precedence, including an explicitly empty value.
String? noProxyFromEnvironment(Map<String, String> env) =>
    env['no_proxy'] ?? env['NO_PROXY'];

/// Matches host names, not URLs or CIDR ranges. Bare names match exactly;
/// `.example.org` and `*.example.org` also match subdomains and the base name.
bool bypassesProxy(String host, String? noProxy) {
  String normalize(String value) {
    var result = value.trim().toLowerCase();
    if (result.startsWith('[') && result.endsWith(']')) {
      result = result.substring(1, result.length - 1);
    }
    if (result.endsWith('.')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  final target = normalize(host);
  if (target == 'localhost' || target == '127.0.0.1' || target == '::1') {
    return true;
  }
  for (final entry in (noProxy ?? '').split(',')) {
    // Checked before normalizing, which would turn "*." into "*".
    if (entry.trim() == '*') {
      return true;
    }
    var pattern = normalize(entry);
    if (pattern == '*') {
      continue;
    }
    final suffix = pattern.startsWith('.') || pattern.startsWith('*.');
    if (suffix) {
      pattern = pattern.substring(pattern.startsWith('*.') ? 2 : 1);
    }
    if (pattern.isEmpty) {
      continue;
    }
    if (target == pattern || (suffix && target.endsWith('.$pattern'))) {
      return true;
    }
  }
  return false;
}
