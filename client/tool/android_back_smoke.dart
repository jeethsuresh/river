// CI-only entry point: real River UI and Android host, with no account or network.
// Release builds always target lib/main.dart.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:river/api.dart';
import 'package:river/main.dart';

class BackSmokeApi extends RiverApi {
  BackSmokeApi() : super(live: false, matrixEnabled: false) {
    loading = false;
    user = {'sub': 'back-smoke', 'username': 'Back tester'};
    groups = [
      {
        'id': 'back-room',
        'name': 'Back gesture test',
        'kind': 'dm',
        'membership': 'join',
        'members': <Json>[],
      },
    ];
    selected = 'back-room';
  }

  @override
  Future<void> resumeAuthentication() async {}
  @override
  Future<void> refresh() async {}
  @override
  Future<void> refreshStoreNotifications() async {}
}

class BackSmokeObserver extends WidgetsBindingObserver {
  int starts = 0, requests = 0;
  @override
  bool handleStartBackGesture(PredictiveBackEvent event) {
    starts++;
    return false;
  }

  @override
  Future<bool> didPopRoute() async {
    requests++;
    return false;
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final app = BackSmokeApi();
  final observer = BackSmokeObserver();
  WidgetsBinding.instance.addObserver(observer);
  const MethodChannel('cool.gravitas.river/back-smoke').setMethodCallHandler((
    call,
  ) async {
    if (call.method != 'state') throw MissingPluginException();
    ScaffoldState? shell;
    void visit(Element element) {
      if (element is StatefulElement &&
          element.state is ScaffoldState &&
          (element.widget as Scaffold).drawer != null) {
        shell = element.state as ScaffoldState;
      }
      element.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    return {
      'drawer': shell?.isDrawerOpen,
      'user': app.user?['sub'],
      'selected': app.selected,
      'gestureStarts': observer.starts,
      'backRequests': observer.requests,
      'focus': FocusManager.instance.primaryFocus?.debugLabel,
    };
  });
  runApp(RiverApp(api: app, boot: false));
}
