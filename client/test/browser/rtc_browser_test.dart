@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'rtc_stub.dart' if (dart.library.js_interop) 'rtc_browser.dart' as tests;

void main() => tests.main();
