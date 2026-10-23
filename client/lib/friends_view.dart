import 'package:flutter/material.dart';
import 'api.dart';

class FriendsView extends StatefulWidget {
  const FriendsView({
    super.key,
    required this.app,
    required this.onConversation,
  });
  final RiverApi app;
  final VoidCallback onConversation;
  @override
  State<FriendsView> createState() => _FriendsViewState();
}

class _FriendsViewState extends State<FriendsView> {
  String query = '';
  bool busy = false;
  RiverApi get app => widget.app;
  Future<void> run(Future<void> Function() f) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await f();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> add() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Add a Gravitas contact'),
            content: TextField(
              controller: controller,
              autofocus: true,
              maxLength: 100,
              decoration: const InputDecoration(
                labelText: 'Gravitas username',
                hintText: 'alice',
              ),
              onSubmitted: (v) {
                if (v.trim().isNotEmpty) Navigator.pop(ctx, v.trim());
              },
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  if (controller.text.trim().isNotEmpty) {
                    Navigator.pop(ctx, controller.text.trim());
                  }
                },
                child: const Text('Send request'),
              ),
            ],
          ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.dispose();
    if (name != null) await run(() => app.friendAction(name, 'request'));
  }

  bool matches(Json p) => '${p['username']} ${p['user_id']}'
      .toLowerCase()
      .contains(query.toLowerCase());
  Widget section(String title, List<Widget> rows, String empty) => Padding(
    padding: const EdgeInsets.only(top: 20),
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            if (rows.isEmpty)
              Text(
                empty,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ...rows,
          ],
        ),
      ),
    ),
  );

  Widget person(Json p, List<Widget> actions) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const CircleAvatar(child: Icon(Icons.person_outline)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p['username'] as String,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    p['user_id'] as String,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 4, children: actions),
      ],
    ),
  );
  Widget button(Json p, String action, String label, {bool filled = false}) {
    void act() => run(() => app.friendAction(p['user_id'] as String, action));
    return filled
        ? FilledButton(onPressed: busy ? null : act, child: Text(label))
        : TextButton(onPressed: busy ? null : act, child: Text(label));
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      const Text(
        'Friends',
        style: TextStyle(fontSize: 32, fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 8),
      const Text(
        'Your Gravitas contacts who connect River are already your friends here. Contact requests, removals and blocks apply across your apps.',
      ),
      const SizedBox(height: 20),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          FilledButton.icon(
            onPressed: busy ? null : add,
            icon: const Icon(Icons.person_add_outlined),
            label: const Text('Add a friend'),
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.all(10),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
      ),
      const SizedBox(height: 16),
      TextField(
        onChanged: (v) => setState(() => query = v),
        decoration: const InputDecoration(
          prefixIcon: Icon(Icons.search),
          labelText: 'Find a friend or request',
        ),
      ),
      if (app.friendsError != null)
        section('Friends unavailable', [
          Text(app.friendsError!),
          TextButton(
            onPressed:
                () => run(app.friendsStatus == 403 ? app.login : app.refresh),
            child: Text(
              app.friendsStatus == 403 ? 'Reconnect with Gravitas' : 'Retry',
            ),
          ),
        ], ''),
      section(
        'Friend requests',
        [
          for (final p in app.requests
              .where((r) => r['direction'] == 'incoming')
              .where(matches))
            person(p, [
              button(p, 'accept', 'Accept', filled: true),
              button(p, 'ignore', 'Ignore'),
              button(p, 'block', 'Block'),
            ]),
        ],
        query.isEmpty
            ? 'No incoming requests.'
            : 'No requests match your search.',
      ),
      section('Sent requests', [
        for (final p in app.requests
            .where((r) => r['direction'] == 'outgoing')
            .where(matches))
          person(p, [button(p, 'cancel', 'Cancel request')]),
      ], 'No pending sent requests.'),
      section(
        'Your friends · ${app.friends.length}',
        [
          for (final p in app.friends.where(matches))
            person(p, [
              FilledButton.tonalIcon(
                onPressed:
                    busy
                        ? null
                        : () => run(() async {
                          await app.messageFriend(p['user_id'] as String);
                          if (mounted) widget.onConversation();
                        }),
                icon: const Icon(Icons.chat_bubble_outline, size: 18),
                label: const Text('Message'),
              ),
              PopupMenuButton<String>(
                enabled: !busy,
                tooltip: 'Options for ${p['username']}',
                onSelected:
                    (v) =>
                        run(() => app.friendAction(p['user_id'] as String, v)),
                itemBuilder:
                    (_) => const [
                      PopupMenuItem(
                        value: 'remove',
                        child: Text('Remove contact everywhere'),
                      ),
                      PopupMenuItem(
                        value: 'block',
                        child: Text('Block across apps'),
                      ),
                    ],
              ),
            ]),
        ],
        query.isEmpty
            ? 'Add someone you know to get started.'
            : 'No friends match your search.',
      ),
      if (app.otherContacts.isNotEmpty)
        section(
          'Other Gravitas contacts · ${app.otherContacts.length}',
          [
            const Text(
              'These contacts will appear as friends when they approve River’s contacts access.',
            ),
            for (final p in app.otherContacts.where(matches))
              person(p, [
                button(p, 'remove', 'Remove contact everywhere'),
                button(p, 'block', 'Block across apps'),
              ]),
          ],
          'All your contacts with River access appear above.',
        ),
      section('Blocked people', [
        const Text(
          'Blocking applies across Gravitas apps and stops contact requests and direct messages. You may still share space channels.',
        ),
        for (final p in app.blocked.where(matches))
          person(p, [button(p, 'unblock', 'Unblock')]),
      ], 'No blocked people.'),
    ],
  );
}
