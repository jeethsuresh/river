import 'dart:io';
import 'package:path_provider/path_provider.dart';

Future<String> matrixStoreLocation(String name) async {
  final support = await getApplicationSupportDirectory();
  final directory = Directory('${support.path}/matrix/$name');
  await directory.create(recursive: true);
  return directory.path;
}
