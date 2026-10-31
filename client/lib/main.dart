import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'api.dart';
import 'username_login.dart';
import 'publishing_widgets.dart';
import 'friends_view.dart';
import 'content_widgets.dart';
import 'workspace_widgets.dart';
import 'home_widgets.dart';
import 'river_design.dart';
import 'destination_widgets.dart';
import 'attachment_widgets.dart';
import 'matrix_attachment_widgets.dart';
import 'matrix_setup.dart';
import 'call_widgets.dart';
import 'file_models.dart' show FileScope;
import 'rich_composer.dart';
import 'media_widgets.dart';

import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;

void main() {
  runApp(const RiverApp());
}

const blue = riverAccent, ink = riverInk, muted = riverMuted;

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
    if (app.active) unawaited(app.resumeAuthentication());
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
      key: ValueKey(app.accountKey),
      title: 'River',
      builder: (context, child) => LinkedImageScope(
        cache: app.linkedImages,
        networkAvailable: !app.networkUnavailable,
        child: child!,
      ),
      localizationsDelegates: FlutterQuillLocalizations.localizationsDelegates,
      debugShowCheckedModeBanner: false,
      theme: riverTheme(),
      home: app.loading
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : app.requiresMatrixSetup
          ? MatrixSetup(app: app)
          : deepLink() ?? RiverShell(key: ValueKey(app.accountKey), app: app),
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
  String section = 'Home', filter = 'Chat', conversationQuery = '';
  bool searchOpen = false, spaceChat = false;
  final draft = TextEditingController();
  final attachments = <Json>[];
  final timeline = ScrollController();
  String? renderedList, renderedLast;
  bool newMessages = false;
  final collapsed = <String>{};
  @override
  void initState() {
    super.initState();
    timeline.addListener(scrolled);
    draft.addListener(composerChanged);
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

  bool _bindingComposer = false;
  int _composerRevision = 0;
  String? _composerAccount;
  final _lastDraftWrites = <String, String>{};
  String? retryTxn, retryPayload;

  Json composerSnapshot() => {
    'text': draft.text,
    'files': List<Json>.of(attachments),
    'txn': retryTxn,
    'payload': retryPayload,
  };

  void composerChanged() {
    if (!_bindingComposer) {
      _composerRevision++;
      unawaited(persistComposer());
    }
  }

  Future<void> persistComposer() async {
    final room = composerRoom;
    if (room == null ||
        !app.matrixConnected ||
        _composerAccount != app.accountKey) {
      return;
    }
    final value = composerSnapshot(), encoded = jsonEncode(composerSnapshot());
    if (_lastDraftWrites[room] == encoded) return;
    _lastDraftWrites[room] = encoded;
    await app.saveDraft(
      room,
      draft.text.isEmpty && attachments.isEmpty && retryTxn == null
          ? null
          : value,
    );
    if (app.cacheError != null && _lastDraftWrites[room] == encoded) {
      _lastDraftWrites.remove(room);
    }
  }

  String? composerRoom;
  final drafts =
      <
        String,
        ({String text, List<Json> files, String? txn, String? payload})
      >{};

  void bindComposer() {
    final id = app.selected;
    final room = id == null ? null : app.matrixRoom(id) ?? id;
    if (_composerAccount != app.accountKey) {
      drafts.clear();
      _lastDraftWrites.clear();
      composerRoom = null;
      _composerAccount = app.accountKey;
    }
    if (room == composerRoom) return;
    unawaited(persistComposer());
    _bindingComposer = true;
    if (composerRoom != null) {
      drafts[composerRoom!] = (
        text: draft.text,
        files: List.of(attachments),
        txn: retryTxn,
        payload: retryPayload,
      );
    }
    final saved = drafts.remove(room);
    composerRoom = room;
    draft.text = saved?.text ?? '';
    attachments
      ..clear()
      ..addAll(saved?.files ?? []);
    retryTxn = saved?.txn;
    retryPayload = saved?.payload;
    _bindingComposer = false;
    final revision = ++_composerRevision, account = app.accountKey;
    if (saved == null && room != null && app.matrixConnected) {
      unawaited(
        (() async {
          try {
            final value = await app.draft(room);
            if (!mounted ||
                account != app.accountKey ||
                room != composerRoom ||
                revision != _composerRevision ||
                value == null) {
              return;
            }
            setState(() {
              _bindingComposer = true;
              draft.text = value['text'] as String? ?? '';
              attachments
                ..clear()
                ..addAll(((value['files'] as List?) ?? []).cast<Json>());
              retryTxn = value['txn'] as String?;
              retryPayload = value['payload'] as String?;
              _bindingComposer = false;
            });
          } catch (_) {
            // Keep an editable composer when local storage cannot be opened.
          }
        })(),
      );
    }
  }

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

  String get activeDestination {
    final group = app.selected == null ? null : app.group(app.selected!);
    if (group == null) return section;
    if (supportsRiverEntries(app, group) &&
        ['Forums', 'Posts'].contains(section)) {
      return section;
    }
    return roomDestination(app, group);
  }

  void open(String? id, {String? destination}) {
    scaffold.currentState?.closeDrawer();
    final group = id == null ? null : app.group(id);
    final target =
        destination ?? (group == null ? 'Home' : roomDestination(app, group));
    setState(() {
      section = target;
      filter = target == 'Posts'
          ? 'Posts'
          : target == 'Forums'
          ? 'Discussions'
          : 'Chat';
      spaceChat = false;
    });
    unawaited(app.open(id));
  }

  Future<void> composeEntry(String destination) async {
    final spaces = destinationGroups(
      app,
      destination,
    ).where((g) => g['membership'] == 'join').toList();
    final room = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(
          destination == 'Posts'
              ? 'Post to a community'
              : 'Start a community discussion',
        ),
        children: [
          if (spaces.isEmpty)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text('Join or create a River community first.'),
            ),
          for (final space in spaces)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, space['id']),
              child: Text(space['name'] as String),
            ),
        ],
      ),
    );
    if (room == null || !mounted) return;
    open(room, destination: destination);
    await showDialog<bool>(
      context: context,
      builder: (_) => EntryEditor(
        app: app,
        room: room,
        kind: destination == 'Posts' ? 'post' : 'discussion',
      ),
    );
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
    if (kind == 'dm' || kind == 'matrix') {
      final created = await showDialog<bool>(
        context: context,
        builder: (_) =>
            ConversationPicker(app: app, matrixOnly: kind == 'matrix'),
      );
      if (created == true && mounted) {
        setState(() {
          section = kind == 'matrix' ? 'Matrix' : 'Chats';
          filter = 'Chat';
        });
      }
      return;
    }
    final name = await ask(
      kind == 'space' ? 'Create community' : 'New conversation',
      kind == 'space' ? 'Community name' : 'Conversation name',
    );
    if (name != null) {
      await action(() => app.create(name, kind));
      if (mounted) {
        setState(() {
          section = kind == 'space' ? 'Communities' : 'Chats';
          filter = 'Chat';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (app.user == null) {
      return app.finishingNativeSignIn ? finishSignIn() : welcome();
    }
    bindComposer();
    final group = app.groups.where((g) => g['id'] == app.selected).firstOrNull;
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 1000;
        final body = Column(
          children: [
            if (app.connectionWarning case final warning?)
              MaterialBanner(
                key: const ValueKey('network-unavailable'),
                leading: const Icon(Icons.sync_problem),
                content: Text(warning),
                actions: [
                  TextButton(
                    onPressed: () => action(app.retryConnections),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            if (app.cacheError != null)
              MaterialBanner(
                content: Text(app.cacheError!),
                actions: [
                  TextButton(
                    onPressed: () => app.refresh(),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            if (app.matrixEnabled &&
                !app.matrixConnected &&
                section != 'Account')
              MaterialBanner(
                content: Text(
                  app.matrix.error ??
                      (app.matrix.connecting
                          ? 'Confirm Matrix messaging in your browser, then return to River.'
                          : 'Connect this device to send encrypted messages. Your draft stays here.'),
                ),
                actions: [
                  TextButton(
                    key: const ValueKey('connect-matrix'),
                    onPressed: app.matrix.connecting
                        ? null
                        : () => action(() async {
                            if (app.user != null) {
                              await app.matrix.bind(app.user!);
                            }
                            await app.matrix.connect();
                            if (app.matrixConnected) await app.refresh();
                          }),
                    child: Text(
                      app.matrix.connecting ? 'Connecting…' : 'Connect',
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      section = 'Account';
                      app.selected = null;
                    }),
                    child: const Text('Device security'),
                  ),
                ],
              ),
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
            if (!wide) RiverCallBar(api: app),
            Expanded(
              child: group != null
                  ? groupView(group)
                  : section == 'Account'
                  ? AccountPanel(app: app)
                  : section == 'Friends'
                  ? FriendsView(
                      app: app,
                      onConversation: () => setState(() {
                        section = 'Chats';
                        filter = 'Chat';
                      }),
                    )
                  : riverDestinations.any((d) => d.name == section)
                  ? RiverDestinationView(
                      key: ValueKey(section),
                      app: app,
                      destination: section,
                      open: (id) => open(id, destination: section),
                      create: create,
                      friends: () => open(null, destination: 'Friends'),
                      compose: () => composeEntry(section),
                      thread: (room, event) =>
                          openRiverThread(context, app, room, event),
                    )
                  : home(),
            ),
          ],
        );
        return Scaffold(
          key: scaffold,
          appBar: wide || group?['membership'] == 'join'
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
                  ],
                ),
          bottomNavigationBar: wide || group != null
              ? null
              : mobileDestinations(),
          drawer: wide ? null : Drawer(child: SafeArea(child: navigation())),
          body: SafeArea(
            bottom: false,
            child: Row(
              children: [
                if (wide) SizedBox(width: 248, child: navigation()),
                if (wide) const VerticalDivider(width: 1),
                Expanded(child: body),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget finishSignIn() => Scaffold(
    key: const ValueKey('finish-native-sign-in'),
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.waves_rounded, color: blue, size: 64),
                const SizedBox(height: 20),
                Text(
                  'Finish signing in',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Your River device is linked. River could not load your account. Retry to continue with the sign-in you already approved.',
                ),
                if (app.error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    app.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () => action(app.boot),
                  child: const Text('Retry sign-in'),
                ),
                TextButton(
                  onPressed: () => action(app.logout),
                  child: const Text('Sign out'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

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
              UsernameLogin(
                defaultDomain: app.defaultDomain,
                onSubmit: (username) => app.login(username: username),
                onRegister: () => app.login(register: true),
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
  Future<void> settings() async {
    scaffold.currentState?.closeDrawer();
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        child: SizedBox(
          width: 620,
          height: MediaQuery.sizeOf(ctx).height * .85,
          child: Column(
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'Settings',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close settings',
                    onPressed: () => Navigator.pop(ctx),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              Expanded(
                child: AccountPanel(
                  app: app,
                  onSignOut: () async {
                    Navigator.pop(ctx);
                    await action(app.logout);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget mobileDestinations() => Material(
    color: Colors.white,
    child: SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: riverBorder)),
        ),
        child: Row(
          children: [
            for (final d in riverDestinations)
              Expanded(
                child: InkWell(
                  key: ValueKey('mobile-${d.name}'),
                  onTap: () => open(null, destination: d.name),
                  child: Semantics(
                    selected: activeDestination == d.name,
                    button: true,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 3,
                        vertical: 10,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            d.icon,
                            size: 21,
                            color: activeDestination == d.name ? blue : muted,
                          ),
                          const SizedBox(height: 4),
                          FittedBox(
                            child: Text(
                              d.name,
                              style: TextStyle(
                                fontSize: 10,
                                color: activeDestination == d.name
                                    ? blue
                                    : muted,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );

  Widget navigation() => Material(
    color: const Color(0xfff3f5fa),
    child: ListTileTheme(
      data: ListTileThemeData(
        dense: true,
        minTileHeight: 36,
        minLeadingWidth: 20,
        horizontalTitleGap: 10,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10),
        visualDensity: VisualDensity.compact,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
            child: Row(
              children: [
                const Icon(Icons.waves_rounded, color: blue, size: 24),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'river',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 24,
                      letterSpacing: -1,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: searchOpen ? 'Close search' : 'Search',
                  icon: Icon(searchOpen ? Icons.close : Icons.search, size: 19),
                  onPressed: () => setState(() {
                    searchOpen = !searchOpen;
                    if (!searchOpen) conversationQuery = '';
                  }),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                ListTile(
                  selected: app.selected == null && section == 'Home',
                  leading: const Icon(Icons.inbox_outlined, size: 19),
                  title: const Text('Home'),
                  onTap: () => open(null),
                ),
                for (final d in riverDestinations)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 1,
                    ),
                    child: ListTile(
                      key: ValueKey('destination-${d.name}'),
                      selected: activeDestination == d.name,
                      leading: Icon(d.icon, size: 19),
                      title: Text(
                        d.name,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      trailing:
                          destinationGroups(
                            app,
                            d.name,
                          ).any((g) => (g['unread_count'] as int? ?? 0) > 0)
                          ? const Icon(Icons.circle, size: 6, color: blue)
                          : null,
                      onTap: () => open(null, destination: d.name),
                    ),
                  ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Divider(),
                ),
                if (searchOpen)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    child: TextField(
                      key: const ValueKey('conversation-search'),
                      autofocus: true,
                      decoration: const InputDecoration(
                        hintText: 'Search all rooms and people',
                        prefixIcon: Icon(Icons.search, size: 18),
                      ),
                      onChanged: (v) => setState(
                        () => conversationQuery = v.trim().toLowerCase(),
                      ),
                    ),
                  ),
                if (searchOpen && conversationQuery.isNotEmpty) ...[
                  navHeading('SEARCH RESULTS'),
                  for (final g in app.groups.where(
                    (g) =>
                        !['call_chat', 'post_comments'].contains(g['kind']) &&
                        conversationMatches(g, conversationQuery),
                  ))
                    navigationGroup(g, 'search'),
                  if (!app.groups.any(
                    (g) => conversationMatches(g, conversationQuery),
                  ))
                    empty('No matching rooms or people.'),
                ] else ...[
                  navHeading(
                    switch (activeDestination) {
                      'Chats' => 'CONVERSATIONS',
                      'Matrix' => 'MATRIX ROOMS',
                      'Forums' || 'Posts' => 'BY COMMUNITY',
                      _ => 'YOUR COMMUNITIES',
                    },
                    add: () => create(
                      activeDestination == 'Chats'
                          ? 'dm'
                          : activeDestination == 'Matrix'
                          ? 'matrix'
                          : 'space',
                    ),
                  ),
                  for (final g in destinationGroups(app, activeDestination))
                    navigationGroup(g, g['kind'] == 'space' ? 'space' : 'dm'),
                  if (destinationGroups(app, activeDestination).isEmpty)
                    empty(switch (activeDestination) {
                      'Chats' => 'Start a conversation with a friend.',
                      'Matrix' => 'Connect to people beyond River.',
                      _ => 'Your communities will appear here.',
                    }),
                ],
              ],
            ),
          ),
          RiverCallBar(api: app),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: ListTile(
              selected: section == 'Friends' && app.selected == null,
              leading: const Icon(Icons.people_outline, size: 19),
              title: const Text('Friends'),
              trailing: app.incomingRequests > 0
                  ? Badge(label: Text('${app.incomingRequests}'))
                  : null,
              onTap: () => open(null, destination: 'Friends'),
            ),
          ),
          const Divider(),
          ListTile(
            leading: RiverAvatar(
              name: app.user?['username'] as String? ?? '',
              size: 30,
            ),
            title: Text(
              app.displayName(
                app.user?['user_id'] as String? ??
                    app.user?['username'] as String? ??
                    '',
              ),
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            trailing: IconButton(
              tooltip: 'Settings',
              icon: const Icon(Icons.settings_outlined, size: 18),
              onPressed: settings,
            ),
            onTap: settings,
          ),
          const SizedBox(height: 4),
        ],
      ),
    ),
  );

  Widget navHeading(String text, {VoidCallback? add}) => Padding(
    padding: const EdgeInsets.only(left: 10, top: 2, bottom: 6),
    child: Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: muted,
              letterSpacing: .8,
            ),
          ),
        ),
        if (add != null)
          IconButton(
            tooltip: activeDestination == 'Chats'
                ? 'New conversation'
                : activeDestination == 'Matrix'
                ? 'Connect with Matrix'
                : 'New space',
            constraints: const BoxConstraints.tightFor(width: 30, height: 30),
            padding: EdgeInsets.zero,
            onPressed: add,
            icon: const Icon(Icons.add, size: 17),
          ),
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
                constraints: const BoxConstraints.tightFor(
                  width: 28,
                  height: 28,
                ),
                padding: EdgeInsets.zero,
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
        onTap: () => open(
          g['id'] as String,
          destination:
              supportsRiverEntries(app, g) &&
                  ['Posts', 'Forums'].contains(activeDestination)
              ? activeDestination
              : null,
        ),
      ),
      if (kind == 'space' &&
          !['Posts', 'Forums'].contains(activeDestination) &&
          !collapsed.contains(g['id']) &&
          g['membership'] == 'join')
        if (isMatrixGroup(app, g))
          MatrixRoomList(app: app, space: g['id'] as String, open: open)
        else
          SpaceChannels(
            app: app,
            space: g['id'] as String,
            open: open,
            thread: (event) {
              scaffold.currentState?.closeDrawer();
              unawaited(
                openRiverThread(
                  context,
                  app,
                  event['group_id'] as String,
                  event,
                ),
              );
            },
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
  Widget home() => RiverHome(
    app: app,
    open: open,
    create: create,
    navigate: (destination) => open(null, destination: destination),
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
                          (m['user_id'] == null ||
                              m['user_id'] != app.user?['user_id']) &&
                          (m['principal_id'] == null ||
                              m['principal_id'] != app.user?['sub'])
                      ? IconButton(
                          tooltip: 'Remove ${m['username']}',
                          icon: const Icon(Icons.person_remove_outlined),
                          onPressed: () {
                            Navigator.pop(ctx);
                            action(
                              () => app.membership(
                                g['id'] as String,
                                'remove',
                                m['user_id'] as String? ??
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
    final matrixOnly = isMatrixGroup(app, g);
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
    final viewFilter =
        g['kind'] != 'space' || matrixOnly || g['encrypted'] == true
        ? 'Chat'
        : filter;
    final directory =
        g['kind'] == 'space' && viewFilter == 'Chat' && !spaceChat;
    final voiceRoom = !matrixOnly && g['channel_kind'] == 'drop_in';
    final needsMessaging = app.matrixEnabled && !app.matrixConnected;
    final items = app.events.where((e) {
      if (viewFilter == 'Chat') {
        final relation = (e['content'] as Json)['m.relates_to'] as Json?;
        return (e['type'] == 'm.room.encrypted' ||
                e['type'] == 'm.room.message' ||
                e['type'] == 'm.sticker' ||
                e['type'] == 'cool.gravitas.river.invitation.v1') &&
            relation?['rel_type'] != 'm.thread';
      }
      return e['type'] ==
          'cool.gravitas.river.${viewFilter == 'Posts' ? 'post' : 'discussion'}.v1';
    }).toList();
    final listKey = '${g['id']}:$viewFilter:$spaceChat';
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
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: riverBorder)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Column(
            children: [
              Row(
                children: [
                  if (MediaQuery.sizeOf(context).width < 1000)
                    IconButton(
                      tooltip: 'Open navigation menu',
                      onPressed: () => scaffold.currentState?.openDrawer(),
                      icon: const Icon(Icons.menu),
                    ),
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
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          '${matrixOnly
                              ? 'Matrix'
                              : ['dm', 'group'].contains(g['kind'])
                              ? 'Conversation'
                              : g['kind'] == 'channel'
                              ? 'Chatroom'
                              : 'Community'} · ${(g['members'] as List? ?? []).length} members',
                          style: const TextStyle(color: muted, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  if (!matrixOnly &&
                      (['dm', 'group'].contains(g['kind']) ||
                          g['channel_kind'] == 'drop_in'))
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
                          await app.updateGroup(
                            g['id'] as String,
                            description: description,
                          );
                          await app.refresh();
                        }
                      }
                      if (v == 'conversation' && mounted) {
                        await showDialog<bool>(
                          context: context,
                          builder: (_) =>
                              ConversationPicker(app: app, contextGroup: g),
                        );
                      }
                      if (v == 'subgroups' && mounted) {
                        await showDialog<void>(
                          context: context,
                          builder: (_) =>
                              SubgroupDetails(app: app, group: g, open: open),
                        );
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
                          await app.updateGroup(g['id'] as String, name: name);
                          await app.refresh();
                        }
                      }
                      if (v == 'encrypt' && mounted) {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Enable end-to-end encryption?'),
                            content: const Text(
                              'Future messages and new Matrix attachments will be encrypted on your devices. Encryption cannot be turned off. Existing messages and room details remain as they are. Calls use their own security settings.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: const Text('Cancel'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const Text('Enable encryption'),
                              ),
                            ],
                          ),
                        );
                        if (confirmed == true) {
                          await app.enableEncryption(g['id'] as String);
                        }
                      }
                      if (v == 'leave') {
                        await app.membership(g['id'] as String, 'leave');
                      }
                    }),
                    itemBuilder: (_) => [
                      if (app.matrixConnected &&
                          g['can_encrypt'] == true &&
                          g['encrypted'] != true &&
                          g['kind'] != 'space')
                        const PopupMenuItem(
                          value: 'encrypt',
                          child: Text('Enable encryption'),
                        ),
                      if (!matrixOnly) ...[
                        const PopupMenuItem(
                          value: 'subgroups',
                          child: Text('Group hierarchy'),
                        ),
                        if (g['kind'] != 'channel')
                          const PopupMenuItem(
                            value: 'conversation',
                            child: Text('Conversation with selected members'),
                          ),
                      ],
                      const PopupMenuItem(
                        value: 'members',
                        child: Text('Members'),
                      ),
                      if (!matrixOnly && ['dm', 'group'].contains(g['kind']))
                        const PopupMenuItem(
                          value: 'share-space',
                          child: Text('Invite to a space'),
                        ),
                      if (g['kind'] == 'space' &&
                          g['owner'] == true &&
                          !matrixOnly) ...[
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
              if (app.groups.any(
                (room) =>
                    room['context_id'] == g['id'] &&
                    room['membership'] == 'join',
              ))
                Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    children: [
                      for (final room in app.groups.where(
                        (room) =>
                            room['context_id'] == g['id'] &&
                            room['membership'] == 'join',
                      ))
                        TextButton.icon(
                          onPressed: () => open(room['id'] as String),
                          icon: const Icon(Icons.forum_outlined, size: 16),
                          label: Text(room['name'] as String),
                        ),
                    ],
                  ),
                ),
              if (g['context_id'] != null &&
                  app.group(g['context_id'] as String) != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => open(g['context_id'] as String),
                    icon: const Icon(Icons.arrow_upward, size: 16),
                    label: Text(
                      'In ${app.group(g['context_id'] as String)!['name']}',
                    ),
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
              if (spaceChat && g['kind'] == 'space')
                TextButton.icon(
                  onPressed: () => setState(() => spaceChat = false),
                  icon: const Icon(Icons.arrow_back, size: 16),
                  label: const Text('Back to rooms'),
                ),
              if (g['kind'] == 'space' && !matrixOnly && g['encrypted'] != true)
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'Chat',
                      label: Text('Rooms'),
                      icon: Icon(Icons.tag),
                    ),
                    ButtonSegment(value: 'Discussions', label: Text('Forums')),
                    ButtonSegment(value: 'Posts', label: Text('Posts')),
                  ],
                  selected: {filter},
                  onSelectionChanged: (v) => setState(() {
                    filter = v.first;
                    section = filter == 'Posts'
                        ? 'Posts'
                        : filter == 'Discussions'
                        ? 'Forums'
                        : 'Communities';
                    spaceChat = false;
                  }),
                ),
            ],
          ),
        ),
        if (matrixOnly)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                Icon(Icons.hub_outlined, size: 14, color: muted),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Matrix · messages, threads, and attachments',
                    style: TextStyle(fontSize: 11, color: muted),
                  ),
                ),
              ],
            ),
          ),
        if (newMessages && !directory && !voiceRoom)
          TextButton.icon(
            onPressed: () {
              setState(() => newMessages = false);
              scrollLatest(g['id'] as String);
            },
            icon: const Icon(Icons.arrow_downward, size: 16),
            label: const Text('New messages'),
          ),
        if (app.nextCursor != null &&
            !directory &&
            !voiceRoom &&
            viewFilter == 'Chat')
          TextButton.icon(
            onPressed: app.loadingOlder ? null : () => action(app.older),
            icon: const Icon(Icons.history, size: 16),
            label: Text(
              app.loadingOlder ? 'Loading…' : 'Load earlier messages',
            ),
          ),
        Expanded(
          child: directory
              ? ListView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  children: [
                    if (matrixOnly)
                      MatrixRoomList(
                        app: app,
                        space: g['id'] as String,
                        open: open,
                      )
                    else
                      SpaceRoomList(
                        app: app,
                        space: g['id'] as String,
                        open: open,
                        openSpaceChat: () => setState(() => spaceChat = true),
                      ),
                  ],
                )
              : voiceRoom
              ? Center(
                  child: VoiceRoomTile(app: app, channel: g),
                )
              : viewFilter != 'Chat'
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  itemCount: items.length,
                  itemBuilder: (context, index) => eventCard(items[index], g),
                ),
        ),
        if (!voiceRoom && !directory)
          SafeArea(
            top: false,
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.all(8),
              child: Column(
                children: [
                  if (attachments.isNotEmpty && viewFilter == 'Chat')
                    PendingAttachments(
                      files: attachments,
                      remove: (f) => setState(() {
                        attachments.remove(f);
                        composerChanged();
                      }),
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
                        Expanded(
                          child: RichComposer(
                            controller: draft,
                            sendOnEnter: app.enterSendsMessages,
                            onAttach:
                                sending ||
                                    needsMessaging ||
                                    (!app.matrixConnected && app.files == null)
                                ? null
                                : () => action(() async {
                                    if (app.matrixConnected) {
                                      await sendMatrixAttachment(
                                        context,
                                        app,
                                        g['id'] as String,
                                      );
                                      return;
                                    }
                                    final picked = await app.files!.pick(
                                      FileScope('room', g['id'] as String),
                                      existing: attachments,
                                    );
                                    if (mounted && app.selected == g['id']) {
                                      setState(() {
                                        attachments.addAll(picked);
                                        composerChanged();
                                      });
                                    }
                                  }),
                            label: 'Message',
                            hint: 'Message ${g['name']}…',
                            onSubmit: sending || needsMessaging
                                ? null
                                : () => send(g),
                          ),
                        ),
                        const SizedBox(width: 10),
                        IconButton.filled(
                          tooltip: 'Send',
                          onPressed: sending || needsMessaging
                              ? null
                              : () => send(g),
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
    padding: const EdgeInsets.symmetric(vertical: 3),
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
    final room = composerRoom, account = app.accountKey;
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
    await persistComposer();
    if (!mounted || account != app.accountKey) return;
    try {
      await app.send(g['id'] as String, type, content, retryTxn!);
      for (final f
          in (content['cool.gravitas.river.attachments'] as List<Json>?) ??
              <Json>[]) {
        await app.files?.publish(f);
      }
      if (mounted && composerRoom == room && draft.text.trim() == body) {
        draft.clear();
        attachments.clear();
        retryTxn = null;
        retryPayload = null;
        await persistComposer();
      } else if (drafts[room]?.payload == payload &&
          drafts[room]?.text.trim() == body) {
        // A completed send must also clear its saved draft if navigation moved
        // to another conversation while the request was in flight.
        drafts.remove(room);
        if (room != null) await app.saveDraft(room, null);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$e · Your draft is kept.'),
            action: SnackBarAction(
              label: 'Retry',
              onPressed: () {
                if (app.selected == g['id'] && draft.text.trim() == body) {
                  unawaited(send(g));
                }
              },
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }
}
