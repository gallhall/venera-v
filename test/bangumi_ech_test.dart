import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/bangumi_ech.dart';

Uint8List _hex(String value) => Uint8List.fromList([
  for (var i = 0; i < value.length; i += 2)
    int.parse(value.substring(i, i + 2), radix: 16),
]);

const _httpsReply =
    '000081800001000100000000036170690362676d0274760000410001'
    'c00c004100010000012c005d000100000100030268320004000467fc733100050047'
    '0045fe0d0041a5002000204dfce7524bef8da72d1e509cbf7069cb99edb24b123800619614297bbe3240770'
    '004000100010012636c6f7564666c6172652d6563682e636f6d0000';
const _aReply =
    '000081800001000200000000036170690362676d0274760000010001'
    'c00c000500010000012c00060363646ec010c028000100010000012c0004681a0817';

void main() {
  test('ECH host gate preserves Bangumi hosts and adds exact BT hosts', () {
    final hosts = EchHosts(read: () => null, write: (_) {});
    for (final host in ['bgm.tv', 'api.bgm.tv', 'lain.bgm.tv', 'chii.in',
      'www.chii.in', ...EchHosts.builtIn]) {
      expect(hosts.contains(host), isTrue, reason: host);
      expect(hosts.contains(host.toUpperCase()), isTrue, reason: host);
      expect(hosts.contains(host, mode: 'off'), isFalse, reason: host);
    }
    for (final host in ['acg.rip', 'nyaa.si', 'mikanime.tv',
      'share.dmhy.org.evil.test', 'other.dmhy.org']) {
      expect(hosts.contains(host), isFalse, reason: host);
    }
    expect(isBangumiHost('api.bgm.tv'), isTrue);
    expect(isBangumiHost('www.chii.in.'), isTrue);
    expect(isBangumiHost('share.dmhy.org'), isFalse);
    expect(isBangumiHost('bangumi.tv'), isFalse);
  });

  test('learn only an answering ECH route, expire after 30 days, bound to 50', () async {
    var time = DateTime.utc(2026, 10, 30);
    Object? stored;
    var writes = 0;
    final hosts = EchHosts(read: () => stored, write: (value) {
      stored = value;
      writes++;
    }, now: () => time);
    bool ok(int status) => status < 400;
    await expectLater(hosts.learnFrom<int>('failed.test', () async {
      throw TimeoutException('ECH failed');
    }, answered: ok), throwsA(isA<TimeoutException>()));
    expect(writes, 0);
    expect(hosts.contains('failed.test'), isFalse);
    // Cloudflare answering for a host it does not serve.
    expect(await hosts.learnFrom('acg.rip', () async => 403, answered: ok), 403);
    expect(hosts.contains('acg.rip'), isFalse);
    expect(await hosts.learnFrom('Learned.test.', () async => 200, answered: ok),
      200);
    expect(hosts.contains('learned.test'), isTrue);
    expect(hosts.contains('learned.test', mode: 'off'), isFalse);
    final restored = EchHosts(read: () => jsonDecode(jsonEncode(stored)),
      write: (_) {}, now: () => time);
    expect(restored.contains('learned.test'), isTrue);
    time = time.add(const Duration(days: 30));
    expect(hosts.contains('learned.test'), isFalse);
    for (var i = 0; i < 51; i++) {
      await hosts.learnFrom('$i.test', () async => 200, answered: ok);
      time = time.add(const Duration(seconds: 1));
    }
    expect(stored, hasLength(50));
    expect(hosts.contains('0.test'), isFalse);
    expect(hosts.contains('50.test'), isTrue);
    hosts.record('never-answered.test', echAnswered: false);
    expect(hosts.contains('never-answered.test'), isFalse);
  });

  test(
    'late rejected fetch cannot overwrite a learned server retry config',
    () async {
      final pending = Completer<Object?>();
      var queries = 0;
      final provider = EchConfigProvider(
        firstWait: const Duration(milliseconds: 1),
        fetchJson: (_) {
          queries++;
          return pending.future;
        },
      );
      final old = decodeEchConfig(builtInEchConfig)!;
      final fresh = Uint8List.fromList([0, 4, 0xfe, 0x0d, 0, 0]);
      expect(
        await provider.get(
          'api.bgm.tv',
          mode: 'doh',
          dohUrl: 'https://dns.test',
          manual: '',
        ),
        old,
      );
      expect(
        await provider.recover(
          'api.bgm.tv',
          old,
          retryConfigs: fresh,
          dohUrl: 'https://dns.test',
        ),
        fresh,
      );
      pending.complete({
        'Answer': [
          {'type': 65, 'data': 'ech=$builtInEchConfig'},
        ],
      });
      await Future<void>.delayed(Duration.zero);
      expect(
        await provider.get(
          'api.bgm.tv',
          mode: 'doh',
          dohUrl: 'https://dns.test',
          manual: '',
        ),
        fresh,
      );
      // A parallel connection that rejected the same old config must retain it.
      expect(
        await provider.recover('api.bgm.tv', old, dohUrl: 'https://dns.test'),
        fresh,
      );
      expect(queries, 1);
    },
  );
  test('wire query fixtures use ID zero, RD, and unpadded base64url', () {
    final https = _hex(
      '000001000001000000000000036170690362676d0274760000410001',
    );
    final a = _hex('000001000001000000000000036170690362676d0274760000010001');
    expect(buildDohQuery('API.BGM.TV.', 65), https);
    expect(buildDohQuery('api.bgm.tv', 1), a);
    expect(
      base64Url.decode(base64.normalize(encodeDohQuery('api.bgm.tv', 65))),
      https,
    );
    expect(encodeDohQuery('api.bgm.tv', 65).contains('='), isFalse);
  });
  test(
    'wire HTTPS decodes key 5 among other SvcParams and compressed owner',
    () {
      final json = decodeDohAnswer(
        _hex(_httpsReply),
        host: 'api.bgm.tv',
        type: 65,
      );
      expect(parseDohEchConfig(json), decodeEchConfig(builtInEchConfig));
      expect(
        parseDohAddresses(json),
        [],
      ); // Poisoned ipv4hint is never an A RR.
    },
  );
  test('wire A decodes CNAME and nested compression pointers', () {
    final json = decodeDohAnswer(_hex(_aReply), host: 'api.bgm.tv', type: 1);
    expect(parseDohAddresses(json), ['104.26.8.23']);
    expect((json['Answer'] as List).first['name'], 'cdn.bgm.tv');
  });
  test(
    'wire decoder rejects truncation, bad pointers and question mismatch',
    () {
      final loop = _hex(_httpsReply)..[29] = 28;
      final truncated = _hex(_httpsReply)..[2] = 0x83;
      for (final bytes in [
        <int>[],
        _hex(_httpsReply).sublist(0, 40),
        loop,
        truncated,
      ]) {
        var rejected = false;
        try {
          decodeDohAnswer(bytes, host: 'api.bgm.tv', type: 65);
        } on FormatException {
          rejected = true;
        }
        expect(rejected, isTrue);
      }
      var mismatch = false;
      try {
        decodeDohAnswer(_hex(_httpsReply), host: 'chii.in', type: 65);
      } on FormatException {
        mismatch = true;
      }
      expect(mismatch, isTrue);
    },
  );
  test('DoH transport retries and endpoint order are deterministic', () async {
    final events = <String>[], delays = <int>[];
    var targetCalls = 0;
    final sample = base64Encode([0, 4, 0xfe, 0x0d, 0, 0]);
    final provider = EchConfigProvider(
      delay: (duration) async {
        delays.add(duration.inMilliseconds);
      },
      endpoints: const [
        DohEndpoint('https://second.test/resolve', wire: false),
      ],
      fetchJson: (uri) async {
        final host = uri.queryParameters['name'];
        events.add('${uri.host} $host');
        if (uri.host == 'first.test') {
          if (host == 'api.bgm.tv' && ++targetCalls > 2) return {'Answer': []};
          throw StateError('reset');
        }
        return {
          'Answer': [
            {'type': 65, 'data': '1 . ech=$sample'},
          ],
        };
      },
    );
    expect(
      await provider.get(
        'api.bgm.tv',
        mode: 'doh',
        dohUrl: 'https://first.test/resolve',
        manual: '',
      ),
      decodeEchConfig(sample),
    );
    expect(events, [
      'first.test api.bgm.tv',
      'first.test api.bgm.tv',
      'first.test api.bgm.tv',
      'first.test cloudflare-ech.com',
      'first.test cloudflare-ech.com',
      'first.test cloudflare-ech.com',
      'second.test api.bgm.tv',
    ]);
    expect(delays, [300, 1000, 300, 1000]);
  });
  test('JSON then wire endpoint fallback works for both HTTPS and A', () async {
    for (final type in [65, 1]) {
      final events = <String>[];
      Object? persisted;
      final provider = EchConfigProvider(
        endpoints: const [DohEndpoint('https://wire.test/dns-query')],
        writePersisted: (value) {
          persisted = value;
        },
        fetchJson: (uri) async {
          events.add('json ${uri.queryParameters['name']}');
          return {'Answer': []};
        },
        fetchWire: (uri) async {
          events.add('wire ${uri.host}');
          expect(
            base64Url.decode(base64.normalize(uri.queryParameters['dns']!)),
            buildDohQuery('api.bgm.tv', type),
          );
          return _hex(type == 65 ? _httpsReply : _aReply);
        },
      );
      if (type == 65) {
        expect(
          await provider.get(
            'api.bgm.tv',
            mode: 'doh',
            dohUrl: 'https://json.test',
            manual: '',
          ),
          decodeEchConfig(builtInEchConfig),
        );
        expect(
          persisted is Map,
          isTrue,
        ); // Was fetched, not the bootstrap fallback.
        expect(events, [
          'json api.bgm.tv',
          'json cloudflare-ech.com',
          'wire wire.test',
        ]);
      } else {
        expect(
          await provider.addresses('api.bgm.tv', dohUrl: 'https://json.test'),
          ['104.26.8.23'],
        );
        expect(events, ['json api.bgm.tv', 'wire wire.test']);
      }
    }
  });
  test('negative cache retries at 5s then grows to a 60s cap', () async {
    var now = DateTime.utc(2026), calls = 0;
    final provider = EchConfigProvider(
      now: () => now,
      endpoints: const [],
      fetchJson: (_) async {
        calls++;
        return {'Answer': []};
      },
    );
    Future<Uint8List?> get() => provider.get(
      'api.bgm.tv',
      mode: 'doh',
      dohUrl: 'https://dns.test',
      manual: '',
    );
    expect(await get(), decodeEchConfig(builtInEchConfig));
    expect(calls, 2);
    for (final seconds in [5, 10, 20, 40, 60, 60]) {
      final before = calls;
      now = now.add(Duration(seconds: seconds - 1));
      await get();
      expect(calls, before);
      now = now.add(const Duration(seconds: 1));
      await get();
      expect(calls, before + 2);
    }
  });
  test(
    'callers arriving during a timed-out flight still wait for it',
    () async {
      final pending = Completer<Object?>();
      var calls = 0;
      final provider = EchConfigProvider(
        firstWait: const Duration(milliseconds: 10),
        fetchJson: (_) {
          calls++;
          return pending.future;
        },
      );
      Future<Uint8List?> get() => provider.get(
        'api.bgm.tv',
        mode: 'doh',
        dohUrl: 'https://dns.test',
        manual: '',
      );
      expect(await get(), decodeEchConfig(builtInEchConfig));
      var completed = false;
      final second = get().then((value) {
        completed = true;
        return value;
      });
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      final bytes = [0, 4, 0xfe, 0x0d, 0, 0];
      pending.complete({
        'Answer': [
          {'type': 65, 'data': 'ech=${base64Encode(bytes)}'},
        ],
      });
      expect(await second, bytes);
      expect(calls, 1);
    },
  );
  test(
    'persistence round-trip uses fresh config without a DNS request',
    () async {
      var now = DateTime.utc(2026);
      Object? persisted;
      final bytes = [0, 4, 0xfe, 0x0d, 0, 0];
      final provider = EchConfigProvider(
        now: () => now,
        writePersisted: (value) {
          persisted = jsonDecode(jsonEncode(value));
        },
        fetchJson: (_) async => {
          'Answer': [
            {'type': 65, 'data': 'ech=${base64Encode(bytes)}'},
          ],
        },
      );
      await provider.get(
        'api.bgm.tv',
        mode: 'doh',
        dohUrl: 'https://dns.test',
        manual: '',
      );
      final stored = ((persisted as Map)['configs'] as Map)['api.bgm.tv'];
      expect(EchStoredConfig.fromJson(stored, now)!.bytes, bytes);
      now = now.add(const Duration(minutes: 10));
      var calls = 0;
      final cold = EchConfigProvider(
        now: () => now,
        readPersisted: () => persisted,
        fetchJson: (_) async {
          calls++;
          throw StateError('must not query');
        },
      );
      expect(
        await cold.get(
          'api.bgm.tv',
          mode: 'doh',
          dohUrl: 'https://dns.test',
          manual: '',
        ),
        bytes,
      );
      expect(calls, 0);
      expect(
        EchStoredConfig.fromJson({'config': 'bad', 'fetchedAt': 0}, now),
        isNull,
      );
      expect(
        EchStoredConfig.fromJson({
          'config': base64Encode(bytes),
          'fetchedAt': -1,
        }, now),
        isNull,
      );
    },
  );
  test(
    'stale persisted config is immediate while refresh runs in background',
    () async {
      final now = DateTime.utc(2026);
      final bytes = Uint8List.fromList([0, 4, 0xfe, 0x0d, 0, 0]);
      final pending = Completer<Object?>();
      var calls = 0;
      final provider = EchConfigProvider(
        now: () => now,
        readPersisted: () => {
          'version': 1,
          'configs': {
            'api.bgm.tv': EchStoredConfig(
              bytes,
              now.subtract(const Duration(minutes: 21)),
            ).toJson(),
          },
        },
        fetchJson: (_) {
          calls++;
          return pending.future;
        },
      );
      expect(
        await provider.get(
          'api.bgm.tv',
          mode: 'doh',
          dohUrl: 'https://dns.test',
          manual: '',
        ),
        bytes,
      );
      expect(calls, 1);
      pending.complete({
        'Answer': [
          {'type': 65, 'data': 'ech=${base64Encode(bytes)}'},
        ],
      });
      await Future<void>.delayed(Duration.zero);
    },
  );
  test(
    'built-in fallback is usable but never persisted as a fresh answer',
    () async {
      var writes = 0;
      final logs = <String>[];
      final provider = EchConfigProvider(
        endpoints: const [],
        log: logs.add,
        writePersisted: (_) {
          writes++;
        },
        fetchJson: (_) async => {'Answer': []},
      );
      final config = await provider.get(
        'api.bgm.tv',
        mode: 'doh',
        dohUrl: 'https://dns.test',
        manual: '',
      );
      expect(config, decodeEchConfig(builtInEchConfig));
      expect(config!.length, 71);
      expect(writes, 0);
      expect(
        logs.any(
          (line) =>
              line.contains('built-in') && line.contains('possibly stale'),
        ),
        isTrue,
      );
    },
  );
  test(
    'server retry configs replace and invalidate persisted shared config',
    () async {
      final now = DateTime.utc(2026), old = decodeEchConfig(builtInEchConfig)!;
      final fresh = Uint8List.fromList([0, 4, 0xfe, 0x0d, 0, 0]);
      Object? stored = {
        'version': 1,
        'configs': {'cloudflare-ech.com': EchStoredConfig(old, now).toJson()},
      };
      var queries = 0;
      final provider = EchConfigProvider(
        now: () => now,
        readPersisted: () => stored,
        writePersisted: (value) {
          stored = value;
        },
        fetchJson: (_) async {
          queries++;
          return {'Answer': []};
        },
      );
      expect(
        await provider.get(
          'api.bgm.tv',
          mode: 'doh',
          dohUrl: 'https://dns.test',
          manual: '',
        ),
        old,
      );
      expect(
        await provider.recover(
          'api.bgm.tv',
          old,
          retryConfigs: fresh,
          dohUrl: 'https://dns.test',
        ),
        fresh,
      );
      expect(queries, 0);
      expect(
        ((stored as Map)['configs'] as Map).containsKey('cloudflare-ech.com'),
        isFalse,
      );
      expect(
        await provider.get(
          'api.bgm.tv',
          mode: 'doh',
          dohUrl: 'https://dns.test',
          manual: '',
        ),
        fresh,
      );
    },
  );
  test(
    'rejection without retry configs refetches and concurrent recovery shares flight',
    () async {
      final old = decodeEchConfig(builtInEchConfig)!;
      final pending = Completer<Object?>();
      var calls = 0;
      final provider = EchConfigProvider(
        fetchJson: (_) {
          calls++;
          return pending.future;
        },
      );
      final first = provider.recover(
        'api.bgm.tv',
        old,
        dohUrl: 'https://dns.test',
      );
      final second = provider.recover(
        'api.bgm.tv',
        old,
        dohUrl: 'https://dns.test',
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      final fresh = [0, 4, 0xfe, 0x0d, 0, 0];
      pending.complete({
        'Answer': [
          {'type': 65, 'data': 'ech=${base64Encode(fresh)}'},
        ],
      });
      expect(await first, fresh);
      expect(await second, fresh);
    },
  );
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
      expect(await get(), bytes); // Use the last good config during refresh.
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
  test('config errors and first wait timeout retain bootstrap ECH', () async {
    final failed = EchConfigProvider(
      delay: (_) async {},
      fetchJson: (_) async => throw StateError('offline'),
    );
    expect(
      await failed.get(
        'bgm.tv',
        mode: 'doh',
        dohUrl: 'https://dns.test',
        manual: '',
      ),
      decodeEchConfig(builtInEchConfig),
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
      decodeEchConfig(builtInEchConfig),
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
