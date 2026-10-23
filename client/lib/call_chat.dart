import 'dart:async';
import 'package:flutter/material.dart';
import 'api.dart';
import 'content_widgets.dart';
import 'file_models.dart';
import 'publishing_widgets.dart';

class CallChatScreen extends StatefulWidget {
  const CallChatScreen({super.key, required this.api, required this.room});
  final RiverApi api;
  final String room;
  @override
  State<CallChatScreen> createState() => _CallChatScreenState();
}

class _CallChatScreenState extends State<CallChatScreen> {
  final events = <Json>[], attachments = <Json>[];
  final draft = TextEditingController();
  StreamSubscription<void>? changes;
  String? cursor, error, payload;
  String txn = transactionId();
  bool loading = false, sending = false;
  bool get allowed =>
      widget.api.calls.active && widget.api.calls.chat == widget.room;
  @override
  void initState() {
    super.initState();
    unawaited(load());
    changes = widget.api.changes.stream.listen((_) => load());
    widget.api.calls.addListener(callChanged);
  }

  void callChanged() {
    if (mounted) {
      setState(() {
        if (!allowed) {
          events.clear();
          attachments.clear();
        }
      });
    }
  }

  @override
  void dispose() {
    changes?.cancel();
    widget.api.calls.removeListener(callChanged);
    draft.dispose();
    super.dispose();
  }

  Future<void> load({bool older = false}) async {
    if (loading || !allowed || !mounted) return;
    setState(() => loading = true);
    try {
      final r = await widget.api.request(
        '/api/groups/${widget.room}/events${older && cursor != null ? '?before=${Uri.encodeQueryComponent(cursor!)}' : ''}',
      );
      if (!mounted || !allowed) return;
      setState(() {
        final all = {for (final e in events) e['event_id']: e};
        for (final e in (r['events'] as List).cast<Json>()) {
          all[e['event_id']] = e;
        }
        events
          ..clear()
          ..addAll(all.values.where((e) => e['type'] == 'm.room.message'));
        events.sort(
          (a, b) => '${(a['unsigned'] as Json?)?['cool.gravitas.stream_order']}'
              .compareTo(
                '${(b['unsigned'] as Json?)?['cool.gravitas.stream_order']}',
              ),
        );
        if (older || cursor == null) cursor = r['next_cursor'] as String?;
        error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          if (e is ApiException && [401, 403].contains(e.status)) {
            events.clear();
          }
        });
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> send() async {
    if (sending ||
        !allowed ||
        (draft.text.trim().isEmpty && attachments.isEmpty)) {
      return;
    }
    final body = draft.text.trim(), sentFiles = List<Json>.of(attachments);
    final c = <String, dynamic>{
      'msgtype': 'm.text',
      'body': body.isEmpty ? 'Shared ${attachments.length} file(s)' : body,
      if (attachments.isNotEmpty) 'cool.gravitas.river.attachments': sentFiles,
    };
    final key = '$body:${attachments.map((a) => a['id']).join(',')}';
    if (key != payload) {
      payload = key;
      txn = transactionId();
    }
    setState(() => sending = true);
    try {
      await widget.api.send(widget.room, 'm.room.message', c, txn);
      for (final file in sentFiles) {
        await widget.api.files?.publish(file);
      }
      if (!mounted) return;
      if (draft.text.trim() == body) draft.clear();
      setState(
        () => attachments.removeWhere(
          (a) => sentFiles.any((f) => a['id'] == f['id']),
        ),
      );
      await load();
    } catch (e) {
      if (mounted) setState(() => error = '$e · Your draft is kept.');
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Future<void> pick() async {
    final files = widget.api.files;
    if (files == null) return;
    try {
      final added = await files.pick(
        FileScope('room', widget.room),
        existing: attachments,
      );
      if (mounted) setState(() => attachments.addAll(added));
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Call-only chat')),
    body: !allowed
        ? const Center(
            child: Text('Join the call to read and send messages here.'),
          )
        : Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'Only people currently in this call can read and send messages here.',
                ),
              ),
              if (error != null)
                MaterialBanner(
                  content: Text(error!),
                  actions: [
                    TextButton(onPressed: load, child: const Text('Retry')),
                  ],
                ),
              if (loading) const LinearProgressIndicator(),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (cursor != null)
                      TextButton(
                        onPressed: loading ? null : () => load(older: true),
                        child: const Text('Load older messages'),
                      ),
                    for (final e in events)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: ContentCard(
                          app: widget.api,
                          room: widget.room,
                          event: e,
                          changed: load,
                          reply: () => Navigator.push<void>(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ThreadScreen(
                                app: widget.api,
                                room: widget.room,
                                rootId: e['event_id'] as String,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      for (final f in attachments)
                        ListTile(
                          title: Text(f['name'] as String),
                          trailing: IconButton(
                            tooltip: 'Remove attachment',
                            onPressed: sending
                                ? null
                                : () => setState(() => attachments.remove(f)),
                            icon: const Icon(Icons.close),
                          ),
                        ),
                      MarkdownToolbar(controller: draft),
                      Row(
                        children: [
                          IconButton(
                            tooltip: 'Attach files',
                            onPressed: sending || attachments.length >= 5
                                ? null
                                : pick,
                            icon: const Icon(Icons.attach_file),
                          ),
                          Expanded(
                            child: TextField(
                              controller: draft,
                              minLines: 1,
                              maxLines: 4,
                              maxLength: 16000,
                              decoration: const InputDecoration(
                                labelText: 'Message callers',
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Send message',
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
