import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/bangumi_ech.dart';

void main() {
  // Structurally framed ECHConfigList; cryptographic validation belongs to Rust.
  final bytes = [0, 4, 0xfe, 0x0d, 0, 0];
  final encoded = base64Encode(bytes);
  Map<String, Object> answer(String data, {int type = 65}) => {
    'type': type,
    'data': data,
  };

  test('HTTPS RR ech param among hints and ALPN, quoted or unquoted', () {
    for (final value in [encoded, '"$encoded"']) {
      expect(
        parseDohEchConfig({
          'Status': 0,
          'Answer': [
            answer('1 . alpn=h2 ipv4hint=1.2.3.4 ech=$value ipv6hint=::1'),
          ],
        }),
        bytes,
      );
    }
  });
  test(
    'multiple answers skip other types, malformed config and absent ech',
    () {
      expect(
        parseDohEchConfig(
          jsonEncode({
            'Answer': [
              answer('ech=$encoded', type: 1),
              answer('1 . alpn=h2'),
              answer('1 . ech=bad!'),
              answer('1 . ech=$encoded'),
            ],
          }),
        ),
        bytes,
      );
      for (final json in [
        null,
        'bad json',
        {},
        {'Answer': []},
        {
          'Answer': [answer('1 . alpn=h2')],
        },
        {
          'Status': 2,
          'Answer': [answer('ech=$encoded')],
        },
        {
          'Answer': [
            {'type': 65, 'data': null},
          ],
        },
      ]) {
        expect(parseDohEchConfig(json), isNull);
      }
    },
  );
  test(
    'base64 accepts whitespace and missing padding, rejects bad framing',
    () {
      expect(decodeEchConfig(' \n$encoded\n'), bytes);
      final padded = base64Encode([0, 5, 0xfe, 0x0d, 0, 1, 1]);
      expect(decodeEchConfig(padded.replaceAll('=', '')), [
        0,
        5,
        0xfe,
        0x0d,
        0,
        1,
        1,
      ]);
      for (final value in [
        '',
        'bad!',
        'AAAA',
        base64Encode([0, 1, 0, 0, 0, 0]),
      ]) {
        expect(decodeEchConfig(value), isNull);
      }
    },
  );
  test('host matching is suffix bounded and case insensitive', () {
    for (final host in [
      'api.bgm.tv',
      'next.bgm.tv',
      'lain.bgm.tv',
      'bgm.tv',
      'chii.in',
      'A.CHII.IN.',
    ]) {
      expect(isBangumiHost(host), isTrue, reason: host);
    }
    for (final host in [
      'evilbgm.tv',
      'bgm.tv.evil.test',
      'chii.in.evil',
      'cloudflare-ech.com',
      'proxy.test',
      '',
    ]) {
      expect(isBangumiHost(host), isFalse, reason: host);
    }
  });
  test('rewrite only lain images, preserving path, escapes and query', () {
    const original = 'https://lain.bgm.tv/pic/cover/a%20b.jpg?x=1&y=2';
    expect(rewriteBangumiImageUrl(original, ''), original);
    expect(
      rewriteBangumiImageUrl(original, 'https://proxy.test/images/'),
      'https://proxy.test/images/pic/cover/a%20b.jpg?x=1&y=2',
    );
    expect(
      rewriteBangumiImageUrl('//lain.bgm.tv/a.jpg', 'https://proxy.test'),
      'https://proxy.test/a.jpg',
    );
    expect(
      rewriteBangumiImageUrl('https://api.bgm.tv/a.jpg', 'https://proxy.test'),
      'https://api.bgm.tv/a.jpg',
    );
    expect(rewriteBangumiImageUrl(original, 'invalid'), original);
    expect(
      rewriteBangumiImageUrl(original, 'https://user:password@proxy.test'),
      original,
    );
  });
  test(
    'fallback excludes HTTP responses and cancellation; backoff expires',
    () {
      var now = DateTime.utc(2026);
      final policy = EchBackoff(now: () => now);
      expect(
        EchBackoff.shouldFallback(hasResponse: false, cancelled: false),
        isTrue,
      );
      expect(
        EchBackoff.shouldFallback(hasResponse: true, cancelled: false),
        isFalse,
      );
      expect(
        EchBackoff.shouldFallback(hasResponse: false, cancelled: true),
        isFalse,
      );
      policy.failed('api.bgm.tv');
      expect(policy.allows('api.bgm.tv'), isFalse);
      expect(policy.allows('lain.bgm.tv'), isTrue);
      now = now.add(const Duration(minutes: 10));
      expect(policy.allows('api.bgm.tv'), isTrue);
    },
  );
  test(
    'provider target then shared fallback; cache and background refresh',
    () async {
      var now = DateTime.utc(2026);
      final names = <String>[];
      Completer<Object?>? refresh;
      final provider = EchConfigProvider(
        now: () => now,
        fetchJson: (uri) async {
          names.add(uri.queryParameters['name']!);
          if (refresh != null) return refresh.future;
          return {
            'Answer': [
              answer(
                uri.queryParameters['name'] == 'cloudflare-ech.com'
                    ? '1 . ech=$encoded'
                    : '1 . alpn=h2',
              ),
            ],
          };
        },
      );
      Future<dynamic> get() => provider.get(
        'api.bgm.tv',
        mode: 'doh',
        dohUrl: 'https://dns.test/resolve?extra=1',
        manual: '',
      );
      expect(await get(), bytes);
      expect(names, ['api.bgm.tv', 'cloudflare-ech.com']);
      expect(await get(), bytes);
      expect(names.length, 2);
      now = now.add(const Duration(minutes: 20));
      refresh = Completer();
      expect(await get(), isNull); // Must not wait for refresh.
      refresh.complete({
        'Answer': [answer('1 . ech=$encoded')],
      });
      await Future<void>.delayed(Duration.zero);
      expect(await get(), bytes);
    },
  );
  test(
    'concurrent first requests share a flight, queries serialize across hosts',
    () async {
      final pending = Completer<Object?>();
      var calls = 0;
      final provider = EchConfigProvider(
        fetchJson: (_) {
          calls++;
          return pending.future;
        },
      );
      Future<dynamic> get(String host) => provider.get(
        host,
        mode: 'doh',
        dohUrl: 'https://dns.test',
        manual: '',
      );
      final first = get('api.bgm.tv');
      final duplicate = get('api.bgm.tv');
      final image = get('lain.bgm.tv');
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      pending.complete({
        'Answer': [answer('1 . ech=$encoded')],
      });
      expect(await first, bytes);
      expect(await duplicate, bytes);
      expect(await image, bytes);
      expect(calls, 2);
    },
  );
  test(
    'off/manual settings never query DoH; invalid manual falls back',
    () async {
      final provider = EchConfigProvider(
        fetchJson: (_) => throw StateError('unexpected query'),
      );
      expect(
        await provider.get('bgm.tv', mode: 'off', dohUrl: '', manual: encoded),
        isNull,
      );
      expect(
        await provider.get(
          'bgm.tv',
          mode: 'manual',
          dohUrl: '',
          manual: encoded,
        ),
        bytes,
      );
      expect(
        await provider.get(
          'bgm.tv',
          mode: 'manual',
          dohUrl: '',
          manual: 'invalid',
        ),
        isNull,
      );
    },
  );
  test('config errors and first wait timeout return normal TLS', () async {
    final failed = EchConfigProvider(
      fetchJson: (_) async => throw StateError('offline'),
    );
    expect(
      await failed.get(
        'bgm.tv',
        mode: 'doh',
        dohUrl: 'https://dns.test',
        manual: '',
      ),
      isNull,
    );
    final pending = Completer<Object?>();
    final slow = EchConfigProvider(
      firstWait: const Duration(milliseconds: 1),
      fetchJson: (_) => pending.future,
    );
    expect(
      await slow.get(
        'bgm.tv',
        mode: 'doh',
        dohUrl: 'https://dns.test',
        manual: '',
      ),
      isNull,
    );
    pending.complete({
      'Answer': [answer('ech=$encoded')],
    });
    await Future<void>.delayed(Duration.zero);
    expect(
      await slow.get(
        'bgm.tv',
        mode: 'doh',
        dohUrl: 'https://dns.test',
        manual: '',
      ),
      bytes,
    );
  });
}
