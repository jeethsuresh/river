import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'api.dart';
import 'content_widgets.dart';

String postPath(String event) => '/posts/${Uri.encodeComponent(event)}';
String postLink(String event) => '${RiverApi.endpoint}${postPath(event)}';

class PostScreen extends StatefulWidget {
  const PostScreen({super.key, required this.app, required this.event});
  final RiverApi app;
  final String event;
  @override
  State<PostScreen> createState() => _PostScreenState();
}

class _PostScreenState extends State<PostScreen> {
  Json? data, parent;
  final comments = <Json>[];
  final draft = TextEditingController();
  String? cursor, error, payload;
  String txn = transactionId();
  bool loading = false, sending = false;
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
    draft.dispose();
    super.dispose();
  }

  Future<void> load({bool older = false}) async {
    if (loading || !mounted) return;
    setState(() => loading = true);
    try {
      final result = await widget.app.publicPost(
        widget.event,
        before: older ? cursor : null,
      );
      if (!mounted) return;
      setState(() {
        data = result;
        final all = {for (final c in comments) c['event_id']: c};
        for (final c in (result['comments'] as List).cast<Json>()) {
          all[c['event_id']] = c;
        }
        if (!older) {
          // A changed policy or account must immediately remove private comments.
          if (result['can_view_comments'] != true) all.clear();
          if (result['member'] != true) {
            all.removeWhere((_, c) => c['audience'] == 'members');
          }
        }
        comments
          ..clear()
          ..addAll(all.values);
        comments.sort(
          (a, b) => '${(a['unsigned'] as Json?)?['cool.gravitas.stream_order']}'
              .compareTo(
                '${(b['unsigned'] as Json?)?['cool.gravitas.stream_order']}',
              ),
        );
        if (older || cursor == null) cursor = result['next_cursor'] as String?;
        error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          if (e is ApiException && [401, 403, 404].contains(e.status)) {
            data = null;
            comments.clear();
            parent = null;
          }
        });
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> send() async {
    final body = draft.text.trim();
    if (body.isEmpty || sending) return;
    final nextPayload = '$body:${parent?['event_id']}';
    if (payload != nextPayload) {
      payload = nextPayload;
      txn = transactionId();
    }
    setState(() => sending = true);
    try {
      await widget.app.postComment(
        widget.event,
        body,
        txn,
        parent: parent?['event_id'] as String?,
      );
      if (!mounted) return;
      if (draft.text.trim() == body) draft.clear();
      setState(() => parent = null);
      await load();
    } catch (e) {
      if (mounted) setState(() => error = '$e · Your draft is kept.');
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = data?['entry'] as Json?;
    final policy = data?['publication'] as Json?;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Post'),
        actions: [
          IconButton(
            tooltip: 'Refresh post',
            onPressed: loading ? null : load,
            icon: const Icon(Icons.refresh),
          ),
          if (policy?['visibility'] == 'public')
            IconButton(
              tooltip: 'Copy public link',
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(text: postLink(widget.event)),
                );
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Public link copied.')),
                  );
                }
              },
              icon: const Icon(Icons.link),
            ),
        ],
      ),
      body: Column(
        children: [
          if (loading) const LinearProgressIndicator(),
          if (error != null)
            MaterialBanner(
              content: Text(error!),
              actions: [
                TextButton(onPressed: load, child: const Text('Retry')),
              ],
            ),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 850),
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    if (entry != null) ...[
                      Text(
                        (entry['content'] as Json)['title'] as String,
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${entry['sender']} · ${policy?['visibility'] == 'public' ? 'Public post' : 'Members only'}',
                      ),
                      const SizedBox(height: 20),
                      RichBody((entry['content'] as Json)['body'] as String),
                      const SizedBox(height: 16),
                      if (widget.app.user != null)
                        ReactionBar(
                          summary: ((data?['reaction_summary'] as List?) ?? [])
                              .cast<Json>(),
                          change: (emoji, active) async {
                            await widget.app.postReaction(
                              widget.event,
                              emoji,
                              active,
                            );
                            await load();
                          },
                        ),
                      if (data?['member'] == true &&
                          entry['sender'] == widget.app.user?['user_id'])
                        TextButton.icon(
                          onPressed: () async {
                            await showDialog<bool>(
                              context: context,
                              builder: (_) => EntryEditor(
                                app: widget.app,
                                room: (data!['space'] as Json)['id'] as String,
                                entry: {...entry, 'publication': policy},
                              ),
                            );
                            await load();
                          },
                          icon: const Icon(Icons.edit_outlined),
                          label: const Text('Edit post and audience'),
                        ),
                      TextButton.icon(
                        onPressed: () => Navigator.push<void>(
                          context,
                          MaterialPageRoute(
                            builder: (_) => BlogScreen(
                              app: widget.app,
                              room: (data!['space'] as Json)['id'] as String,
                            ),
                          ),
                        ),
                        icon: const Icon(Icons.library_books_outlined),
                        label: Text(
                          'More from ${(data!['space'] as Json)['name']}',
                        ),
                      ),
                      const Divider(height: 36),
                      Text(
                        'Comments',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      if (data?['can_view_comments'] != true)
                        const Text(
                          'Only space members can see these comments.',
                        ),
                      if (policy?['comments_policy'] == 'disabled')
                        const Text('New comments are disabled.'),
                      if (cursor != null)
                        TextButton(
                          onPressed: loading ? null : () => load(older: true),
                          child: const Text('Load older comments'),
                        ),
                      for (final c in comments)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                c['audience'] == 'members'
                                    ? 'Space members only'
                                    : 'Public comment',
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                              if (replyParent(c) != policy?['anchor_id'] &&
                                  replyParent(c) != widget.event)
                                Text(
                                  'Reply to ${replyParent(c)}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.labelSmall,
                                ),
                              ContentCard(
                                app: widget.app,
                                room: c['comment_room'] as String,
                                event: c,
                                changed: load,
                                reply: () => setState(() => parent = c),
                              ),
                            ],
                          ),
                        ),
                      if (widget.app.user == null)
                        FilledButton(
                          onPressed: () =>
                              widget.app.login(next: postPath(widget.event)),
                          child: const Text(
                            'Sign in with Gravitas to join the conversation',
                          ),
                        ),
                    ] else if (!loading && error == null)
                      const Text('This post is unavailable.'),
                  ],
                ),
              ),
            ),
          ),
          if (data?['can_comment'] == true)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            parent?['audience'] == 'members' ||
                                    policy?['comments_policy'] != 'public'
                                ? 'Your reply is visible to space members.'
                                : 'Your reply is public.',
                          ),
                        ),
                        if (parent != null)
                          TextButton(
                            onPressed: () => setState(() => parent = null),
                            child: const Text('Cancel reply'),
                          ),
                      ],
                    ),
                    MarkdownToolbar(controller: draft),
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
                              labelText: 'Write a comment',
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Send comment',
                          onPressed: sending ? null : send,
                          icon: const Icon(Icons.send),
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

  String? replyParent(Json e) =>
      ((e['content'] as Json)['m.relates_to']
              as Json?)?['m.in_reply_to']?['event_id']
          as String?;
}

class BlogScreen extends StatefulWidget {
  const BlogScreen({super.key, required this.app, required this.room});
  final RiverApi app;
  final String room;
  @override
  State<BlogScreen> createState() => _BlogScreenState();
}

class _BlogScreenState extends State<BlogScreen> {
  final posts = <Json>[];
  String? cursor, error, name;
  bool loading = false;
  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load({bool more = false}) async {
    if (loading) return;
    setState(() => loading = true);
    try {
      final r = await widget.app.blog(
        widget.room,
        before: more ? cursor : null,
      );
      if (!mounted) return;
      setState(() {
        if (!more) posts.clear();
        posts.addAll((r['posts'] as List).cast<Json>());
        cursor = r['next_cursor'] as String?;
        name = (r['space'] as Json)['name'] as String;
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(name ?? 'Space posts'),
      actions: [
        IconButton(
          tooltip: 'Refresh posts',
          onPressed: loading ? null : load,
          icon: const Icon(Icons.refresh),
        ),
        IconButton(
          tooltip: 'Copy space blog link',
          onPressed: () => Clipboard.setData(
            ClipboardData(
              text: '${RiverApi.endpoint}/spaces/${widget.room}/posts',
            ),
          ),
          icon: const Icon(Icons.link),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (loading) const LinearProgressIndicator(),
        if (error != null) Text(error!),
        for (final post in posts)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Card(
              child: ListTile(
                title: Text(post['title'] as String),
                subtitle: Text(
                  post['preview'] as String,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => PostScreen(
                      app: widget.app,
                      event: post['event_id'] as String,
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (cursor != null)
          TextButton(
            onPressed: loading ? null : () => load(more: true),
            child: const Text('Load more posts'),
          ),
      ],
    ),
  );
}

class MarkdownToolbar extends StatelessWidget {
  const MarkdownToolbar({super.key, required this.controller});
  final TextEditingController controller;
  void insert(String before, String after) {
    final s = controller.selection;
    final start = s.isValid ? s.start : controller.text.length,
        end = s.isValid ? s.end : controller.text.length;
    final selected = controller.text.substring(start, end);
    controller.value = TextEditingValue(
      text: controller.text.replaceRange(start, end, '$before$selected$after'),
      selection: TextSelection(
        baseOffset: start + before.length,
        extentOffset: start + before.length + selected.length,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        for (final item in <(String, IconData, String, String)>[
          ('Bold', Icons.format_bold, '**', '**'),
          ('Italic', Icons.format_italic, '_', '_'),
          ('Heading', Icons.title, '\n## ', ''),
          ('Link', Icons.link, '[', '](https://)'),
          ('Quote', Icons.format_quote, '\n> ', ''),
          ('Code', Icons.code, '`', '`'),
          ('Code block', Icons.data_object, '\n```\n', '\n```'),
          ('Bullet list', Icons.format_list_bulleted, '\n- ', ''),
          ('Numbered list', Icons.format_list_numbered, '\n1. ', ''),
        ])
          IconButton(
            tooltip: item.$1,
            onPressed: () => insert(item.$3, item.$4),
            icon: Icon(item.$2, size: 19),
          ),
      ],
    ),
  );
}
