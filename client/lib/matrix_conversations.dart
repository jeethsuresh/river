import 'dart:convert';

import 'matrix_messaging.dart';

String matrixParticipantKey(Iterable<String> participants) =>
    jsonEncode(participants.toSet().toList()..sort());

/// Group joined private chats by their complete participant roster. Keep the
/// Gravitas group as the representative so delegated actions retain their ID.
List<MatrixJson> combineMatrixConversations(
  Map<String, MatrixJson> byWire,
  String? ownUser, {
  String? preferredWire,
}) {
  final conversations = <String, List<MatrixJson>>{};
  final keys = <String, String>{};
  final anchors = <String, String>{};
  for (final room in byWire.values) {
    if (!['dm', 'group'].contains(room['kind']) ||
        room['membership'] != 'join' ||
        room['replacement_room'] != null ||
        room['upgrade_pending'] == true) {
      continue;
    }
    final wire = room['room_id'] as String;
    final participants = (room['conversation_participants'] as List?)
        ?.whereType<String>()
        .toSet();
    final peer = room['direct_peer'];
    if (participants != null &&
        participants.length >= 2 &&
        participants.contains(ownUser)) {
      keys[wire] = matrixParticipantKey(participants);
    } else if (room['kind'] == 'dm' && peer is String && ownUser != null) {
      keys[wire] = matrixParticipantKey([ownUser, peer]);
    }
    if (keys[wire] case final key?) {
      (conversations[key] ??= []).add(room);
    }
  }
  for (final rooms in conversations.values) {
    rooms.sort((a, b) {
      final aOrigin = a['is_fallback_room'] != true;
      final bOrigin = b['is_fallback_room'] != true;
      if (aOrigin != bOrigin) return aOrigin ? -1 : 1;
      final aDelegated = a['matrix_only'] != true;
      final bDelegated = b['matrix_only'] != true;
      if (aDelegated != bDelegated) return aDelegated ? -1 : 1;
      final aPreferred = a['room_id'] == preferredWire;
      final bPreferred = b['room_id'] == preferredWire;
      if (aPreferred != bPreferred) return aPreferred ? -1 : 1;
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
        ['dm', 'group'].contains(byWire[origin]?['kind']) &&
        (keys[room['room_id']] == null ||
            keys[room['room_id']] == keys[origin])) {
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
            'participant_key': keys[entry.key],
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
          {
            ...entry.value,
            if (keys[entry.key] case final key?) 'participant_key': key,
          },
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
