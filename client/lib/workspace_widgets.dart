import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'call_widgets.dart';
import 'matrix_security_widgets.dart';
import 'content_widgets.dart';
import 'publishing_widgets.dart';

class SubgroupDetails extends StatefulWidget {
  const SubgroupDetails({
    super.key,
    required this.app,
    required this.group,
    required this.open,
  });
  final RiverApi app;
  final Json group;
  final void Function(String?) open;
  @override
  State<SubgroupDetails> createState() => _SubgroupDetailsState();
}

class _SubgroupDetailsState extends State<SubgroupDetails> {
  late final Future<Json> details = widget.app.subgroups(
    widget.group['id'] as String,
  );
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('${widget.group['name']} · Group hierarchy'),
    content: SizedBox(
      width: 440,
      height: 400,
      child: FutureBuilder<Json>(
        future: details,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Text(
              'Could not load the group hierarchy: ${snapshot.error}',
            );
          }
          final data = snapshot.data;
          if (data == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return ListView(
            children: [
              Text('${data['participant_count']} participants'),
              const SizedBox(height: 8),
              const Text(
                'Groups below are related by their current participants. Each conversation keeps its own visibility and permissions.',
              ),
              for (final section in const {
                'containing_groups': 'Containing groups',
                'contained_groups': 'Sub-groups',
                'same_participant_groups': 'Same participants',
              }.entries) ...[
                const SizedBox(height: 20),
                Text(
                  section.value,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                if ((data[section.key] as List? ?? []).isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text('No groups to show.'),
                  ),
                for (final related
                    in (data[section.key] as List? ?? []).cast<Json>())
                  ListTile(
                    leading: const Icon(Icons.account_tree_outlined),
                    title: Text(related['name'] as String),
                    onTap: () {
                      Navigator.pop(context);
                      widget.open(related['id'] as String);
                    },
                  ),
              ],
            ],
          );
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Done'),
      ),
    ],
  );
}

class ConversationPicker extends StatefulWidget {
  const ConversationPicker({
    super.key,
    required this.app,
    this.contextGroup,
    this.matrixOnly = false,
  });
  final bool matrixOnly;
  final RiverApi app;
  final Json? contextGroup;
  @override
  State<ConversationPicker> createState() => _ConversationPickerState();
}

class _ConversationPickerState extends State<ConversationPicker> {
  final name = TextEditingController(), query = TextEditingController();
  final selected = <String>{};
  bool busy = false;
  String? error;
  @override
  void dispose() {
    name.dispose();
    query.dispose();
    super.dispose();
  }

  Future<void> create() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.app.conversation(
        name.text.trim().isEmpty ? 'Conversation' : name.text.trim(),
        selected.toList()..sort(),
        contextId: widget.contextGroup?['id'] as String?,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  List<Json> get candidates {
    if (widget.contextGroup == null) return widget.app.friends;
    return (widget.contextGroup!['members'] as List? ?? [])
        .cast<Json>()
        .where(
          (person) =>
              person['principal_id'] != widget.app.user?['sub'] &&
              (person['user_id'] ??
                      widget.app.userId(person['username'] as String)) !=
                  widget.app.user?['user_id'],
        )
        .map(
          (person) => <String, dynamic>{
            ...person,
            'user_id':
                person['user_id'] ??
                widget.app.userId(person['username'] as String),
          },
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.matrixOnly
          ? 'Connect with Matrix'
          : widget.contextGroup == null
          ? 'New conversation'
          : 'Conversation in ${widget.contextGroup!['name']}',
    ),
    content: SizedBox(
      width: 440,
      height: 420,
      child: Column(
        children: [
          if (selected.length > 1 || widget.contextGroup != null)
            TextField(
              controller: name,
              maxLength: 80,
              decoration: const InputDecoration(labelText: 'Group name'),
            ),
          TextField(
            controller: query,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: widget.matrixOnly
                  ? 'Matrix ID, room alias or link'
                  : widget.contextGroup == null
                  ? 'Friend, Matrix user or room'
                  : 'Find a group member',
              prefixIcon: Icon(Icons.search),
            ),
          ),
          if (widget.app.matrixConnected && widget.contextGroup == null)
            TextButton.icon(
              icon: const Icon(Icons.public),
              label: const Text('Message a Matrix user'),
              onPressed: busy
                  ? null
                  : () async {
                      final person = query.text.trim();
                      if (!person.startsWith('@') || !person.contains(':')) {
                        setState(
                          () => error =
                              'Enter a full Matrix ID, such as @Alice:example.org, in the search field.',
                        );
                        return;
                      }
                      setState(() {
                        busy = true;
                        error = null;
                      });
                      try {
                        await widget.app.messageFriend(person);
                        if (context.mounted) Navigator.pop(context, true);
                      } catch (e) {
                        if (mounted) setState(() => error = '$e');
                      } finally {
                        if (mounted) setState(() => busy = false);
                      }
                    },
            ),
          if (widget.app.matrixConnected && widget.contextGroup == null)
            TextButton.icon(
              icon: const Icon(Icons.add_link),
              label: const Text('Join Matrix room'),
              onPressed: busy
                  ? null
                  : () async {
                      final room = query.text.trim();
                      if (room.isEmpty) {
                        setState(
                          () => error =
                              'Enter a room ID, alias or matrix.to link in the search field.',
                        );
                        return;
                      }
                      setState(() {
                        busy = true;
                        error = null;
                      });
                      try {
                        await widget.app.joinMatrixRoom(room);
                        if (context.mounted) Navigator.pop(context, true);
                      } catch (e) {
                        if (mounted) setState(() => error = '$e');
                      } finally {
                        if (mounted) setState(() => busy = false);
                      }
                    },
            ),
          Expanded(
            child: widget.matrixOnly
                ? Center(
                    child: Text(
                      widget.app.matrixConnected
                          ? 'Use @name:server to message someone, or #room:server to join a room.'
                          : 'Connect Matrix messaging on this device to continue.',
                    ),
                  )
                : candidates.isEmpty
                ? Center(
                    child: Text(
                      widget.contextGroup == null
                          ? 'Add a Gravitas contact who uses River to start a conversation.'
                          : 'Invite people to this group before starting a conversation.',
                    ),
                  )
                : ListView(
                    children: [
                      for (final friend in candidates.where(
                        (p) => '${p['username']}'.toLowerCase().contains(
                          query.text.toLowerCase(),
                        ),
                      ))
                        CheckboxListTile(
                          value: selected.contains(friend['user_id']),
                          title: Text(friend['username'] as String),
                          subtitle: Text(
                            widget.app.online.contains(friend['user_id'])
                                ? 'Online'
                                : widget.contextGroup == null
                                ? 'River friend'
                                : 'Group member',
                          ),
                          onChanged: busy
                              ? null
                              : (checked) => setState(() {
                                  if (checked == true && selected.length < 24) {
                                    selected.add(friend['user_id'] as String);
                                  } else {
                                    selected.remove(friend['user_id']);
                                  }
                                }),
                        ),
                    ],
                  ),
          ),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      if (!widget.matrixOnly)
        FilledButton(
          onPressed: busy || selected.isEmpty ? null : create,
          child: Text(busy ? 'Creating…' : 'Start conversation'),
        ),
    ],
  );
}

Future<void> openRiverThread(
  BuildContext context,
  RiverApi app,
  String room,
  Json event,
) async {
  if (event['type'] != 'm.room.message') {
    try {
      await app.readEntry(room, event['event_id'] as String);
    } on Object {
      /* Reading can still proceed if an acknowledgement failed. */
    }
  }
  if (context.mounted) {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => event['type'] == 'cool.gravitas.river.post.v1'
            ? PostScreen(app: app, event: event['event_id'] as String)
            : ThreadScreen(
                app: app,
                room: room,
                rootId: event['event_id'] as String,
              ),
      ),
    );
  }
}

class CatchUpPanel extends StatelessWidget {
  const CatchUpPanel({super.key, required this.app, this.open});
  final RiverApi app;
  final ValueChanged<String?>? open;
  List<Json> unreadGroups(bool conversations) {
    final items = app.groups
        .where(
          (g) =>
              (g['unread_count'] as int? ?? 0) > 0 &&
              (conversations
                  ? ['dm', 'group'].contains(g['kind'])
                  : g['kind'] == 'channel' && g['channel_kind'] == 'text'),
        )
        .toList();
    items.sort(
      (a, b) => (b['last_activity_at'] as int? ?? 0).compareTo(
        a['last_activity_at'] as int? ?? 0,
      ),
    );
    return items.take(20).toList();
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Catch Up', style: Theme.of(context).textTheme.titleLarge),
          if (app.catchUp.isEmpty &&
              !app.groups.any((g) => (g['unread_count'] as int? ?? 0) > 0))
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('You’re all caught up.'),
            ),

          for (final kind in ['post', 'discussion']) ...[
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                kind == 'post' ? 'Recent Posts' : 'Recent Discussions',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            if (![
              ...app.catchUp,
              ...app.recent,
            ].any((e) => e['type'] == 'cool.gravitas.river.$kind.v1'))
              Text('No unread ${kind == 'post' ? 'posts' : 'discussions'}.'),
            for (final e
                in {
                      for (final entry in [...app.recent, ...app.catchUp])
                        entry['event_id']: entry,
                    }.values
                    .where((e) => e['type'] == 'cool.gravitas.river.$kind.v1')
                    .take(20))
              ListTile(
                leading: Icon(
                  kind == 'post'
                      ? Icons.article_outlined
                      : Icons.forum_outlined,
                ),
                title: Text(rendered(e)['title'] as String? ?? 'Entry'),
                subtitle: Text(
                  '${e['group_name'] ?? ''} · ${app.displayName(e['sender'] as String)}\n${rendered(e)['body'] ?? ''}',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () =>
                    openRiverThread(context, app, e['group_id'] as String, e),
              ),
          ],
          for (final conversation in [false, true]) ...[
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                conversation ? 'Recent Chats' : 'New activity in your channels',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            for (final g
                in conversation
                    ? (app.groups
                              .where(
                                (g) =>
                                    ['dm', 'group'].contains(g['kind']) &&
                                    g['membership'] == 'join',
                              )
                              .toList()
                            ..sort(
                              (a, b) => (b['last_activity_at'] as int? ?? 0)
                                  .compareTo(
                                    a['last_activity_at'] as int? ?? 0,
                                  ),
                            ))
                          .take(12)
                    : unreadGroups(false))
              ListTile(
                leading: Icon(
                  conversation ? Icons.mark_chat_unread_outlined : Icons.tag,
                ),
                title: Text(g['name'] as String),
                subtitle: (g['unread_preview'] as String? ?? '').isEmpty
                    ? null
                    : Text(
                        g['unread_preview'] as String,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                trailing: (g['unread_count'] as int? ?? 0) > 0
                    ? Badge(label: Text('${g['unread_count']}'))
                    : null,
                onTap: () => open != null
                    ? open!(g['id'] as String)
                    : app.open(g['id'] as String),
              ),
          ],
        ],
      ),
    ),
  );
}

class AccountPanel extends StatelessWidget {
  const AccountPanel({super.key, required this.app, this.onSignOut});
  final RiverApi app;
  final VoidCallback? onSignOut;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: app,
    builder: (context, _) => buildSettings(context),
  );

  Widget buildSettings(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      Text('Your account', style: Theme.of(context).textTheme.headlineMedium),
      ListTile(
        leading: const Icon(Icons.person_outline),
        title: Text(app.user?['username'] as String? ?? ''),
        subtitle: Text(app.user?['user_id'] as String? ?? 'Gravitas account'),
      ),
      Card(
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.manage_accounts_outlined),
              title: const Text('Password and app permissions'),
              subtitle: const Text('Manage your shared account in Gravitas'),
              trailing: const Icon(Icons.open_in_new),
              onTap: () => launchUrl(
                Uri.parse('https://gravitas.cool/settings'),
                mode: LaunchMode.externalApplication,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('Reconnect with Gravitas'),
              subtitle: const Text('Approve new River permissions'),
              onTap: app.login,
            ),
            ListTile(
              leading: const Icon(Icons.contacts_outlined),
              title: const Text('Gravitas contacts'),
              subtitle: const Text('Manage your shared contacts and requests'),
              trailing: const Icon(Icons.open_in_new),
              onTap: () => launchUrl(
                Uri.parse('https://gravitas.cool/contacts'),
                mode: LaunchMode.externalApplication,
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 24),
      Card(
        child: SwitchListTile(
          key: const ValueKey('enter-sends-messages'),
          title: const Text('Enter sends messages on desktop'),
          subtitle: const Text(
            'Use Shift+Enter for a new line. Turn off to use Enter for new lines.',
          ),
          value: app.enterSendsMessages,
          onChanged: (enabled) async {
            try {
              await app.setEnterSendsMessages(enabled);
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('$e')));
              }
            }
          },
        ),
      ),
      const SizedBox(height: 24),
      if (app.matrixEnabled) MatrixSecurityPanel(messaging: app.matrix),
      const SizedBox(height: 24),
      OutlinedButton.icon(
        onPressed: onSignOut ?? app.logout,
        icon: const Icon(Icons.logout),
        label: const Text('Sign out of River'),
      ),
    ],
  );
}

class InvitationCard extends StatelessWidget {
  const InvitationCard({super.key, required this.app, required this.event});
  final RiverApi app;
  final Json event;
  @override
  Widget build(BuildContext context) {
    final content = event['content'] as Json;
    final room = app.groups
        .where((g) => g['id'] == content['space_id'])
        .firstOrNull;
    Future<void> act(String action) async {
      try {
        await app.membership(content['space_id'] as String, action);
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('$e')));
        }
      }
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.mark_email_unread_outlined),
            Text(
              content['body'] as String? ?? 'Space invitation',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Text('From ${event['sender']}'),
            if (room?['membership'] == 'invite')
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    onPressed: () => act('accept'),
                    child: const Text('Join space'),
                  ),
                  TextButton(
                    onPressed: () => act('leave'),
                    child: const Text('Ignore'),
                  ),
                ],
              )
            else if (room?['membership'] == 'join')
              TextButton(
                onPressed: () => app.open(content['space_id'] as String),
                child: const Text('Open space'),
              )
            else
              const Text('This invitation is no longer available.'),
          ],
        ),
      ),
    );
  }
}

bool conversationMatches(Json group, String query) =>
    query.isEmpty ||
    '${group['name']} ${(group['members'] as List?)?.map((p) => '${p['username']} ${p['user_id']}').join(' ') ?? ''}'
        .toLowerCase()
        .contains(query.toLowerCase());

class SpaceChannels extends StatelessWidget {
  const SpaceChannels({
    super.key,
    required this.app,
    required this.space,
    required this.open,
    required this.thread,
  });
  final RiverApi app;
  final String space;
  final ValueChanged<String> open;
  final ValueChanged<Json> thread;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final channel
          in app.channels(space).where((c) => c['channel_kind'] == 'drop_in'))
        Padding(
          padding: const EdgeInsets.only(left: 24),
          child: VoiceRoomTile(app: app, channel: channel, compact: true),
        ),
      for (final channel
          in app.channels(space).where((c) => c['channel_kind'] == 'text'))
        _ChannelWithThreads(
          app: app,
          channel: channel,
          open: open,
          thread: thread,
        ),
    ],
  );
}

/// Rooms belong directly to a space. Voice rooms never open a message timeline.
class SpaceRoomList extends StatelessWidget {
  const SpaceRoomList({
    super.key,
    required this.app,
    required this.space,
    required this.open,
    this.openSpaceChat,
  });
  final RiverApi app;
  final String space;
  final ValueChanged<String> open;
  final VoidCallback? openSpaceChat;
  @override
  Widget build(BuildContext context) {
    final channels = app.channels(space);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Text(
            'CHATROOMS',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Color(0xff6b7280),
              letterSpacing: 1,
            ),
          ),
        ),
        if (channels.any((c) => c['channel_kind'] == 'drop_in'))
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final channel in channels.where(
                  (c) => c['channel_kind'] == 'drop_in',
                ))
                  SizedBox(
                    width: 220,
                    child: VoiceRoomTile(app: app, channel: channel),
                  ),
              ],
            ),
          ),
        if (openSpaceChat != null)
          ListTile(
            key: const ValueKey('space-chat'),
            dense: true,
            leading: const Icon(Icons.tag, size: 18),
            title: const Text('Space chat'),
            onTap: openSpaceChat,
          ),
        for (final channel in channels.where(
          (c) => c['channel_kind'] == 'text',
        ))
          ListTile(
            dense: true,
            leading: const Icon(Icons.tag, size: 18),
            title: Text(channel['name'] as String),
            trailing: (channel['unread_count'] as int? ?? 0) > 0
                ? Badge(label: Text('${channel['unread_count']}'))
                : null,
            onTap: () => open(channel['id'] as String),
          ),
        if (channels.isEmpty)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'Create a voice room or text chat from the space menu.',
            ),
          ),
      ],
    );
  }
}

class VoiceRoomTile extends StatefulWidget {
  const VoiceRoomTile({
    super.key,
    required this.app,
    required this.channel,
    this.compact = false,
  });
  final RiverApi app;
  final Json channel;
  final bool compact;
  @override
  State<VoiceRoomTile> createState() => _VoiceRoomTileState();
}

class _VoiceRoomTileState extends State<VoiceRoomTile> {
  bool preview = false;
  @override
  Widget build(BuildContext context) {
    final app = widget.app, channel = widget.channel;
    final people = app.activeCalls
        .where((c) => c['group_id'] == channel['id'])
        .expand((c) => (c['participants'] as List? ?? []).cast<Json>())
        .toList();
    return MouseRegion(
      onEnter: (_) => setState(() => preview = true),
      onExit: (_) => setState(() => preview = false),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            dense: true,
            minTileHeight: widget.compact ? 32 : 44,
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            minLeadingWidth: 18,
            horizontalTitleGap: 6,
            leading: const Icon(Icons.headphones_outlined, size: 17),
            title: Text(
              channel['name'] as String,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
            trailing: Text(
              '${people.length}',
              style: Theme.of(context).textTheme.labelSmall,
            ),
            onTap: () {
              if (preview) {
                joinRiverCall(context, app, channel);
              } else {
                setState(() => preview = true);
              }
            },
          ),
          if (preview)
            Padding(
              padding: const EdgeInsets.only(left: 8, right: 8, bottom: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    people.isEmpty
                        ? 'No one here yet'
                        : '${people.length} ${people.length == 1 ? 'person' : 'people'} here',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                  for (final p in people)
                    Text(
                      app.displayName(
                        p['user_id'] as String? ??
                            p['identity'] as String? ??
                            'Guest',
                      ),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  TextButton.icon(
                    onPressed: () => joinRiverCall(context, app, channel),
                    icon: const Icon(Icons.call_outlined, size: 16),
                    label: const Text('Join voice room'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ChannelWithThreads extends StatefulWidget {
  const _ChannelWithThreads({
    required this.app,
    required this.channel,
    required this.open,
    required this.thread,
  });
  final RiverApi app;
  final Json channel;
  final ValueChanged<String> open;
  final ValueChanged<Json> thread;
  @override
  State<_ChannelWithThreads> createState() => _ChannelWithThreadsState();
}

class _ChannelWithThreadsState extends State<_ChannelWithThreads> {
  bool closed = false;
  @override
  Widget build(BuildContext context) {
    final channel = widget.channel;
    final threads = widget.app.threads
        .where((t) => t['group_id'] == channel['id'])
        .toList();
    final calls = widget.app.activeCalls
        .where((c) => c['group_id'] == channel['id'])
        .toList();
    final participants = calls
        .expand((c) => (c['participants'] as List?) ?? [])
        .length;
    return Column(
      children: [
        ListTile(
          dense: true,
          selected: widget.app.selected == channel['id'],
          contentPadding: const EdgeInsets.only(left: 36, right: 12),
          leading: Icon(
            channel['channel_kind'] == 'drop_in'
                ? Icons.headphones_outlined
                : Icons.tag,
            size: 17,
          ),
          title: Text(
            channel['name'] as String,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13),
          ),
          subtitle: channel['channel_kind'] == 'drop_in'
              ? Text(
                  participants == 0
                      ? 'Ready when you are'
                      : '$participants ${participants == 1 ? 'person' : 'people'} here',
                )
              : null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if ((channel['unread_count'] as int? ?? 0) > 0)
                Badge(label: Text('${channel['unread_count']}')),
              if (threads.isNotEmpty)
                IconButton(
                  tooltip:
                      '${closed ? 'Expand' : 'Collapse'} replies in ${channel['name']}',
                  onPressed: () => setState(() => closed = !closed),
                  icon: Icon(
                    closed ? Icons.chevron_right : Icons.expand_more,
                    size: 18,
                  ),
                ),
            ],
          ),
          onTap: () => widget.open(channel['id'] as String),
        ),
        if (!closed)
          for (final event in threads)
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.only(left: 55, right: 16),
              leading: const Icon(Icons.reply, size: 15),
              title: Text(
                rendered(event)['body'] as String? ?? 'Thread',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
              trailing: Text('${event['reply_count'] ?? 0}'),
              onTap: () => widget.thread(event),
            ),
      ],
    );
  }
}
