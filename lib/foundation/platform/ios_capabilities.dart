import 'package:connectivity_plus/connectivity_plus.dart';

import 'capabilities.dart';

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
