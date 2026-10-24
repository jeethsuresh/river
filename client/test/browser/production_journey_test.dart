@TestOn('browser')
library;

// ignore_for_file: depend_on_referenced_packages, implementation_imports
import 'package:integration_test/integration_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:connectivity_plus/src/connectivity_plus_web.dart';
import 'package:device_info_plus/src/device_info_plus_web.dart';
import 'package:livekit_client/livekit_client_web.dart';
import '../production_journey_scenarios.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  ConnectivityPlusWebPlugin.registerWith(webPluginRegistrar);
  DeviceInfoPlusWebPlugin.registerWith(webPluginRegistrar);
  LiveKitWebPlugin.registerWith(webPluginRegistrar);
  webPluginRegistrar.registerMessageHandler();
  productionJourneyScenarios();
}
