import 'matrix_messaging.dart';

/// A direct conversation is identified by the peer Matrix verified in its
/// roster. A private group keeps its original identity and can have a linked
/// room with the same roster. Invitations and archived rooms stay actionable.
List<MatrixJson> combineMatrixConversations(Map<String, MatrixJson> byWire) {
  final direct = <String, List<MatrixJson>>{};
  final anchors = <String, String>{};
  for (final room in byWire.values) {
    final peer = room['direct_peer'];
    if (room['kind'] == 'dm' &&
        room['membership'] == 'join' &&
        room['replacement_room'] == null &&
        room['upgrade_pending'] != true &&
        peer is String) {
      (direct[peer] ??= []).add(room);
    }
  }
  for (final rooms in direct.values) {
    rooms.sort((a, b) {
      final aDelegated = a['matrix_only'] != true;
      final bDelegated = b['matrix_only'] != true;
      if (aDelegated != bDelegated) return aDelegated ? -1 : 1;
      return (a['room_id'] as String).compareTo(b['room_id'] as String);
    });
    final anchor = rooms.first['room_id'] as String;
    for (final room in rooms.skip(1)) {
      anchors[room['room_id'] as String] = anchor;
    }
  }
  for (final room in byWire.values) {
    final origin = room['fallback_for'];
    if (room['membership'] == 'join' &&
        origin is String &&
        byWire[origin]?['membership'] == 'join' &&
        ['dm', 'group'].contains(byWire[origin]?['kind'])) {
      anchors[room['room_id'] as String] = anchors[origin] ?? origin;
    }
  }

  final histories = <String, List<MatrixJson>>{};
  for (final entry in anchors.entries) {
    (histories[entry.value] ??= [byWire[entry.value]!]).add(byWire[entry.key]!);
  }
  for (final rooms in histories.values) {
    final origin = rooms.removeAt(0);
    rooms.sort(
      (a, b) => (a['room_id'] as String).compareTo(b['room_id'] as String),
    );
    rooms.insert(0, origin);
  }
  return [
    for (final entry in byWire.entries)
      if (!anchors.containsKey(entry.key))
        if (histories[entry.key] case final rooms?)
          {
            ...entry.value,
            'history_rooms': [for (final room in rooms) room['room_id']],
            'secure_room': rooms
                .where(
                  (r) =>
                      r['encrypted'] == true && r['is_fallback_room'] != true,
                )
                .firstOrNull?['room_id'],
            'fallback_rooms': [
              for (final room in rooms)
                if (room['fallback_for'] != null && room['encrypted'] == false)
                  room['room_id'],
            ],
            'unread_count': rooms.fold<int>(
              0,
              (sum, room) => sum + (room['unread_count'] as int? ?? 0),
            ),
          }
        else
          entry.value,
  ];
}

/// Keep the homeserver's order inside each room. The timestamp only chooses
/// between rooms, which have independent event orderings.
List<MatrixJson> interleaveMatrixHistory(
  List<MatrixJson> events,
  List<String> rooms,
) {
  if (rooms.length < 2) return events;
  final timelines = [
    for (final room in rooms)
      events.where((event) => event['room_id'] == room).iterator,
  ].where((timeline) => timeline.moveNext()).toList();
  final merged = <MatrixJson>[];
  while (timelines.isNotEmpty) {
    var first = 0;
    for (var i = 1; i < timelines.length; i++) {
      final time = timelines[i].current['origin_server_ts'] as int? ?? 0;
      final firstTime =
          timelines[first].current['origin_server_ts'] as int? ?? 0;
      if (time < firstTime) first = i;
    }
    merged.add(timelines[first].current);
    if (!timelines[first].moveNext()) timelines.removeAt(first);
  }
  return merged;
}
