import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'api.dart';
import 'publishing_widgets.dart';
import 'friends_view.dart';
import 'content_widgets.dart';
import 'workspace_widgets.dart';
import 'attachment_widgets.dart';
import 'call_widgets.dart';
import 'file_models.dart' show FileScope;

void main() {
  runApp(const RiverApp());
}

const blue = Color(0xff185adb),
    ink = Color(0xff172d4b),
    muted = Color(0xff64748b);

class RiverApp extends StatefulWidget {
  const RiverApp({super.key, this.api, this.boot = true});
  final RiverApi? api;
  final bool boot;
  @override
  State<RiverApp> createState() => _RiverAppState();
}

class _RiverAppState extends State<RiverApp> with WidgetsBindingObserver {
  late final app = widget.api ?? RiverApi();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.boot) unawaited(app.boot());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    app.active = state == AppLifecycleState.resumed;
    if (app.active && app.user != null) unawaited(app.refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    app.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: app,
    builder: (_, _) => MaterialApp(
      key: ValueKey(app.user?['sub']),
      title: 'River',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: blue,
          primary: blue,
          surface: Colors.white,
        ),
        scaffoldBackgroundColor: const Color(0xfff4f7fc),
        textTheme: const TextTheme(bodyMedium: TextStyle(color: ink)),
        cardTheme: const CardThemeData(
          elevation: 0,
          color: Colors.white,
          margin: EdgeInsets.zero,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xfff4f7fc),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
        ),
      ),
      home: app.loading
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : deepLink() ?? RiverShell(key: ValueKey(app.user?['sub']), app: app),
    ),
  );
  Widget? deepLink() {
    final parts = Uri.base.pathSegments;
    if (parts.length == 2 && parts[0] == 'posts' && parts[1].startsWith(r'$')) {
      return PostScreen(app: app, event: parts[1]);
    }
    if (parts.length == 3 && parts[0] == 'spaces' && parts[2] == 'posts') {
      return BlogScreen(app: app, room: parts[1]);
    }
    return null;
  }
}

class RiverShell extends StatefulWidget {
  const RiverShell({super.key, required this.app});
  final RiverApi app;
  @override
  State<RiverShell> createState() => _RiverShellState();
}

class _RiverShellState extends State<RiverShell> {
  RiverApi get app => widget.app;
  String section = 'Home', filter = 'Chat';
  final draft = TextEditingController();
  final attachments = <Json>[];
  final timeline = ScrollController();
  String? renderedList, renderedLast;
  bool newMessages = false, chatPreview = false;
  final collapsed = <String>{};
  @override
  void initState() {
    super.initState();
    timeline.addListener(scrolled);
  }

  void scrolled() {
    if (timeline.hasClients && timeline.position.extentAfter < 60) {
      if (newMessages) setState(() => newMessages = false);
      markVisibleRead();
    }
  }

  void markVisibleRead() {
    if (!app.active || !(ModalRoute.of(context)?.isCurrent ?? true)) return;
    final id = app.selected,
        event = app.events.lastOrNull?['event_id'] as String?;
    if (id != null && event != null) {
      unawaited(action(() => app.markRead(id, event)));
    }
  }

  void scrollLatest(String id) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || app.selected != id || !timeline.hasClients) return;
      timeline.jumpTo(timeline.position.maxScrollExtent);
      markVisibleRead();
    });
  }

  String? retryTxn, retryPayload;
  final scaffold = GlobalKey<ScaffoldState>();
  bool sending = false;
  @override
  void dispose() {
    timeline.dispose();
    draft.dispose();
    super.dispose();
  }

  Future<void> action(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  void open(String? id) {
    scaffold.currentState?.closeDrawer();
    setState(() {
      section = 'Home';
      filter = 'Chat';
      retryTxn = null;
      draft.clear();
      attachments.clear();
    });
    unawaited(app.open(id));
  }

  Future<String?> ask(String title, String label, {int maxLength = 160}) async {
    final c = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLength: maxLength,
          decoration: InputDecoration(labelText: label),
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
              if (c.text.trim().isNotEmpty) {
                Navigator.pop(ctx, c.text.trim());
              }
            },
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    c.dispose();
    return result;
  }

  Future<void> create(String kind) async {
    if (kind == 'dm') {
      final created = await showDialog<bool>(
        context: context,
        builder: (_) => ConversationPicker(app: app),
      );
      if (created == true && mounted) {
        setState(() {
          section = 'Home';
          filter = 'Chat';
          draft.clear();
        });
      }
      return;
    }
    final name = await ask(
      kind == 'space' ? 'Create a space' : 'New conversation',
      kind == 'space' ? 'Space name' : 'Conversation name',
    );
    if (name != null) {
      await action(() => app.create(name, kind));
      if (mounted) {
        setState(() {
          section = 'Home';
          filter = 'Chat';
          draft.clear();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (app.user == null) return welcome();
    final group = app.groups.where((g) => g['id'] == app.selected).firstOrNull;
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 1000;
        final body = Column(
          children: [
            RiverCallBar(api: app),
            if (app.friendsStatus == 403)
              MaterialBanner(
                content: const Text(
                  'Reconnect with Gravitas to approve contacts access and find your River friends.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => action(app.login),
                    child: const Text('Reconnect'),
                  ),
                ],
              ),
            if (app.error != null)
              MaterialBanner(
                content: Text(app.error!),
                actions: [
                  TextButton(
                    onPressed: () => app.refresh(),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            Expanded(
              child: group != null
                  ? groupView(group)
                  : section == 'Account'
                  ? AccountPanel(app: app)
                  : section == 'Friends'
                  ? FriendsView(
                      app: app,
                      onConversation: () => setState(() {
                        section = 'Home';
                        filter = 'Chat';
                        draft.clear();
                      }),
                    )
                  : home(),
            ),
          ],
        );
        return Scaffold(
          key: scaffold,
          appBar: wide
              ? null
              : AppBar(
                  title: Text(
                    group?['name'] as String? ?? 'River',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  actions: [
                    IconButton(
                      tooltip: 'Refresh',
                      onPressed: () => app.refresh(),
                      icon: const Icon(Icons.refresh),
                    ),
                    IconButton(
                      tooltip: 'New space',
                      onPressed: () => create('space'),
                      icon: const Icon(Icons.add),
                    ),
                  ],
                ),
          drawer: wide ? null : Drawer(child: SafeArea(child: navigation())),
          body: Row(
            children: [
              if (wide) SizedBox(width: 260, child: navigation()),
              Expanded(child: body),
            ],
          ),
        );
      },
    );
  }

  Widget welcome() => Scaffold(
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.waves_rounded, color: blue, size: 64),
              const SizedBox(height: 20),
              const Text(
                'river',
                style: TextStyle(
                  fontSize: 52,
                  fontWeight: FontWeight.w800,
                  color: ink,
                  letterSpacing: -2,
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'A little closer,\nwherever you are.',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w700,
                  height: 1.15,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Your Gravitas spaces, conversations and ideas, together in one place.',
                style: TextStyle(fontSize: 17, color: muted),
              ),
              const SizedBox(height: 32),
              FilledButton.icon(
                onPressed: app.pairingLabel == null
                    ? () => action(app.login)
                    : null,
                icon: const Icon(Icons.arrow_forward),
                label: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('Continue with Gravitas'),
                ),
              ),
              if (app.pairingLabel != null)
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: Text(
                    'In your browser, confirm device ${app.pairingLabel}. Then return here.',
                  ),
                ),
              const SizedBox(height: 24),
              const Text(
                'Messages, ideas and calls, connected through Gravitas.',
                style: TextStyle(color: muted, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  Widget navigation() => Material(
    color: Colors.white,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 30, 24, 24),
          child: Row(
            children: [
              Icon(Icons.waves_rounded, color: blue, size: 32),
              SizedBox(width: 10),
              Text(
                'river',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 30,
                  letterSpacing: -1,
                ),
              ),
            ],
          ),
        ),
        for (final entry in [
          ('Home', Icons.home_outlined),
          ('Friends', Icons.people_outline),
          ('Account', Icons.settings_outlined),
        ])
          ListTile(
            selected: app.selected == null && section == entry.$1,
            selectedColor: blue,
            leading: Icon(entry.$2),
            title: Text(entry.$1),
            trailing: entry.$1 == 'Friends' && app.incomingRequests > 0
                ? Badge(label: Text('${app.incomingRequests}'))
                : null,
            onTap: () {
              scaffold.currentState?.closeDrawer();
              setState(() => section = entry.$1);
              unawaited(app.open(null));
            },
          ),
        const Divider(indent: 20, endIndent: 20),
        Expanded(
          child: ListView(
            children: [
              for (final kind in ['space', 'dm']) ...[
                ListTile(
                  dense: true,
                  title: Text(
                    kind == 'space' ? 'YOUR SPACES' : 'CONVERSATIONS',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: muted,
                      letterSpacing: 1,
                    ),
                  ),
                  trailing: IconButton(
                    tooltip: kind == 'space' ? 'New space' : 'New conversation',
                    icon: const Icon(Icons.add, size: 18),
                    onPressed: () => create(kind),
                  ),
                ),
                for (final g in app.groups.where(
                  (g) => kind == 'dm'
                      ? ['dm', 'group'].contains(g['kind'])
                      : ![
                          'dm',
                          'group',
                          'channel',
                          'post_comments',
                        ].contains(g['kind']),
                ))
                  navigationGroup(g, kind),
              ],
            ],
          ),
        ),
        const Divider(),
        ListTile(
          leading: const CircleAvatar(
            backgroundColor: Color(0xffe8efff),
            child: Icon(Icons.person_outline, color: blue),
          ),
          title: Text(app.user?['username'] as String? ?? ''),
          subtitle: const Text('Gravitas account'),
          trailing: IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout, size: 19),
            onPressed: () => action(app.logout),
          ),
        ),
        const SizedBox(height: 12),
      ],
    ),
  );
  Widget navigationGroup(Json g, String kind) => Column(
    children: [
      ListTile(
        selected: app.selected == g['id'],
        leading: Icon(
          g['membership'] == 'invite'
              ? Icons.mark_email_unread_outlined
              : kind == 'space'
              ? Icons.grid_view_outlined
              : Icons.chat_bubble_outline,
          size: 20,
        ),
        title: Text(g['name'] as String, overflow: TextOverflow.ellipsis),
        subtitle: g['membership'] == 'invite' ? const Text('Invitation') : null,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if ((g['unread_count'] as int? ?? 0) > 0)
              Badge(label: Text('${g['unread_count']}')),
            if (kind == 'space')
              IconButton(
                tooltip: collapsed.contains(g['id'])
                    ? 'Expand channels'
                    : 'Collapse channels',
                onPressed: () => setState(() {
                  if (!collapsed.add(g['id'] as String)) {
                    collapsed.remove(g['id']);
                  }
                }),
                icon: Icon(
                  collapsed.contains(g['id'])
                      ? Icons.chevron_right
                      : Icons.expand_more,
                ),
              ),
          ],
        ),
        onLongPress: kind == 'space'
            ? () => setState(() {
                if (!collapsed.add(g['id'] as String)) {
                  collapsed.remove(g['id']);
                }
              })
            : null,
        onTap: () => open(g['id'] as String),
      ),
      if (kind == 'space' &&
          !collapsed.contains(g['id']) &&
          g['membership'] == 'join')
        for (final channel in app.channels(g['id'] as String))
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.only(left: 42, right: 20),
            selected: app.selected == channel['id'],
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
            trailing: (channel['unread_count'] as int? ?? 0) > 0
                ? Badge(label: Text('${channel['unread_count']}'))
                : null,
            onTap: () => open(channel['id'] as String),
          ),
    ],
  );

  Widget panel(String title, IconData icon, List<Widget> children) => Card(
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: blue),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 17,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          ...children,
        ],
      ),
    ),
  );
  Widget empty(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Text(text, style: const TextStyle(color: muted, height: 1.5)),
  );
  Widget home() => LayoutBuilder(
    builder: (context, box) => ListView(
      padding: EdgeInsets.all(box.maxWidth < 600 ? 20 : 36),
      children: [
        const Text(
          'A LITTLE CLOSER, WHEREVER YOU ARE',
          style: TextStyle(
            color: blue,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'Welcome to your river, ${app.user?['username']}.',
          style: TextStyle(
            fontSize: box.maxWidth < 600 ? 29 : 38,
            fontWeight: FontWeight.w800,
            color: ink,
            letterSpacing: -1,
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          'Catch up, find your people, or start something good.',
          style: TextStyle(color: muted, fontSize: 16),
        ),
        const SizedBox(height: 24),
        Wrap(
          spacing: 12,
          runSpacing: 12,
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
        const SizedBox(height: 28),
        CatchUpPanel(app: app),
        const SizedBox(height: 18),
        if (app.threads.isNotEmpty)
          panel('Your recent threads', Icons.reply, [
            for (final e in app.threads)
              ListTile(
                title: Text(
                  rendered(e)['body'] as String? ?? 'Thread',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text('${e['reply_count']} replies'),
                onTap: () =>
                    openRiverThread(context, app, e['group_id'] as String, e),
              ),
          ]),
        const SizedBox(height: 18),
        for (final kind in ['post', 'discussion'])
          Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: panel(
              kind == 'post' ? 'Recent posts' : 'Recent discussions',
              kind == 'post' ? Icons.article_outlined : Icons.forum_outlined,
              [
                if (!app.recent.any(
                  (e) => e['type'] == 'cool.gravitas.river.$kind.v1',
                ))
                  empty(
                    'Nothing here yet. Share an idea in one of your spaces.',
                  ),
                for (final e
                    in app.recent
                        .where(
                          (e) => e['type'] == 'cool.gravitas.river.$kind.v1',
                        )
                        .take(6))
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(rendered(e)['title'] as String),
                    subtitle: Text('${e['group_name']} · ${e['sender']}'),
                    trailing: const Icon(Icons.north_east, size: 18),
                    onTap: () => openRiverThread(
                      context,
                      app,
                      e['group_id'] as String,
                      e,
                    ),
                  ),
              ],
            ),
          ),
        panel('Your people & spaces', Icons.chat_bubble_outline, [
          if (app.groups.isEmpty)
            empty(
              'Bring your people together. Create your first space or conversation.',
            ),
          for (final g
              in app.groups
                  .where((g) => ['space', 'dm', 'group'].contains(g['kind']))
                  .take(12))
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                g['kind'] == 'dm' ? Icons.chat_outlined : Icons.tag,
                color: blue,
              ),
              title: Text(g['name'] as String),
              subtitle: Text(
                g['membership'] == 'invite'
                    ? 'You have an invitation'
                    : '${(g['members'] as List).length} members',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => open(g['id'] as String),
            ),
        ]),
        const SizedBox(height: 18),
        panel('Drop-in calls', Icons.graphic_eq, [
          if (app.activeCalls.isEmpty)
            empty(
              'No one is in a call yet. Join a voice channel or start a call in a conversation.',
            ),
          for (final call in app.activeCalls)
            ListTile(
              leading: const Icon(Icons.graphic_eq, color: blue),
              title: Text(call['name'] as String),
              subtitle: Text(
                ((call['participants'] as List).cast<Json>())
                    .map((p) => p['user_id'])
                    .join(', '),
              ),
              trailing: const Icon(Icons.call_outlined),
              onTap: () {
                final target = app.groups
                    .where((g) => g['id'] == call['group_id'])
                    .firstOrNull;
                if (target != null) joinRiverCall(context, app, target);
              },
            ),
          for (final channel in app.groups.where(
            (g) =>
                g['channel_kind'] == 'drop_in' &&
                g['membership'] == 'join' &&
                !app.activeCalls.any((c) => c['group_id'] == g['id']),
          ))
            ListTile(
              leading: const Icon(Icons.headphones_outlined),
              title: Text(channel['name'] as String),
              subtitle: const Text('Join a voice room'),
              onTap: () => joinRiverCall(context, app, channel),
            ),
        ]),
      ],
    ),
  );
  Future<void> members(Json g) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * .65,
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                '${g['name']} · Members',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (g['kind'] == 'channel')
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('Channel members are managed by the space.'),
                ),
              for (final m in (g['members'] as List).cast<Json>())
                ListTile(
                  leading: const CircleAvatar(
                    child: Icon(Icons.person_outline),
                  ),
                  title: Text(m['username'] as String),
                  trailing:
                      g['owner'] == true &&
                          g['kind'] != 'channel' &&
                          m['principal_id'] != app.user?['sub']
                      ? IconButton(
                          tooltip: 'Remove ${m['username']}',
                          icon: const Icon(Icons.person_remove_outlined),
                          onPressed: () {
                            Navigator.pop(ctx);
                            action(
                              () => app.membership(
                                g['id'] as String,
                                'remove',
                                app.userId(m['username'] as String),
                              ),
                            );
                          },
                        )
                      : null,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget groupView(Json g) {
    if (g['membership'] == 'invite') {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.mail_outline, size: 48, color: blue),
              Text(
                'Join ${g['name']}?',
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () =>
                    action(() => app.membership(g['id'] as String, 'accept')),
                child: const Text('Accept invitation'),
              ),
              TextButton(
                onPressed: () =>
                    action(() => app.membership(g['id'] as String, 'leave')),
                child: const Text('Decline'),
              ),
            ],
          ),
        ),
      );
    }
    final viewFilter = g['kind'] == 'channel' ? 'Chat' : filter;
    final items = app.events.where((e) {
      if (viewFilter == 'Chat') {
        final relation = (e['content'] as Json)['m.relates_to'] as Json?;
        return (e['type'] == 'm.room.message' ||
                e['type'] == 'cool.gravitas.river.invitation.v1') &&
            relation?['rel_type'] != 'm.thread';
      }
      return e['type'] ==
          'cool.gravitas.river.${viewFilter == 'Posts' ? 'post' : 'discussion'}.v1';
    }).toList();
    final listKey = '${g['id']}:$viewFilter';
    final last = items.lastOrNull?['event_id'] as String?;
    if (renderedList != listKey || renderedLast != last) {
      final stick =
          renderedList != listKey ||
          !timeline.hasClients ||
          timeline.position.extentAfter < 100;
      renderedList = listKey;
      renderedLast = last;
      if (stick) {
        newMessages = false;
        scrollLatest(g['id'] as String);
      } else {
        newMessages = true;
      }
    }
    return Column(
      children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.all(18),
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: 'Home',
                    onPressed: () => open(null),
                    icon: const Icon(Icons.arrow_back),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          g['name'] as String,
                          style: const TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          '${g['kind'] == 'dm'
                              ? 'Conversation'
                              : g['kind'] == 'channel'
                              ? 'Channel'
                              : 'Space'} · ${(g['members'] as List).length} members',
                          style: const TextStyle(color: muted, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  if (['dm', 'group'].contains(g['kind']) ||
                      g['channel_kind'] == 'drop_in')
                    IconButton(
                      tooltip: 'Join call',
                      icon: const Icon(Icons.call_outlined),
                      onPressed: () => joinRiverCall(context, app, g),
                    ),
                  PopupMenuButton<String>(
                    tooltip: 'Group options',
                    onSelected: (v) => action(() async {
                      if (v == 'channel' || v == 'drop_in') {
                        final name = await ask(
                          'Create a channel',
                          'Channel name',
                        );
                        if (name != null) {
                          await app.createChannel(
                            g['id'] as String,
                            name,
                            v == 'channel' ? 'text' : 'drop_in',
                          );
                          if (mounted) {
                            setState(() {
                              filter = 'Chat';
                              draft.clear();
                            });
                          }
                        }
                      }
                      if (v == 'share-space') {
                        final spaces = app.spaces
                            .where(
                              (x) =>
                                  x['owner'] == true &&
                                  x['membership'] == 'join',
                            )
                            .toList();
                        if (mounted) {
                          final id = await showDialog<String>(
                            context: context,
                            builder: (ctx) => SimpleDialog(
                              title: const Text('Invite to a space'),
                              children: [
                                if (spaces.isEmpty)
                                  const Padding(
                                    padding: EdgeInsets.all(20),
                                    child: Text('Create a space first.'),
                                  ),
                                for (final space in spaces)
                                  SimpleDialogOption(
                                    onPressed: () =>
                                        Navigator.pop(ctx, space['id']),
                                    child: Text(space['name'] as String),
                                  ),
                              ],
                            ),
                          );
                          if (id != null) {
                            await app.inviteSpace(g['id'] as String, id);
                          }
                        }
                      }
                      if (v == 'description') {
                        final description = await ask(
                          'Space description',
                          'Description',
                          maxLength: 500,
                        );
                        if (description != null) {
                          await app.request(
                            '/api/groups/${g['id']}',
                            method: 'PATCH',
                            body: {
                              'name': g['name'],
                              'description': description,
                            },
                          );
                          await app.refresh();
                        }
                      }
                      if (v == 'members') {
                        await members(g);
                      }
                      if (v == 'invite') {
                        final u = await ask(
                          'Invite a person',
                          '@username:gravitas.cool',
                        );
                        if (u != null) {
                          await app.membership(g['id'] as String, 'invite', u);
                        }
                      }
                      if (v == 'rename') {
                        final name = await ask('Rename group', 'Name');
                        if (name != null) {
                          await app.request(
                            '/api/groups/${g['id']}',
                            method: 'PATCH',
                            body: {'name': name},
                          );
                          await app.refresh();
                        }
                      }
                      if (v == 'leave') {
                        await app.membership(g['id'] as String, 'leave');
                      }
                    }),
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'members',
                        child: Text('Members'),
                      ),
                      if (['dm', 'group'].contains(g['kind']))
                        const PopupMenuItem(
                          value: 'share-space',
                          child: Text('Invite to a space'),
                        ),
                      if (g['kind'] == 'space' && g['owner'] == true) ...[
                        const PopupMenuItem(
                          value: 'description',
                          child: Text('Edit description'),
                        ),
                        const PopupMenuItem(
                          value: 'channel',
                          child: Text('New text channel'),
                        ),
                        const PopupMenuItem(
                          value: 'drop_in',
                          child: Text('New drop-in channel'),
                        ),
                      ],
                      if (g['owner'] == true && g['kind'] != 'channel')
                        const PopupMenuItem(
                          value: 'invite',
                          child: Text('Invite member'),
                        ),
                      if (g['owner'] == true)
                        const PopupMenuItem(
                          value: 'rename',
                          child: Text('Rename'),
                        ),
                      if (g['kind'] != 'channel')
                        const PopupMenuItem(
                          value: 'leave',
                          child: Text('Leave group'),
                        ),
                    ],
                  ),
                ],
              ),
              if ((g['description'] as String? ?? '').isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(g['description'] as String),
                  ),
                ),
              if (g['parent_id'] != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => open(g['parent_id'] as String),
                    icon: const Icon(Icons.grid_view_outlined, size: 16),
                    label: const Text('Back to space'),
                  ),
                ),
              if (g['kind'] == 'space' &&
                  app.channels(g['id'] as String).isNotEmpty)
                SizedBox(
                  height: 44,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final c in app.channels(g['id'] as String))
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ActionChip(
                            avatar: Icon(
                              c['channel_kind'] == 'drop_in'
                                  ? Icons.headphones_outlined
                                  : Icons.tag,
                              size: 16,
                            ),
                            label: Text(c['name'] as String),
                            onPressed: () => open(c['id'] as String),
                          ),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              if (g['kind'] != 'channel')
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'Chat',
                      label: Text('Chat'),
                      icon: Icon(Icons.tag),
                    ),
                    ButtonSegment(
                      value: 'Discussions',
                      label: Text('Discussions'),
                    ),
                    ButtonSegment(value: 'Posts', label: Text('Posts')),
                  ],
                  selected: {filter},
                  onSelectionChanged: (v) => setState(() => filter = v.first),
                ),
            ],
          ),
        ),
        if (newMessages)
          TextButton.icon(
            onPressed: () {
              setState(() => newMessages = false);
              scrollLatest(g['id'] as String);
            },
            icon: const Icon(Icons.arrow_downward, size: 16),
            label: const Text('New messages'),
          ),
        if (app.nextCursor != null)
          TextButton.icon(
            onPressed: app.loadingOlder ? null : () => action(app.older),
            icon: const Icon(Icons.history, size: 16),
            label: Text(
              app.loadingOlder ? 'Loading…' : 'Load earlier messages',
            ),
          ),
        if (g['channel_kind'] == 'drop_in')
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'Drop in to talk, turn on your camera or share your screen. Room chat stays here.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        Expanded(
          child: viewFilter != 'Chat'
              ? EntryFeed(
                  key: ValueKey('${g['id']}:$viewFilter'),
                  app: app,
                  room: g['id'] as String,
                  kind: viewFilter == 'Posts' ? 'post' : 'discussion',
                )
              : items.isEmpty
              ? Center(
                  child: Text(
                    'Start the ${viewFilter == 'Chat' ? 'conversation' : viewFilter.toLowerCase()}.',
                    style: const TextStyle(color: muted),
                  ),
                )
              : ListView.builder(
                  controller: timeline,
                  padding: const EdgeInsets.all(20),
                  itemCount: items.length,
                  itemBuilder: (context, index) => eventCard(items[index], g),
                ),
        ),
        SafeArea(
          top: false,
          child: Container(
            color: Colors.white,
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                if (attachments.isNotEmpty && viewFilter == 'Chat')
                  PendingAttachments(
                    files: attachments,
                    remove: (f) => setState(() => attachments.remove(f)),
                  ),
                if (viewFilter == 'Chat')
                  Row(
                    children: [
                      Expanded(child: MarkdownToolbar(controller: draft)),
                      IconButton(
                        tooltip: chatPreview
                            ? 'Write message'
                            : 'Preview message',
                        onPressed: () =>
                            setState(() => chatPreview = !chatPreview),
                        icon: Icon(
                          chatPreview
                              ? Icons.edit_outlined
                              : Icons.visibility_outlined,
                        ),
                      ),
                    ],
                  ),
                if (viewFilter == 'Chat' && chatPreview)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 150),
                    child: SingleChildScrollView(child: RichBody(draft.text)),
                  ),
                if (viewFilter != 'Chat')
                  FilledButton.icon(
                    onPressed: () => showDialog<bool>(
                      context: context,
                      builder: (_) => EntryEditor(
                        app: app,
                        room: g['id'] as String,
                        kind: viewFilter == 'Posts' ? 'post' : 'discussion',
                      ),
                    ),
                    icon: const Icon(Icons.edit_outlined),
                    label: Text(
                      viewFilter == 'Posts' ? 'New post' : 'New discussion',
                    ),
                  )
                else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      IconButton(
                        tooltip: 'Attach files',
                        onPressed: sending || app.files == null
                            ? null
                            : () => action(() async {
                                final picked = await app.files!.pick(
                                  FileScope('room', g['id'] as String),
                                  existing: attachments,
                                );
                                if (mounted && app.selected == g['id']) {
                                  setState(() => attachments.addAll(picked));
                                }
                              }),
                        icon: const Icon(Icons.attach_file),
                      ),
                      Expanded(
                        child: MarkdownShortcuts(
                          controller: draft,
                          onSubmit: () => send(g),
                          child: TextField(
                            controller: draft,
                            minLines: 1,
                            maxLines: 5,
                            maxLength: 16000,
                            decoration: InputDecoration(
                              hintText: viewFilter == 'Chat'
                                  ? 'Message ${g['name']}…'
                                  : 'Write ${viewFilter == 'Posts' ? 'a post' : 'a discussion'}…',
                              counterText: '',
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      IconButton.filled(
                        tooltip: 'Send',
                        onPressed: sending ? null : () => send(g),
                        icon: Icon(
                          sending ? Icons.hourglass_top : Icons.arrow_upward,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget eventCard(Json e, Json g) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: e['type'] == 'cool.gravitas.river.invitation.v1'
        ? InvitationCard(app: app, event: e)
        : ContentCard(
            app: app,
            room: g['id'] as String,
            event: e,
            reply: () async {
              final relation = (e['content'] as Json)['m.relates_to'] as Json?;
              final rootId = relation?['rel_type'] == 'm.thread'
                  ? relation!['event_id'] as String
                  : e['event_id'] as String;
              await Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => e['type'] == 'cool.gravitas.river.post.v1'
                      ? PostScreen(app: app, event: rootId)
                      : ThreadScreen(
                          app: app,
                          room: g['id'] as String,
                          rootId: rootId,
                        ),
                ),
              );
              if (mounted) await app.refresh();
            },
          ),
  );

  Future<void> send(Json g) async {
    final body = draft.text.trim();
    if ((body.isEmpty && attachments.isEmpty) || sending) return;
    const type = 'm.room.message';
    final content = <String, dynamic>{
      'body': body.isEmpty
          ? attachments.map((f) => f['name']).join(', ')
          : body,
      if (attachments.isNotEmpty)
        'cool.gravitas.river.attachments': List<Json>.from(attachments),
      'msgtype': 'm.text',
      'cool.gravitas.river': {'version': 1, 'kind': 'message'},
    };
    setState(() => sending = true);
    final payload = jsonEncode(content);
    if (payload != retryPayload) {
      retryTxn = transactionId();
      retryPayload = payload;
    }
    retryTxn ??= transactionId();
    try {
      await app.send(g['id'] as String, type, content, retryTxn!);
      for (final f
          in (content['cool.gravitas.river.attachments'] as List<Json>?) ??
              <Json>[]) {
        await app.files?.publish(f);
      }
      if (mounted && app.selected == g['id'] && draft.text.trim() == body) {
        draft.clear();
        attachments.clear();
        retryTxn = null;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e · Your draft is kept.')));
      }
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }
}
