import 'package:flutter/material.dart';

import 'api.dart';
import 'profile_avatar.dart';
import 'river_feedback.dart';

class FriendsSidebar extends StatelessWidget {
  const FriendsSidebar({
    super.key,
    required this.app,
    required this.selected,
    required this.selectedPerson,
    required this.onOpen,
    required this.onPerson,
  });

  final RiverApi app;
  final bool selected;
  final String? selectedPerson;
  final VoidCallback onOpen;
  final ValueChanged<String> onPerson;

  List<Widget> _requests(String direction) {
    final incoming = direction == 'incoming';
    final requests = app.requests
        .where((p) => p['direction'] == direction)
        .toList();
    return [
      for (final request in requests.take(2))
        _person(
          request,
          name: request['username'] as String,
          status: incoming ? 'Incoming request' : 'Sent · Pending',
          icon: incoming ? Icons.mark_email_unread_outlined : Icons.schedule,
        ),
      if (requests.length > 2)
        ListTile(
          title: Text('More ${incoming ? 'incoming' : 'sent'} requests'),
          trailing: Text('+${requests.length - 2}'),
          onTap: onOpen,
        ),
    ];
  }

  Widget _person(
    Json person, {
    required String name,
    String? status,
    IconData? icon,
  }) {
    final id = person['user_id'] as String;
    return RiverPress(
      key: ValueKey(('sidebar-friend', id)),
      child: ListTile(
        selected: selected && selectedPerson == id,
        leading: ElasticArt(
          child: icon == null
              ? RiverProfileAvatar(
                  app: app,
                  name: name,
                  avatarUrl: app.personAvatar(id),
                  size: 24,
                )
              : Icon(icon, size: 19),
        ),
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: status == null ? null : Text(status),
        onTap: () => onPerson(id),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final incoming = app.incomingRequests;
    final color = Theme.of(context).colorScheme;
    return Material(
      color: color.primary.withValues(alpha: .055),
      borderRadius: BorderRadius.circular(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RiverPress(
            child: ListTile(
              key: const ValueKey('destination-Friends'),
              selected: selected && selectedPerson == null,
              leading: ElasticArt(
                child: ElasticPulse(
                  signal: incoming,
                  child: const Icon(Icons.people_outline, size: 19),
                ),
              ),
              title: const Text(
                'Friends',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              trailing: incoming == 0
                  ? const Icon(Icons.chevron_right, size: 18)
                  : Semantics(
                      label:
                          '$incoming incoming friend ${incoming == 1 ? 'request' : 'requests'}',
                      excludeSemantics: true,
                      child: Badge.count(count: incoming),
                    ),
              onTap: onOpen,
            ),
          ),
          ..._requests('incoming'),
          ..._requests('outgoing'),
          for (final friend in app.friends.take(3))
            _person(friend, name: app.displayName(friend['user_id'] as String)),
        ],
      ),
    );
  }
}
