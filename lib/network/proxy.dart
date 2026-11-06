import 'dart:io';

import 'package:flutter/services.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/proxy_environment.dart';
import 'package:venera/utils/ext.dart';

export 'proxy_environment.dart';

String? _cachedProxy;

DateTime? _cachedProxyTime;

bool _warnedAboutSocks = false;

/// Environment bypass rules must not override a manual proxy or other OSes.
/// Without an environment proxy there is nothing to bypass, and requests
/// keep the persistent client.
bool bypassesSystemProxy(String host) =>
    App.isLinux && appdata.settings['proxy'] == 'system' &&
    proxyFromEnvironment(Platform.environment) != null &&
    bypassesProxy(host, noProxyFromEnvironment(Platform.environment));

Future<String?> getProxy({String? host}) async {
  if (host != null && bypassesSystemProxy(host)) {
    return null;
  }
  if (_cachedProxyTime != null &&
      DateTime.now().difference(_cachedProxyTime!).inSeconds < 1) {
    return _cachedProxy;
  }
  String? proxy = await _getProxy();
  _cachedProxy = proxy;
  _cachedProxyTime = DateTime.now();
  return proxy;
}

Future<String?> _getProxy() async {
  if ((appdata.settings['proxy'] as String).removeAllBlank == "direct") {
    return null;
  }
  if (appdata.settings['proxy'] != "system") {
    return appdata.settings['proxy'];
  }

  String res;
  if (!App.isLinux) {
    const channel = MethodChannel("venera/method_channel");
    try {
      res = await channel.invokeMethod("getProxy");
    } catch (e) {
      return null;
    }
  } else {
    final result = parseProxyEnvironment(Platform.environment);
    if (result.skippedSocks && !_warnedAboutSocks) {
      _warnedAboutSocks = true;
      Log.warning('Proxy', 'Ignoring SOCKS environment proxies: '
          'the shared HTTP proxy consumers do not support SOCKS.');
    }
    return result.proxy;
  }
  if (res == "No Proxy") {
    return null;
  }

  if (res.contains(";")) {
    var proxies = res.split(";");
    for (String proxy in proxies) {
      proxy = proxy.removeAllBlank;
      if (proxy.startsWith('https=')) {
        return proxy.substring(6);
      }
    }
  }

  final RegExp regex = RegExp(
    r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}:\d+$',
    caseSensitive: false,
    multiLine: false,
  );
  if (!regex.hasMatch(res)) {
    return null;
  }

  return res;
}
