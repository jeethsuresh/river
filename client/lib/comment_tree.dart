import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'api.dart';

/// Parent links may arrive before their parents when history is paginated.
/// Missing parents and malformed cycles remain visible at the top level.
class CommentBranch {
  CommentBranch(this.event);
  final Json event;
  final List<CommentBranch> children = [];
  int get descendantCount =>
      children.fold(0, (n, c) => n + 1 + c.descendantCount);
}

List<CommentBranch> commentForest(
  List<Json> events,
  String? Function(Json) parentOf,
) {
  final nodes = {
    for (final e in events) e['event_id'] as String: CommentBranch(e),
  };
  final roots = <CommentBranch>[];
  for (final node in nodes.values) {
    final id = node.event['event_id'] as String;
    var parent = parentOf(node.event);
    final seen = <String>{id};
    var cursor = parent;
    while (cursor != null && nodes.containsKey(cursor)) {
      if (!seen.add(cursor)) {
        parent = null;
        break;
      }
      cursor = parentOf(nodes[cursor]!.event);
    }
    if (parent == null || !nodes.containsKey(parent)) {
      roots.add(node);
    } else {
      nodes[parent]!.children.add(node);
    }
  }
  return roots;
}

class CommentTree extends StatefulWidget {
  const CommentTree({
    super.key,
    required this.events,
    required this.parentOf,
    required this.builder,
    this.replyTarget,
    this.composer,
  });
  final List<Json> events;
  final String? Function(Json) parentOf;
  final Widget Function(Json) builder;
  final String? replyTarget;
  final Widget? composer;
  @override
  State<CommentTree> createState() => _CommentTreeState();
}

class _CommentTreeState extends State<CommentTree> {
  final collapsed = <String>{};
  @override
  Widget build(BuildContext context) {
    final roots = commentForest(widget.events, widget.parentOf);
    final rows = <Widget>[];
    void add(CommentBranch branch, int depth) {
      final id = branch.event['event_id'] as String;
      final hidden = collapsed.contains(id);
      rows.add(
        Padding(
          key: ValueKey('comment-$id'),
          padding: EdgeInsets.only(left: math.min(depth, 5) * 14.0, bottom: 6),
          child: Container(
            decoration: depth == 0
                ? null
                : BoxDecoration(
                    border: Border(
                      left: BorderSide(
                        color: Theme.of(context).colorScheme.outlineVariant,
                        width: 2,
                      ),
                    ),
                  ),
            padding: EdgeInsets.only(left: depth == 0 ? 0 : 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                widget.builder(branch.event),
                if (branch.children.isNotEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: ValueKey('collapse-$id'),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                      ),
                      onPressed: () => setState(() {
                        if (!collapsed.add(id)) collapsed.remove(id);
                      }),
                      icon: Icon(
                        hidden ? Icons.chevron_right : Icons.expand_more,
                        size: 16,
                      ),
                      label: Text(
                        '${hidden ? 'Show' : 'Collapse'} ${branch.descendantCount} ${branch.descendantCount == 1 ? 'reply' : 'replies'}',
                      ),
                    ),
                  ),
                if (widget.replyTarget == id && widget.composer != null)
                  widget.composer!,
              ],
            ),
          ),
        ),
      );
      if (!hidden) {
        for (final child in branch.children) {
          add(child, depth + 1);
        }
      }
    }

    for (final root in roots) {
      add(root, 0);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }
}
