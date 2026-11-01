import 'desktop_store_broker.dart';

Future<Map<String, dynamic>?> authorize(
  String origin,
  String challenge,
  String state,
  String? username,
) => authorizeDesktopStore(
  appOrigin: origin,
  challenge: challenge,
  state: state,
  username: username,
);
