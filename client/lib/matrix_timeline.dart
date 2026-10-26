typedef MatrixEvent = Map<String, dynamic>;

/// Render SDK-decrypted events in their supplied DAG order. Edits only apply
/// to the same sender and event type; a relation is never an authorization.
List<MatrixEvent> renderMatrixTimeline(List<MatrixEvent> raw, String? ownUser) {
  final events = [for (final event in raw) Map<String, dynamic>.of(event)];
  final byId = {for (final event in events) event['event_id']: event};
  final reactions = <String, Map<String, Set<String>>>{};
  final replies = <String, Set<String>>{};
  bool redacted(MatrixEvent e) =>
      (e['unsigned'] as Map?)?['redacted_because'] != null;
  for (final event in events) {
    if (redacted(event)) continue;
    final content = event['content'] as Map? ?? {};
    final relation = content['m.relates_to'] as Map? ?? {};
    final target = relation['event_id'];
    final original = byId[target];
    if (original == null || redacted(original)) continue;
    if (relation['rel_type'] == 'm.replace' &&
        event['sender'] == original['sender'] &&
        event['type'] == original['type'] &&
        content['m.new_content'] is Map) {
      original['rendered_content'] = (content['m.new_content'] as Map)
          .cast<String, dynamic>();
      original['edited'] = true;
    }
    if (event['type'] == 'm.reaction' &&
        relation['rel_type'] == 'm.annotation' &&
        relation['key'] is String &&
        event['sender'] is String) {
      reactions
          .putIfAbsent(target as String, () => {})
          .putIfAbsent(relation['key'] as String, () => {})
          .add(event['sender'] as String);
    }
    if (relation['rel_type'] == 'm.thread' &&
        event['type'] == 'm.room.message') {
      replies
          .putIfAbsent(target as String, () => {})
          .add(event['event_id'] as String);
    }
  }
  for (final event in events) {
    final relation =
        ((event['unsigned'] as Map?)?['m.relations'] as Map?) ?? {};
    final counts = <String, int>{};
    for (final annotation
        in ((relation['m.annotation'] as Map?)?['chunk'] as List? ?? [])) {
      if (annotation is Map &&
          annotation['type'] == 'm.reaction' &&
          annotation['key'] is String &&
          annotation['count'] is int) {
        counts[annotation['key'] as String] = annotation['count'] as int;
      }
    }
    final seen = reactions[event['event_id']] ?? {};
    for (final reaction in seen.entries) {
      if (reaction.value.length > (counts[reaction.key] ?? 0)) {
        counts[reaction.key] = reaction.value.length;
      }
    }
    event['reaction_summary'] = [
      for (final count in counts.entries)
        {
          'key': count.key,
          'count': count.value,
          'active': seen[count.key]?.contains(ownUser) ?? false,
        },
    ];
    final bundled = (relation['m.thread'] as Map?)?['count'] as int? ?? 0;
    final observed = replies[event['event_id']]?.length ?? 0;
    event['reply_count'] = bundled > observed ? bundled : observed;
  }
  return events
      .where(
        (e) =>
            ((e['content'] as Map?)?['m.relates_to'] as Map?)?['rel_type'] !=
            'm.replace',
      )
      .toList();
}
