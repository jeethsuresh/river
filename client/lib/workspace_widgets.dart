import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'api.dart';
import 'matrix_security_widgets.dart';
import 'content_widgets.dart';
import 'publishing_widgets.dart';

class ConversationPicker extends StatefulWidget {
  const ConversationPicker({super.key, required this.app});
  final RiverApi app;
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
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('New conversation'),
    content: SizedBox(
      width: 440,
      height: 420,
      child: Column(
        children: [
          if (selected.length > 1)
            TextField(
              controller: name,
              maxLength: 80,
              decoration: const InputDecoration(labelText: 'Group name'),
            ),
          TextField(
            controller: query,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Find a friend',
              prefixIcon: Icon(Icons.search),
            ),
          ),
          if (widget.app.matrixConnected)
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
          Expanded(
            child: widget.app.friends.isEmpty
                ? const Center(
                    child: Text(
                      'Add a Gravitas contact who uses River to start a conversation.',
                    ),
                  )
                : ListView(
                    children: [
                      for (final friend in widget.app.friends.where(
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
                                : 'River friend',
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
  const CatchUpPanel({super.key, required this.app});
  final RiverApi app;
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
          Text('Catch up', style: Theme.of(context).textTheme.titleLarge),
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
                'New ${kind == 'post' ? 'posts' : 'discussions'} from your spaces',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            if (!app.catchUp.any(
              (e) => e['type'] == 'cool.gravitas.river.$kind.v1',
            ))
              Text('No unread ${kind == 'post' ? 'posts' : 'discussions'}.'),
            for (final e
                in app.catchUp
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
                  '${e['group_name'] ?? ''} · ${e['sender']}\n${rendered(e)['body'] ?? ''}',
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
                conversation
                    ? 'Unread conversations'
                    : 'New activity in your channels',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            for (final g in unreadGroups(conversation))
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
                trailing: Badge(label: Text('${g['unread_count']}')),
                onTap: () => app.open(g['id'] as String),
              ),
          ],
        ],
      ),
    ),
  );
}

class AccountPanel extends StatelessWidget {
  const AccountPanel({super.key, required this.app});
  final RiverApi app;
  @override
  Widget build(BuildContext context) => ListView(
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
      if (app.matrixEnabled) MatrixSecurityPanel(messaging: app.matrix),
      const SizedBox(height: 24),
      OutlinedButton.icon(
        onPressed: app.logout,
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
      for (final kind in ['text', 'drop_in'])
        ExpansionTile(
          key: PageStorageKey('$space:$kind'),
          initiallyExpanded: true,
          title: Text(
            kind == 'text' ? 'Text channels' : 'Voice rooms',
            style: const TextStyle(fontSize: 12),
          ),
          children: [
            for (final channel
                in app.channels(space).where((c) => c['channel_kind'] == kind))
              _ChannelWithThreads(
                app: app,
                channel: channel,
                open: open,
                thread: thread,
              ),
          ],
        ),
    ],
  );
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
