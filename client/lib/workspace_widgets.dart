import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'api.dart';
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
          for (final e in app.catchUp.take(12))
            ListTile(
              leading: Icon(
                e['type'] == 'cool.gravitas.river.post.v1'
                    ? Icons.article_outlined
                    : Icons.forum_outlined,
              ),
              title: Text(rendered(e)['title'] as String? ?? 'Entry'),
              subtitle: Text(e['sender'] as String),
              onTap: () =>
                  openRiverThread(context, app, e['group_id'] as String, e),
            ),
          for (final g
              in app.groups
                  .where((g) => (g['unread_count'] as int? ?? 0) > 0)
                  .take(12))
            ListTile(
              leading: const Icon(Icons.mark_chat_unread_outlined),
              title: Text(g['name'] as String),
              trailing: Badge(label: Text('${g['unread_count']}')),
              onTap: () => app.open(g['id'] as String),
            ),
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
              title: const Text('Email, password and app permissions'),
              subtitle: const Text('Manage your shared account in Gravitas'),
              trailing: const Icon(Icons.open_in_new),
              onTap: () => launchUrl(
                Uri.parse('https://gravitas.cool/settings'),
                mode: LaunchMode.externalApplication,
              ),
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
