import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/bangumi_ech.dart';

void main() {
  test(
    'failed plain fallback preserves ECH error and stack without backoff',
    () async {
      final policy = EchBackoff();
      final echError = StateError('ECH reset');
      final echStack = StackTrace.fromString('ECH attempt stack');
      var calls = 0;
      Object? actual;
      StackTrace? actualStack;
      try {
        await policy.tryPlain<int>(
          'lain.bgm.tv',
          echError: echError,
          echStack: echStack,
          isCancelled: (_) => false,
          plain: () async {
            calls++;
            throw StateError('plain reset');
          },
        );
      } catch (error, stack) {
        actual = error;
        actualStack = stack;
      }
      expect(identical(actual, echError), isTrue);
      expect(actualStack.toString(), echStack.toString());
      expect(policy.allows('lain.bgm.tv'), isTrue);
      expect(calls, 1);
    },
  );
  test(
    'plain response starts backoff even for an HTTP error response',
    () async {
      final policy = EchBackoff();
      final response = await policy.tryPlain<int>(
        'api.bgm.tv',
        echError: StateError('ECH timeout'),
        echStack: StackTrace.current,
        isCancelled: (_) => false,
        plain: () async => 403,
      );
      expect(response, 403);
      expect(policy.allows('api.bgm.tv'), isFalse);
    },
  );
  test(
    'cancelled fallback does not replace cancellation with ECH error',
    () async {
      final policy = EchBackoff();
      final cancel = StateError('cancel');
      Object? actual;
      try {
        await policy.tryPlain<int>(
          'api.bgm.tv',
          echError: StateError('ECH timeout'),
          echStack: StackTrace.current,
          isCancelled: (e) => identical(e, cancel),
          plain: () async => throw cancel,
        );
      } catch (error) {
        actual = error;
      }
      expect(identical(actual, cancel), isTrue);
      expect(policy.allows('api.bgm.tv'), isTrue);
    },
  );
  test('backoff requires plain response after ECH failure', () {
    var now = DateTime.utc(2026);
    final policy = EchBackoff(now: () => now);
    policy.recordFallback('lain.bgm.tv', plainHasResponse: false);
    expect(policy.allows('lain.bgm.tv'), isTrue);
    policy.recordFallback('lain.bgm.tv', plainHasResponse: true);
    expect(policy.allows('lain.bgm.tv'), isFalse);
    expect(policy.allows('api.bgm.tv'), isTrue);
    now = now.add(const Duration(minutes: 10));
    expect(policy.allows('lain.bgm.tv'), isTrue);
    policy.recordFallback('lain.bgm.tv', plainHasResponse: true);
    policy.recordFallback('lain.bgm.tv', plainHasResponse: false);
    expect(policy.allows('lain.bgm.tv'), isTrue);
  });
  test('retry eligibility protects writes, responses and cancellation', () {
    for (final method in [
      'GET',
      'get',
      'POST',
      'PATCH',
      'DELETE',
      'PUT',
      'HEAD',
    ]) {
      for (final beforeSend in [true, false]) {
        expect(
          canReplayEchRequest(
            method: method,
            hasResponse: true,
            cancelled: false,
            beforeSend: beforeSend,
          ),
          isFalse,
        );
        expect(
          canReplayEchRequest(
            method: method,
            hasResponse: false,
            cancelled: true,
            beforeSend: beforeSend,
          ),
          isFalse,
        );
        expect(
          canReplayEchRequest(
            method: method,
            hasResponse: false,
            cancelled: false,
            beforeSend: beforeSend,
          ),
          beforeSend || method.toUpperCase() == 'GET',
        );
      }
    }
  });
  test('IPv4 CIDR boundaries and all published Cloudflare ranges', () {
    for (final cidr in cloudflareIpv4Ranges) {
      expect(isCloudflareIpv4(cidr.split('/')[0]), isTrue, reason: cidr);
    }
    expect(ipv4InCidr('104.16.0.0', '104.16.0.0/13'), isTrue);
    expect(ipv4InCidr('104.23.255.255', '104.16.0.0/13'), isTrue);
    expect(ipv4InCidr('104.24.0.0', '104.16.0.0/13'), isFalse);
    expect(ipv4InCidr('104.15.255.255', '104.16.0.0/13'), isFalse);
    expect(ipv4InCidr('1.2.3.4', '0.0.0.0/0'), isTrue);
    expect(ipv4InCidr('1.2.3.4', '1.2.3.4/32'), isTrue);
    expect(ipv4InCidr('1.2.3.5', '1.2.3.4/32'), isFalse);
    for (final ip in [
      '127.0.0.1',
      '8.8.8.8',
      '::1',
      '104.26.8.256',
      '104.26.8.-1',
      '104.26.8',
      '104.26.8.23.evil',
      '',
    ]) {
      expect(isCloudflareIpv4(ip), isFalse, reason: ip);
    }
    expect(ipv4InCidr('1.2.3.4', '1.2.3.4/33'), isFalse);
    expect(ipv4InCidr('1.2.3.4', 'invalid'), isFalse);
  });
  test('DoH A parser ignores CNAME, AAAA, poisoned IPs and duplicates', () {
    final json = {
      'Status': 0,
      'Answer': [
        {'type': 5, 'data': 'bgm.tv'},
        {'type': 1, 'data': '104.26.8.23'},
        {'type': 1, 'data': '8.8.8.8'},
        {'type': 28, 'data': '2606:4700::1'},
        {'type': 1, 'data': ' 104.26.9.23 '},
        {'type': 1, 'data': '104.26.8.23'},
        {'type': 1, 'data': null},
      ],
    };
    expect(parseDohAddresses(json), ['104.26.8.23', '104.26.9.23']);
    expect(parseDohAddresses(jsonEncode(json)), ['104.26.8.23', '104.26.9.23']);
    for (final value in [
      null,
      'not json',
      {},
      {'Answer': []},
      {
        'Status': 2,
        'Answer': [
          {'type': 1, 'data': '104.26.8.23'},
        ],
      },
    ]) {
      expect(parseDohAddresses(value), []);
    }
  });
  test('IP selection falls back safely and respects user DNS overrides', () {
    expect(bangumiAddresses([]), [
      '104.26.8.23',
      '104.26.9.23',
      '172.67.73.67',
    ]);
    expect(bangumiAddresses(['8.8.8.8', 'invalid']), bangumiFallbackIps);
    expect(bangumiAddresses(['8.8.8.8', '104.26.9.23']), ['104.26.9.23']);
    expect(bangumiAddresses([], override: ['192.0.2.5']), ['192.0.2.5']);
    expect(bangumiAddresses([], override: ['::1']), ['::1']);
    expect(rotateEchAddresses(bangumiFallbackIps, 1), [
      '104.26.9.23',
      '172.67.73.67',
      '104.26.8.23',
    ]);
    expect(rotateEchAddresses(['192.0.2.5'], 1), ['192.0.2.5']);
  });
  test('DoH A cache shares flights and refreshes after 20 minutes', () async {
    var now = DateTime.utc(2026);
    var calls = 0;
    final pending = Completer<Object?>();
    final provider = EchConfigProvider(
      now: () => now,
      fetchJson: (uri) {
        calls++;
        expect(uri.queryParameters['name'], 'api.bgm.tv');
        expect(uri.queryParameters['type'], '1');
        return pending.future;
      },
    );
    final first = provider.addresses('api.bgm.tv', dohUrl: 'https://dns.test');
    final second = provider.addresses('api.bgm.tv', dohUrl: 'https://dns.test');
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    pending.complete({
      'Answer': [
        {'type': 1, 'data': '104.26.9.23'},
      ],
    });
    expect(await first, ['104.26.9.23']);
    expect(await second, ['104.26.9.23']);
    expect(await provider.addresses('api.bgm.tv', dohUrl: 'https://dns.test'), [
      '104.26.9.23',
    ]);
    expect(calls, 1);
    now = now.add(const Duration(minutes: 20));
    expect(await provider.addresses('api.bgm.tv', dohUrl: 'https://dns.test'), [
      '104.26.9.23',
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 2);
  });
  test('DoH A errors and poisoned answers use built-in IPs', () async {
    for (final json in [
      null,
      {
        'Answer': [
          {'type': 1, 'data': '8.8.8.8'},
        ],
      },
    ]) {
      final provider = EchConfigProvider(fetchJson: (_) async => json);
      expect(
        await provider.addresses('bgm.tv', dohUrl: 'https://dns.test'),
        bangumiFallbackIps,
      );
    }
    final provider = EchConfigProvider(
      fetchJson: (_) async => throw StateError('offline'),
    );
    expect(
      await provider.addresses('bgm.tv', dohUrl: 'https://dns.test'),
      bangumiFallbackIps,
    );
  });
  test(
    'host limiter allows two, queues FIFO and releases idempotently',
    () async {
      final limiter = EchHostLimiter();
      final first = await limiter.acquire('lain.bgm.tv');
      final second = await limiter.acquire('lain.bgm.tv');
      final other = await limiter.acquire('api.bgm.tv');
      final order = <int>[];
      final third = limiter.acquire('lain.bgm.tv').then((permit) {
        order.add(3);
        return permit;
      });
      final fourth = limiter.acquire('lain.bgm.tv').then((permit) {
        order.add(4);
        return permit;
      });
      await Future<void>.delayed(Duration.zero);
      expect(order, []);
      first.release();
      first.release();
      final thirdPermit = await third;
      expect(order, [3]);
      second.release();
      final fourthPermit = await fourth;
      expect(order, [3, 4]);
      thirdPermit.release();
      fourthPermit.release();
      other.release();
      final again = await limiter.acquire('lain.bgm.tv');
      again.release();
    },
  );
  test('success logs throttle per host; failure logs never throttle', () {
    var now = DateTime.utc(2026);
    final throttle = EchLogThrottle(now: () => now);
    expect(throttle.allows('lain.bgm.tv', failure: false), isTrue);
    expect(throttle.allows('lain.bgm.tv', failure: false), isFalse);
    expect(throttle.allows('lain.bgm.tv', failure: true), isTrue);
    expect(throttle.allows('lain.bgm.tv', failure: true), isTrue);
    expect(throttle.allows('api.bgm.tv', failure: false), isTrue);
    now = now.add(const Duration(minutes: 1));
    expect(throttle.allows('lain.bgm.tv', failure: false), isTrue);
  });
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
      policy.recordFallback('api.bgm.tv', plainHasResponse: true);
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
