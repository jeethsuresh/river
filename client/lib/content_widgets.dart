import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'api.dart';
import 'publishing_widgets.dart';
import 'package:flutter/services.dart';
import 'attachment_widgets.dart';

const reactionEmojis = [
  '👍',
  '👎',
  '❤️',
  '😂',
  '🎉',
  '🔥',
  '👀',
  '🙌',
  '✅',
  '🤔',
  '😮',
  '😢',
  '🚀',
  '💯',
  '👏',
  '✨',
  '🫶',
  '🙏',
  '🥰',
  '😎',
  '🤯',
  '💡',
  '🌈',
  '☕',
];
Json rendered(Json e) => (e['rendered_content'] ?? e['content']) as Json;

Future<void> openContentLink(BuildContext context, String? value) async {
  final uri = value == null ? null : Uri.tryParse(value);
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return;
  }
  final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!opened && context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Unable to open this link.')));
  }
}

class RichBody extends StatelessWidget {
  const RichBody(this.body, {super.key});
  final String body;
  @override
  Widget build(BuildContext context) => SelectionArea(
    child: MarkdownBody(
      data: body,
      onTapLink: (_, href, _) => openContentLink(context, href),
      // Message content never loads local files, assets, data URLs, or remote
      // tracking images. Images remain explicit links that a person can open.
      imageBuilder: (uri, title, alt) => TextButton.icon(
        onPressed: ['http', 'https'].contains(uri.scheme)
            ? () => openContentLink(context, '$uri')
            : null,
        icon: const Icon(Icons.image_outlined),
        label: Text(alt?.isNotEmpty == true ? alt! : 'Open image'),
      ),
    ),
  );
}

class ReactionBar extends StatefulWidget {
  const ReactionBar({super.key, required this.summary, required this.change});
  final List<Json> summary;
  final Future<void> Function(String emoji, bool active) change;
  @override
  State<ReactionBar> createState() => _ReactionBarState();
}

class _ReactionBarState extends State<ReactionBar> {
  bool busy = false;
  Future<void> react(String emoji) async {
    if (busy) return;
    final mine = widget.summary.any(
      (r) => r['key'] == emoji && r['mine'] == true,
    );
    setState(() => busy = true);
    try {
      await widget.change(emoji, !mine);
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

  Future<void> choose() async {
    final emoji = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final e in reactionEmojis)
                Semantics(
                  label: 'React $e',
                  button: true,
                  child: InkWell(
                    onTap: () => Navigator.pop(ctx, e),
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(e, style: const TextStyle(fontSize: 26)),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (emoji != null && mounted) await react(emoji);
  }

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 6,
    runSpacing: 6,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      for (final r in widget.summary)
        FilterChip(
          label: Text('${r['key']} ${r['count']}'),
          selected: r['mine'] == true,
          tooltip: r['mine'] == true
              ? 'Remove ${r['key']} reaction'
              : 'React ${r['key']}',
          onSelected: busy ? null : (_) => react(r['key'] as String),
        ),
      IconButton(
        tooltip: 'Add reaction',
        onPressed: busy ? null : choose,
        icon: const Icon(Icons.add_reaction_outlined, size: 20),
      ),
    ],
  );
}

class ContentCard extends StatelessWidget {
  const ContentCard({
    super.key,
    required this.app,
    required this.room,
    required this.event,
    required this.reply,
    this.changed,
  });
  final RiverApi app;
  final String room;
  final Json event;
  final VoidCallback reply;
  final Future<void> Function()? changed;
  @override
  Widget build(BuildContext context) {
    final c = rendered(event),
        t = DateTime.fromMillisecondsSinceEpoch(
          event['origin_server_ts'] as int,
        ).toLocal();
    final summary = ((event['reaction_summary'] as List?) ?? []).cast<Json>();
    final replies = event['reply_count'] as int? ?? 0;
    final canEdit =
        event['sender'] == app.user?['user_id'] &&
        [
          'cool.gravitas.river.post.v1',
          'cool.gravitas.river.discussion.v1',
        ].contains(event['type']);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const CircleAvatar(
                  radius: 15,
                  child: Icon(Icons.person_outline, size: 18),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    event['sender'] as String,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}${event['edited'] == true ? ' · edited' : ''}',
                  style: const TextStyle(fontSize: 11),
                ),
              ],
            ),
            if (c['title'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(
                  c['title'] as String,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            const SizedBox(height: 12),
            RichBody(c['body'] as String? ?? ''),
            for (final file
                in ((c['cool.gravitas.river.attachments'] as List?) ?? [])
                    .cast<Json>())
              AttachmentCard(app: app, file: file),
            const SizedBox(height: 10),
            if (app.user != null)
              ReactionBar(
                summary: summary,
                change: (emoji, active) async {
                  await app.react(
                    room,
                    event['event_id'] as String,
                    emoji,
                    active,
                  );
                  await changed?.call();
                },
              ),
            Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  onPressed: app.user == null ? null : reply,
                  icon: const Icon(Icons.reply, size: 18),
                  label: Text(
                    replies == 0
                        ? 'Reply'
                        : replies == 1
                        ? '1 reply'
                        : '$replies replies',
                  ),
                ),
                if (event['type'] == 'cool.gravitas.river.post.v1' &&
                    (event['publication'] as Json?)?['visibility'] == 'public')
                  TextButton.icon(
                    onPressed: () => Clipboard.setData(
                      ClipboardData(
                        text: postLink(event['event_id'] as String),
                      ),
                    ),
                    icon: const Icon(Icons.link, size: 17),
                    label: const Text('Copy public link'),
                  ),
                if (canEdit)
                  TextButton.icon(
                    onPressed: () async {
                      await showDialog<bool>(
                        context: context,
                        builder: (_) =>
                            EntryEditor(app: app, room: room, entry: event),
                      );
                      await changed?.call();
                    },
                    icon: const Icon(Icons.edit_outlined, size: 17),
                    label: const Text('Edit'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class EntryEditor extends StatefulWidget {
  const EntryEditor({
    super.key,
    required this.app,
    required this.room,
    this.entry,
    this.kind = 'post',
  });
  final RiverApi app;
  final String room, kind;
  final Json? entry;
  @override
  State<EntryEditor> createState() => _EntryEditorState();
}

class _EntryEditorState extends State<EntryEditor> {
  late final title = TextEditingController(
    text: widget.entry == null
        ? ''
        : rendered(widget.entry!)['title'] as String?,
  );
  late final body = TextEditingController(
    text: widget.entry == null
        ? ''
        : rendered(widget.entry!)['body'] as String?,
  );
  late String visibility =
      (widget.entry?['publication'] as Json?)?['visibility'] as String? ??
      'members';
  late String commentsPolicy =
      (widget.entry?['publication'] as Json?)?['comments_policy'] as String? ??
      'members';
  bool get isPost => widget.entry == null
      ? widget.kind == 'post'
      : widget.entry!['type'] == 'cool.gravitas.river.post.v1';
  String? createdEvent;
  bool preview = false, busy = false;
  String? error, payload;
  String txn = transactionId();
  final form = GlobalKey<FormState>();
  @override
  void dispose() {
    title.dispose();
    body.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (busy || !form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    final content = <String, dynamic>{
      'version': 1,
      'title': title.text.trim(),
      'body': body.text.trim(),
    };
    final encoded = jsonEncode(content);
    if (encoded != payload) {
      payload = encoded;
      txn = transactionId();
    }
    try {
      final existing = widget.entry?['event_id'] as String? ?? createdEvent;
      if (isPost &&
          existing != null &&
          visibility == 'members' &&
          (widget.entry?['publication'] as Json?)?['visibility'] == 'public') {
        await widget.app.publication(
          widget.room,
          existing,
          visibility,
          commentsPolicy,
        );
      }
      if (existing != null) {
        await widget.app.editEntry(
          widget.room,
          existing,
          content['title'] as String,
          content['body'] as String,
        );
      } else {
        final result = await widget.app.send(
          widget.room,
          'cool.gravitas.river.${widget.kind}.v1',
          content,
          txn,
        );
        createdEvent = result['event_id'] as String;
      }
      if (isPost) {
        await widget.app.publication(
          widget.room,
          existing ?? createdEvent!,
          visibility,
          commentsPolicy,
        );
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => error = '$e · Your draft is kept.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(
      widget.entry != null
          ? 'Edit ${widget.entry!['type'] == 'cool.gravitas.river.post.v1' ? 'post' : 'discussion'}'
          : 'New ${widget.kind}',
    ),
    content: SizedBox(
      width: 600,
      child: Form(
        key: form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: title,
              autofocus: true,
              maxLength: 160,
              decoration: const InputDecoration(labelText: 'Title'),
              validator: (v) =>
                  v?.trim().isNotEmpty == true ? null : 'Add a title.',
            ),
            const SizedBox(height: 12),
            if (!preview) MarkdownToolbar(controller: body),
            if (isPost) ...[
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: visibility,
                decoration: const InputDecoration(labelText: 'Post audience'),
                items: const [
                  DropdownMenuItem(
                    value: 'members',
                    child: Text('Space members'),
                  ),
                  DropdownMenuItem(
                    value: 'public',
                    child: Text('Public · anyone with the link'),
                  ),
                ],
                onChanged: busy
                    ? null
                    : (v) => setState(() {
                        visibility = v!;
                        if (v != 'public' && commentsPolicy == 'public') {
                          commentsPolicy = 'members';
                        }
                      }),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                isExpanded: true,
                key: ValueKey('$visibility:$commentsPolicy'),
                initialValue: commentsPolicy,
                decoration: const InputDecoration(labelText: 'Who can comment'),
                items: [
                  const DropdownMenuItem(
                    value: 'members',
                    child: Text('Space members'),
                  ),
                  if (visibility == 'public')
                    const DropdownMenuItem(
                      value: 'public',
                      child: Text('Anyone signed in with Gravitas'),
                    ),
                  const DropdownMenuItem(
                    value: 'disabled',
                    child: Text('Comments disabled'),
                  ),
                ],
                onChanged: busy
                    ? null
                    : (v) => setState(() => commentsPolicy = v!),
              ),
              if (visibility == 'public')
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 10),
                  child: Text(
                    'The post and new public comments can be read and copied by anyone. Earlier member comments stay private.',
                  ),
                ),
              const SizedBox(height: 12),
            ],
            if (preview)
              Padding(
                padding: const EdgeInsets.all(12),
                child: RichBody(body.text),
              )
            else
              TextFormField(
                controller: body,
                minLines: 6,
                maxLines: 16,
                maxLength: 40000,
                decoration: const InputDecoration(
                  labelText: 'Body',
                  hintText: 'Share an idea. Markdown formatting is supported.',
                ),
                validator: (v) => v?.trim().isNotEmpty == true
                    ? null
                    : 'Write something first.',
              ),
            TextButton.icon(
              onPressed: () => setState(() => preview = !preview),
              icon: Icon(
                preview ? Icons.edit_outlined : Icons.visibility_outlined,
              ),
              label: Text(preview ? 'Write' : 'Preview'),
            ),
            if (error != null)
              Semantics(
                liveRegion: true,
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: busy ? null : save,
        child: Text(
          busy
              ? 'Saving…'
              : widget.entry == null
              ? 'Post'
              : 'Save changes',
        ),
      ),
    ],
  );
}

class ThreadScreen extends StatefulWidget {
  const ThreadScreen({
    super.key,
    required this.app,
    required this.room,
    required this.rootId,
  });
  final RiverApi app;
  final String room, rootId;
  @override
  State<ThreadScreen> createState() => _ThreadScreenState();
}

class _ThreadScreenState extends State<ThreadScreen> {
  Json? root, parent;
  List<Json> events = [];
  String? cursor, error, payload;
  String txn = transactionId();
  bool loading = false, loaded = false, again = false, sending = false;
  final draft = TextEditingController(), scroll = ScrollController();
  StreamSubscription<void>? subscription;
  @override
  void initState() {
    super.initState();
    unawaited(load());
    subscription = widget.app.changes.stream.listen((_) {
      if (mounted &&
          widget.app.active &&
          (ModalRoute.of(context)?.isCurrent ?? false)) {
        unawaited(load());
      }
    });
  }

  @override
  void dispose() {
    subscription?.cancel();
    draft.dispose();
    scroll.dispose();
    super.dispose();
  }

  void merge(List<Json> incoming) {
    final all = {for (final e in events) e['event_id'] as String: e};
    for (final e in incoming) {
      all[e['event_id'] as String] = e;
    }
    events = all.values.toList()
      ..sort((a, b) {
        final ax =
            (a['unsigned'] as Json?)?['cool.gravitas.stream_order'] as String?;
        final bx =
            (b['unsigned'] as Json?)?['cool.gravitas.stream_order'] as String?;
        return ax != null && bx != null
            ? ax.compareTo(bx)
            : (a['origin_server_ts'] as int).compareTo(
                b['origin_server_ts'] as int,
              );
      });
  }

  Future<void> load({bool older = false}) async {
    if (loading) {
      again = true;
      return;
    }
    setState(() => loading = true);
    try {
      final result = await widget.app.thread(
        widget.room,
        widget.rootId,
        before: older ? cursor : null,
      );
      if (!mounted) return;
      final incoming = (result['events'] as List).cast<Json>();
      final overlap = incoming.any(
        (e) => events.any((old) => old['event_id'] == e['event_id']),
      );
      setState(() {
        root = result['root'] as Json;
        if (!loaded || older || (!overlap && incoming.isNotEmpty)) {
          cursor = result['next_cursor'] as String?;
        }
        loaded = true;
        merge(incoming);
        error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          if (e is ApiException && [401, 403].contains(e.status)) {
            root = null;
            events = [];
            parent = null;
          }
        });
      }
    } finally {
      if (mounted) {
        setState(() => loading = false);
        if (again) {
          again = false;
          unawaited(load());
        }
      }
    }
  }

  Future<void> send() async {
    if (sending || root == null || draft.text.trim().isEmpty) return;
    final body = draft.text.trim();
    final c = <String, dynamic>{
      'msgtype': 'm.text',
      'body': body,
      'cool.gravitas.river': {'version': 1, 'kind': 'reply'},
      'm.relates_to': {
        'rel_type': 'm.thread',
        'event_id': root!['event_id'],
        'is_falling_back': false,
        'm.in_reply_to': {'event_id': parent?['event_id'] ?? root!['event_id']},
      },
    };
    final encoded = jsonEncode(c);
    if (encoded != payload) {
      payload = encoded;
      txn = transactionId();
    }
    setState(() => sending = true);
    try {
      await widget.app.send(widget.room, 'm.room.message', c, txn);
      if (!mounted) return;
      if (draft.text.trim() == body) draft.clear();
      setState(() => parent = null);
      await load();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && scroll.hasClients) {
          scroll.jumpTo(scroll.position.maxScrollExtent);
        }
      });
    } catch (e) {
      if (mounted) setState(() => error = '$e · Your draft is kept.');
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Thread')),
    body: Column(
      children: [
        if (error != null)
          MaterialBanner(
            content: Text(error!),
            actions: [
              TextButton(onPressed: () => load(), child: const Text('Retry')),
            ],
          ),
        if (!loaded && loading) const LinearProgressIndicator(),
        Expanded(
          child: ListView(
            controller: scroll,
            padding: const EdgeInsets.all(20),
            children: [
              if (root != null)
                ContentCard(
                  app: widget.app,
                  room: widget.room,
                  event: root!,
                  reply: () => setState(() => parent = null),
                  changed: () => load(),
                ),
              const SizedBox(height: 20),
              if (cursor != null)
                TextButton(
                  onPressed: loading ? null : () => load(older: true),
                  child: const Text('Load earlier replies'),
                ),
              if (loaded && events.isEmpty && root != null)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('Start the thread.'),
                ),
              for (final e in events)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (getReplyParent(e) != root?['event_id'])
                        Padding(
                          padding: const EdgeInsets.only(left: 12, bottom: 6),
                          child: Text(
                            '↳ Reply to ${events.where((p) => p['event_id'] == getReplyParent(e)).firstOrNull?['sender'] ?? 'an earlier reply'}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ContentCard(
                        app: widget.app,
                        room: widget.room,
                        event: e,
                        reply: () => setState(() => parent = e),
                        changed: () => load(),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        if (root != null)
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  if (parent != null)
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Replying to ${parent!['sender']}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Cancel quoted reply',
                          onPressed: () => setState(() => parent = null),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: draft,
                          minLines: 1,
                          maxLines: 5,
                          maxLength: 16000,
                          decoration: const InputDecoration(
                            hintText: 'Write a reply…',
                            counterText: '',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      IconButton.filled(
                        tooltip: 'Send reply',
                        onPressed: sending ? null : send,
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
    ),
  );
}

String? getReplyParent(Json e) =>
    (((e['content'] as Json)['m.relates_to'] as Json?)?['m.in_reply_to']
            as Json?)?['event_id']
        as String?;

class EntryFeed extends StatefulWidget {
  const EntryFeed({
    super.key,
    required this.app,
    required this.room,
    required this.kind,
  });
  final RiverApi app;
  final String room, kind;
  @override
  State<EntryFeed> createState() => _EntryFeedState();
}

class _EntryFeedState extends State<EntryFeed> {
  final events = <Json>[];
  String? cursor, error;
  bool loading = false;
  StreamSubscription<void>? changes;
  @override
  void initState() {
    super.initState();
    unawaited(load());
    changes = widget.app.changes.stream.listen((_) => load());
  }

  @override
  void dispose() {
    changes?.cancel();
    super.dispose();
  }

  Future<void> load({bool more = false}) async {
    if (loading || !mounted) return;
    setState(() => loading = true);
    try {
      final r = await widget.app.request(
        '/api/groups/${widget.room}/entries?kind=${widget.kind}${more && cursor != null ? '&before=${Uri.encodeQueryComponent(cursor!)}' : ''}',
      );
      if (!mounted) return;
      setState(() {
        final all = {for (final e in events) e['event_id']: e};
        for (final e in (r['events'] as List).cast<Json>()) {
          all[e['event_id']] = e;
        }
        events
          ..clear()
          ..addAll(all.values);
        events.sort(
          (a, b) => '${(b['unsigned'] as Json?)?['cool.gravitas.stream_order']}'
              .compareTo(
                '${(a['unsigned'] as Json?)?['cool.gravitas.stream_order']}',
              ),
        );
        if (more || cursor == null) cursor = r['next_cursor'] as String?;
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      if (loading) const LinearProgressIndicator(),
      if (error != null)
        ListTile(
          title: Text(error!),
          trailing: TextButton(onPressed: load, child: const Text('Retry')),
        ),
      if (events.isEmpty && !loading && error == null)
        Text('Start the ${widget.kind == 'post' ? 'posts' : 'discussions'}.'),
      for (final e in events)
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: ContentCard(
            app: widget.app,
            room: widget.room,
            event: e,
            changed: load,
            reply: () => Navigator.push<void>(
              context,
              MaterialPageRoute(
                builder: (_) => widget.kind == 'post'
                    ? PostScreen(
                        app: widget.app,
                        event: e['event_id'] as String,
                      )
                    : ThreadScreen(
                        app: widget.app,
                        room: widget.room,
                        rootId: e['event_id'] as String,
                      ),
              ),
            ),
          ),
        ),
      if (cursor != null)
        TextButton(
          onPressed: loading ? null : () => load(more: true),
          child: const Text('Load older entries'),
        ),
    ],
  );
}
