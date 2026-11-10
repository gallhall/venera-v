import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';

import 'capabilities.dart';

class IosThermal implements ThermalCapability {
  const IosThermal();

  static const _channel = MethodChannel('venera/thermal');

  @override
  bool get isSupported => true;

  @override
  Future<Map<String, dynamic>?> sample() => _channel
      .invokeMapMethod<String, dynamic>('sample')
      .timeout(const Duration(seconds: 2));
}

class IosNetworkType implements NetworkTypeCapability {
  const IosNetworkType();

  @override
  bool get isSupported => true;

  static bool _isUnmetered(List<ConnectivityResult> results) =>
      results.contains(ConnectivityResult.wifi) ||
      results.contains(ConnectivityResult.ethernet);

  @override
  Future<bool> isWifi() async =>
      _isUnmetered(await Connectivity().checkConnectivity());

  @override
  Future<bool> isMetered() async {
    final results = await Connectivity().checkConnectivity();
    return results.contains(ConnectivityResult.mobile) && !_isUnmetered(results);
  }
}
