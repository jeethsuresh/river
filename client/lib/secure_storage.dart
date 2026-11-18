import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// The desktop bundle stores credentials in the macOS login Keychain.
const riverSecureStorage = FlutterSecureStorage(
  mOptions: MacOsOptions(usesDataProtectionKeychain: false),
);
