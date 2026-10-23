import 'api.dart';
export 'api.dart' show Json;

Json object(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};
List<Json> records(Object? value) =>
    value is List ? value.map(object).toList() : [];

extension Fields on Json {
  String text(String key, [String fallback = '']) =>
      this[key] is String ? this[key] as String : fallback;
  int number(String key) => (this[key] as num?)?.toInt() ?? 0;
  List<Json> rows(String key) => records(this[key]);
}

class FileScope {
  const FileScope(this.kind, this.id);
  final String kind, id;
  String get key => '$kind:$id';
  @override
  bool operator ==(Object other) => other is FileScope && other.key == key;
  @override
  int get hashCode => key.hashCode;
}

String fileSize(int size) => size >= 1024 * 1024
    ? '${(size / (1024 * 1024)).toStringAsFixed(1)} MB'
    : size >= 1024
    ? '${(size / 1024).ceil()} KB'
    : '$size B';
