import 'package:flutter/material.dart';
import 'api.dart';
import 'workspace_widgets.dart';

class RiverHome extends StatelessWidget {
  const RiverHome({
    super.key,
    required this.app,
    required this.open,
    required this.create,
  });
  final RiverApi app;
  final ValueChanged<String?> open;
  final ValueChanged<String> create;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final catchUp = CatchUpPanel(app: app, open: open);
      final voices = HomeSection(
        title: 'Active Voice Rooms',
        icon: Icons.graphic_eq,
        child: Column(
          children: [
            if (!app.activeCalls.any(
              (c) => (c['participants'] as List? ?? []).isNotEmpty,
            ))
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'No active voice rooms. Drop into a room in one of your spaces.',
                ),
              ),
            for (final call in app.activeCalls.where(
              (c) => (c['participants'] as List? ?? []).isNotEmpty,
            ))
              if (app.group(call['group_id'] as String) case final room?)
                VoiceRoomTile(app: app, channel: room),
          ],
        ),
      );
      final people = FavouritePeople(key: ValueKey(app.accountKey), app: app);
      return ListView(
        padding: EdgeInsets.all(box.maxWidth < 600 ? 12 : 24),
        children: [
          Text(
            'Welcome, ${app.displayName(app.user?['user_id'] as String? ?? app.user?['username'] as String? ?? '')}.',
            style: Theme.of(
              context,
            ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: () => create('dm'),
                icon: const Icon(Icons.add),
                label: const Text('New conversation'),
              ),
              OutlinedButton.icon(
                onPressed: () => create('space'),
                icon: const Icon(Icons.grid_view_outlined),
                label: const Text('Create a space'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (box.maxWidth >= 850)
            Row(
              key: const ValueKey('home-columns'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 2, child: catchUp),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [voices, const SizedBox(height: 16), people],
                  ),
                ),
              ],
            )
          else ...[
            voices,
            const SizedBox(height: 16),
            catchUp,
            const SizedBox(height: 16),
            people,
          ],
        ],
      );
    },
  );
}

class HomeSection extends StatelessWidget {
  const HomeSection({
    super.key,
    required this.title,
    required this.icon,
    required this.child,
  });
  final String title;
  final IconData icon;
  final Widget child;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    ),
  );
}

class FavouritePeople extends StatefulWidget {
  const FavouritePeople({super.key, required this.app});
  final RiverApi app;
  @override
  State<FavouritePeople> createState() => _FavouritePeopleState();
}

class _FavouritePeopleState extends State<FavouritePeople> {
  Set<String> favourites = {};
  bool loaded = false, saving = false;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final saved = await widget.app.favouritePeople();
      if (mounted) {
        setState(() {
          favourites = saved;
          loaded = true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          error = 'Could not load your favourites.';
          loaded = false;
        });
      }
    }
  }

  Future<void> toggle(String id) async {
    if (!loaded || saving) return;
    final next = {...favourites};
    if (!next.add(id)) next.remove(id);
    setState(() => saving = true);
    try {
      await widget.app.saveFavouritePeople(next);
      if (mounted) {
        setState(() {
          favourites = next;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Could not save your favourites. Try again.');
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final people = [...app.friends]
      ..sort((a, b) {
        final priority = (favourites.contains(b['user_id']) ? 1 : 0).compareTo(
          favourites.contains(a['user_id']) ? 1 : 0,
        );
        return priority != 0
            ? priority
            : app
                  .displayName(a['user_id'] as String)
                  .compareTo(app.displayName(b['user_id'] as String));
      });
    return HomeSection(
      title: 'Your Favourite People',
      icon: Icons.star_outline,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (error != null) Text(error!),
          if (!loaded && error != null)
            TextButton(onPressed: load, child: const Text('Retry favourites')),
          if (people.isEmpty)
            const Text('Add friends to keep your favourite people close.'),
          if (people.isNotEmpty && favourites.isEmpty)
            const Text('Star people to keep them at the top.'),
          for (final person in people)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                Icons.circle,
                size: 10,
                color: app.online.contains(person['user_id'])
                    ? Colors.green
                    : Colors.grey,
              ),
              title: Text(
                app.displayName(person['user_id'] as String),
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                app.online.contains(person['user_id']) ? 'Online' : 'Offline',
              ),
              trailing: IconButton(
                tooltip: favourites.contains(person['user_id'])
                    ? 'Remove favourite'
                    : 'Add favourite',
                onPressed: !loaded || saving
                    ? null
                    : () => toggle(person['user_id'] as String),
                icon: Icon(
                  favourites.contains(person['user_id'])
                      ? Icons.star
                      : Icons.star_outline,
                ),
              ),
              onTap: () async {
                try {
                  await app.messageFriend(person['user_id'] as String);
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text('$e')));
                  }
                }
              },
            ),
        ],
      ),
    );
  }
}
