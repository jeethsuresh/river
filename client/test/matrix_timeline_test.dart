import 'package:flutter_test/flutter_test.dart';
import 'package:river/matrix_timeline.dart';

MatrixEvent event(
  String id,
  String sender,
  Map<String, dynamic> content, {
  String type = 'm.room.message',
  int timestamp = 1,
}) => {
  'event_id': id,
  'sender': sender,
  'type': type,
  'origin_server_ts': timestamp,
  'content': content,
};

void main() {
  test(
    'only same-sender, same-type edits can replace an event; DAG order is preserved',
    () {
      final input = [
        event('root', '@Alice:remote', {'body': 'original'}, timestamp: 999999),
        event('valid', '@Alice:remote', {
          'm.relates_to': {'rel_type': 'm.replace', 'event_id': 'root'},
          'm.new_content': {'body': 'edited'},
        }),
        event('forged', '@mallory:remote', {
          'm.relates_to': {'rel_type': 'm.replace', 'event_id': 'root'},
          'm.new_content': {'body': 'forged'},
        }),
        event('wrong-type', '@Alice:remote', {
          'm.relates_to': {'rel_type': 'm.replace', 'event_id': 'root'},
          'm.new_content': {'body': 'wrong'},
        }, type: 'other.type'),
        event('next', '@bob:remote', {'body': 'next'}, timestamp: 0),
      ];
      final rendered = renderMatrixTimeline(input, '@me:home');
      expect(rendered.map((e) => e['event_id']), ['root', 'next']);
      expect(rendered.first['rendered_content'], {'body': 'edited'});
      expect((input.first['content'] as Map)['body'], 'original');
    },
  );
  test(
    'reaction senders are deduplicated and thread replies stay separate',
    () {
      final events = [
        event('root', '@Alice:remote', {'body': 'Hello'}),
        for (final id in ['reaction1', 'reaction2'])
          event(id, '@me:home', {
            'm.relates_to': {
              'rel_type': 'm.annotation',
              'event_id': 'root',
              'key': '👍',
            },
          }, type: 'm.reaction'),
        event('reply', '@bob:remote', {
          'body': 'In a thread',
          'm.relates_to': {'rel_type': 'm.thread', 'event_id': 'root'},
        }),
      ];
      final rendered = renderMatrixTimeline(events, '@me:home');
      expect(rendered.first['reaction_summary'], [
        {'key': '👍', 'count': 1, 'active': true},
      ]);
      expect(rendered.first['reply_count'], 1);
    },
  );
}
