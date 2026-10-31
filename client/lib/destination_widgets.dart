import 'package:flutter/material.dart';
import 'api.dart';
import 'content_widgets.dart';
import 'river_design.dart';

bool isMatrixGroup(RiverApi app, Json group) =>
    group['matrix_only'] == true ||
    (group['parent_id'] is String &&
        app.group(group['parent_id'] as String)?['matrix_only'] == true);

bool supportsRiverEntries(RiverApi app, Json group) =>
    group['kind'] == 'space' &&
    !isMatrixGroup(app, group) &&
    group['encrypted'] != true;

String roomDestination(RiverApi app, Json group) => isMatrixGroup(app, group)
    ? 'Matrix'
    : ['dm', 'group'].contains(group['kind'])
    ? 'Chats'
    : 'Communities';

List<Json> destinationGroups(RiverApi app, String destination) {
  final groups = app.groups.where((g) {
    if (!['join', 'invite', 'knock'].contains(g['membership'])) return false;
    final external = isMatrixGroup(app, g);
    return switch (destination) {
      'Chats' => !external && ['dm', 'group'].contains(g['kind']),
      'Matrix' =>
        external &&
            g['parent_id'] == null &&
            !['call_chat', 'post_comments'].contains(g['kind']),
      'Forums' || 'Posts' => supportsRiverEntries(app, g),
      _ => !external && g['kind'] == 'space',
    };
  }).toList();
  groups.sort((a, b) {
    final latest = (b['last_activity_at'] as int? ?? 0).compareTo(
      a['last_activity_at'] as int? ?? 0,
    );
    return latest != 0
        ? latest
        : (a['name'] as String).toLowerCase().compareTo(
            (b['name'] as String).toLowerCase(),
          );
  });
  return groups;
}

/// Each destination gives its content a task-specific shape. All actions use
/// the existing permission-checked room, thread and publication APIs.
class RiverDestinationView extends StatefulWidget {
  const RiverDestinationView({
    super.key,
    required this.app,
    required this.destination,
    required this.open,
    required this.create,
    required this.friends,
    required this.compose,
    required this.thread,
  });
  final RiverApi app;
  final String destination;
  final ValueChanged<String> open;
  final ValueChanged<String> create;
  final VoidCallback friends, compose;
  final void Function(String, Json) thread;
  @override
  State<RiverDestinationView> createState() => _RiverDestinationViewState();
}

class _RiverDestinationViewState extends State<RiverDestinationView> {
  String query = '';
  bool unread = false;
  @override
  Widget build(BuildContext context) {
    final app = widget.app, destination = widget.destination;
    final descriptor = riverDestinations.firstWhere(
      (d) => d.name == destination,
    );
    final groups = destinationGroups(app, destination);
    final entries = destination == 'Posts' || destination == 'Forums';
    final kind = destination == 'Posts' ? 'post' : 'discussion';
    final feed =
        {
              for (final event in [...app.recent, ...app.catchUp])
                if (event['type'] == 'cool.gravitas.river.$kind.v1' &&
                    groups.any(
                      (g) =>
                          g['id'] == event['group_id'] &&
                          g['membership'] == 'join',
                    ))
                  event['event_id']: event,
            }.values
            .where(
              (e) =>
                  '${rendered(e)['title']} ${e['group_name']} ${rendered(e)['body']}'
                      .toLowerCase()
                      .contains(query.toLowerCase()),
            )
            .toList()
          ..sort(
            (a, b) => (b['origin_server_ts'] as int? ?? 0).compareTo(
              a['origin_server_ts'] as int? ?? 0,
            ),
          );
    final visible = groups
        .where(
          (g) =>
              (query.isEmpty ||
                  (g['name'] as String).toLowerCase().contains(
                    query.toLowerCase(),
                  )) &&
              (!unread || (g['unread_count'] as int? ?? 0) > 0),
        )
        .toList();
    final subtitle = switch (destination) {
      'Chats' => 'Your people. Text, talk, or share your screen.',
      'Communities' =>
        'Your shared places, with a room for every conversation.',
      'Forums' =>
        'Conversations around ideas, with people in your communities.',
      'Posts' => 'Stories and updates, shared with a community or the world.',
      _ => 'Conversations with people beyond River.',
    };
    return ListView(
      padding: EdgeInsets.all(MediaQuery.sizeOf(context).width < 600 ? 16 : 24),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                destination,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ),
            if (destination == 'Chats')
              TextButton.icon(
                onPressed: widget.friends,
                icon: const Icon(Icons.people_outline, size: 18),
                label: const Text('Friends'),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(subtitle, style: const TextStyle(color: riverMuted, height: 1.5)),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: entries
                  ? widget.compose
                  : () => widget.create(
                      destination == 'Communities'
                          ? 'space'
                          : destination == 'Matrix'
                          ? 'matrix'
                          : 'dm',
                    ),
              icon: Icon(entries ? Icons.edit_outlined : Icons.add, size: 18),
              label: Text(switch (destination) {
                'Chats' => 'New conversation',
                'Communities' => 'Create community',
                'Forums' => 'New discussion',
                'Posts' => 'New post',
                _ => 'Connect with Matrix',
              }),
            ),
            if (destination == 'Chats')
              FilterChip(
                label: const Text('Unread'),
                selected: unread,
                onSelected: (v) => setState(() => unread = v),
              ),
          ],
        ),
        const SizedBox(height: 16),
        TextField(
          key: ValueKey('search-$destination'),
          decoration: InputDecoration(
            hintText: entries
                ? 'Search recent ${destination == 'Forums' ? 'topics' : 'posts'}'
                : 'Search ${destination.toLowerCase()}',
            prefixIcon: const Icon(Icons.search, size: 18),
          ),
          onChanged: (v) => setState(() => query = v.trim()),
        ),
        const SizedBox(height: 18),
        if (destination == 'Matrix') ...[
          const Card(
            child: Padding(
              padding: EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Connected through Matrix',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Messages, threads, reactions, and attachments. Encryption follows each room’s settings. River calls, forums, and publishing are available in River communities.',
                    style: TextStyle(
                      fontSize: 12,
                      color: riverMuted,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (entries) ...[
          Text(
            'YOUR COMMUNITIES',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: riverMuted,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final g in groups)
                ActionChip(
                  avatar: const Icon(Icons.workspaces_outline, size: 16),
                  label: Text(g['name'] as String),
                  onPressed: () => widget.open(g['id'] as String),
                ),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            destination == 'Forums' ? 'RECENT TOPICS' : 'RECENT POSTS',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: riverMuted,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 10),
          if (feed.isEmpty)
            RiverEmptyState(
              icon: descriptor.icon,
              title: query.isEmpty
                  ? 'Room for your next ${kind == 'post' ? 'story' : 'idea'}'
                  : 'No matching ${destination.toLowerCase()}',
              body:
                  'Choose a community to browse its full ${kind == 'post' ? 'post' : 'topic'} history, or start something new.',
            ),
          for (final event in feed)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: entriesCard(event, kind),
            ),
        ] else ...[
          if (visible.isEmpty)
            RiverEmptyState(
              icon: descriptor.icon,
              title: query.isNotEmpty || unread
                  ? 'Nothing matches this view'
                  : switch (destination) {
                      'Chats' => 'Start with someone you know',
                      'Communities' => 'Find your shared place',
                      _ => 'Your network reaches further',
                    },
              body: query.isNotEmpty || unread
                  ? 'Try another search or clear the unread filter.'
                  : switch (destination) {
                      'Chats' =>
                        'Find friends or start a conversation. Voice, video, and screen sharing are one call away.',
                      'Communities' =>
                        'Create a community, then add text rooms and drop-in voice rooms.',
                      _ =>
                        'Message a full Matrix ID or join a room by alias or link.',
                    },
            ),
          for (final g in visible)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Card(
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  leading: RiverAvatar(
                    name: g['name'] as String,
                    icon: destination == 'Matrix' ? Icons.hub_outlined : null,
                  ),
                  title: Text(
                    g['name'] as String,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    g['membership'] == 'invite'
                        ? 'Invitation · tap to respond'
                        : destination == 'Communities'
                        ? '${app.channels(g['id'] as String).length} ${app.channels(g['id'] as String).length == 1 ? 'room' : 'rooms'} · ${(g['members'] as List? ?? []).length} members'
                        : (g['unread_preview'] as String? ?? '').isNotEmpty
                        ? g['unread_preview'] as String
                        : destination == 'Matrix'
                        ? (g['encrypted'] == true
                              ? 'Encrypted Matrix room'
                              : 'Matrix room')
                        : 'Text · voice · video · screen sharing',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: (g['unread_count'] as int? ?? 0) > 0
                      ? Badge(label: Text('${g['unread_count']}'))
                      : const Icon(
                          Icons.chevron_right,
                          size: 18,
                          color: riverMuted,
                        ),
                  onTap: () => widget.open(g['id'] as String),
                ),
              ),
            ),
        ],
      ],
    );
  }

  Widget entriesCard(Json event, String kind) {
    final content = rendered(event);
    final visibility = (event['publication'] as Json?)?['visibility'];
    final public = visibility == 'public';
    final body = content['body'] as String? ?? '';
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => widget.thread(event['group_id'] as String, event),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      event['group_name'] as String? ??
                          widget.app.group(event['group_id'] as String)?['name']
                              as String? ??
                          '',
                      style: const TextStyle(fontSize: 12, color: riverMuted),
                    ),
                  ),
                  Icon(
                    kind == 'post' && public
                        ? Icons.public
                        : Icons.people_outline,
                    size: 14,
                    color: riverMuted,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    kind == 'post'
                        ? (public
                              ? 'Public'
                              : visibility == 'members'
                              ? 'Community'
                              : 'View audience')
                        : 'Community',
                    style: const TextStyle(fontSize: 11, color: riverMuted),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                content['title'] as String? ?? 'Untitled',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (kind == 'post' && body.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  body,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: riverMuted, height: 1.5),
                ),
              ],
              const SizedBox(height: 10),
              Text(
                '${widget.app.displayName(event['sender'] as String)} · ${event['reply_count'] ?? 0} ${kind == 'post' ? 'comments' : 'replies'}',
                style: const TextStyle(fontSize: 12, color: riverMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MatrixRoomList extends StatelessWidget {
  const MatrixRoomList({
    super.key,
    required this.app,
    required this.space,
    required this.open,
  });
  final RiverApi app;
  final String space;
  final ValueChanged<String> open;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final room in app.channels(space))
        ListTile(
          dense: true,
          leading: const Icon(Icons.tag, size: 17),
          title: Text(
            room['name'] as String,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: (room['unread_count'] as int? ?? 0) > 0
              ? Badge(label: Text('${room['unread_count']}'))
              : null,
          onTap: () => open(room['id'] as String),
        ),
      if (app.channels(space).isEmpty)
        const RiverEmptyState(
          icon: Icons.hub_outlined,
          title: 'No rooms in this Matrix space',
          body: 'Joined rooms appear here when this space includes them.',
        ),
    ],
  );
}
