import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/proxy_environment.dart';

void main() {
  group('proxyFromEnvironment', () {
    test('uses the first supported non-empty variable in priority order', () {
      const keys = [
        'https_proxy', 'HTTPS_PROXY', 'http_proxy',
        'HTTP_PROXY', 'all_proxy', 'ALL_PROXY',
      ];
      for (var first = 0; first < keys.length; first++) {
        final env = <String, String>{};
        // Reverse insertion order to verify priority is independent of the map.
        for (var i = keys.length - 1; i >= first; i--) {
          env[keys[i]] = 'proxy$i.example:7890';
        }
        expect(proxyFromEnvironment(env), 'proxy$first.example:7890');
      }
    });

    test('accepts schemes, bare authorities, trailing slash and whitespace', () {
      for (final value in [
        'http://127.0.0.1:7890',
        '127.0.0.1:7890',
        '  http://127.0.0.1:7890/  ',
      ]) {
        expect(proxyFromEnvironment({'https_proxy': value}), '127.0.0.1:7890');
      }
      expect(proxyFromEnvironment({'HTTP_PROXY': 'http://proxy.example'}),
          'proxy.example:80');
      expect(proxyFromEnvironment({'ALL_PROXY': 'http://[::1]:7890/'}),
          '[::1]:7890');
    });

    test('drops credentials for the shared HTTP proxy consumers', () {
      for (final value in [
        'http://user:pass@host:7890/',
        'user:p%40ss@host:7890',
      ]) {
        expect(proxyFromEnvironment({'https_proxy': value}), 'host:7890');
      }
    });

    test('ignores absent, empty and whitespace values', () {
      expect(proxyFromEnvironment({}), isNull);
      expect(proxyFromEnvironment({'https_proxy': '', 'HTTP_PROXY': '  '}),
          isNull);
      expect(proxyFromEnvironment({
        'https_proxy': ' ', 'HTTPS_PROXY': '', 'http_proxy': 'host:7890',
      }), 'host:7890');
    });

    test('skips SOCKS and reports a diagnostic without exposing credentials', () {
      final result = parseProxyEnvironment({
        'https_proxy': 'socks5://user:secret@host:1080',
        'HTTPS_PROXY': 'socks5h://host:1080',
        'http_proxy': 'http://fallback:7890',
      });
      expect(result.proxy, 'fallback:7890');
      expect(result.skippedSocks, isTrue);
      expect(proxyFromEnvironment({'ALL_PROXY': 'socks5://host:1080'}), isNull);
      expect(parseProxyEnvironment({
        'https_proxy': 'host:7890', 'ALL_PROXY': 'socks5://host:1080',
      }).skippedSocks, isFalse);
    });

    test('skips malformed and unsupported proxy URLs', () {
      for (final value in [
        'http://', 'http://host:0', 'http://host:65536',
        'http://host:bad', 'http://host:7890/path',
        'http://host:7890?query', 'http://host:7890#fragment',
        'ftp://host:7890', 'https://host:7890',
      ]) {
        expect(proxyFromEnvironment({
          'https_proxy': value, 'http_proxy': 'fallback:7890',
        }), 'fallback:7890', reason: value);
      }
    });
  });

  group('bypassesProxy', () {
    test('always bypasses loopback hosts', () {
      for (final host in ['localhost', 'LOCALHOST.', '127.0.0.1', '::1', '[::1]']) {
        expect(bypassesProxy(host, null), isTrue, reason: host);
      }
      expect(bypassesProxy('localhost.example', null), isFalse);
    });

    test('matches comma separated exact hosts case insensitively', () {
      const rules = ' , example.com, INTERNAL.example ,192.168.1.2,, ';
      for (final host in ['example.com', 'internal.EXAMPLE.', '192.168.1.2']) {
        expect(bypassesProxy(host, rules), isTrue);
      }
      expect(bypassesProxy('sub.example.com', rules), isFalse);
      expect(bypassesProxy('notexample.com', rules), isFalse);
    });

    test('matches suffixes on domain boundaries', () {
      for (final rule in ['.example.com', '*.example.com']) {
        for (final host in ['example.com', 'sub.example.com', 'a.b.example.com']) {
          expect(bypassesProxy(host, rule), isTrue);
        }
        for (final host in ['badexample.com', 'example.com.evil', 'other.com']) {
          expect(bypassesProxy(host, rule), isFalse);
        }
      }
    });

    test('supports wildcard and empty rules', () {
      expect(bypassesProxy('anything.example', ' , * , '), isTrue);
      for (final rules in [null, '', ' , , ', '.', '*.']) {
        expect(bypassesProxy('remote.example', rules), isFalse);
      }
    });

    test('selects lowercase no_proxy before uppercase, even when empty', () {
      expect(noProxyFromEnvironment({}), isNull);
      expect(noProxyFromEnvironment({'NO_PROXY': 'upper.example'}),
          'upper.example');
      expect(noProxyFromEnvironment({
        'no_proxy': 'lower.example', 'NO_PROXY': 'upper.example',
      }), 'lower.example');
      expect(noProxyFromEnvironment({'no_proxy': '', 'NO_PROXY': '*'}), '');
    });
  });
}
