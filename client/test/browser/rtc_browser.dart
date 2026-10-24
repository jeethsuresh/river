library;

// Web tests run without Flutter's generated plugin registrant.
// ignore_for_file: depend_on_referenced_packages, implementation_imports
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:connectivity_plus/src/connectivity_plus_web.dart';
import 'package:device_info_plus/src/device_info_plus_web.dart';
import 'package:livekit_client/livekit_client_web.dart';

import 'package:flutter_test/flutter_test.dart';
import '../media_scenarios.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ConnectivityPlusWebPlugin.registerWith(webPluginRegistrar);
  DeviceInfoPlusWebPlugin.registerWith(webPluginRegistrar);
  LiveKitWebPlugin.registerWith(webPluginRegistrar);
  webPluginRegistrar.registerMessageHandler();
  mediaScenarios(
    (name, run, {required skip, required timeout}) =>
        test(name, run, skip: skip, timeout: timeout),
  );
}
