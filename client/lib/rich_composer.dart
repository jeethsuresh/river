// The clipboard switch is experimental in pinned flutter_quill 11.6.0.
// Keep it off so pasted HTML cannot inject remote embeds into a peer-only editor.
// ignore_for_file: experimental_member_use
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:markdown/markdown.dart' as md;
import 'package:markdown_quill/markdown_quill.dart';
import 'content_widgets.dart';
import 'media.dart';
import 'media_widgets.dart';
import 'publishing_widgets.dart' show MarkdownShortcuts, MarkdownToolbar;

/// One editor for web and Android. Markdown remains the portable event body;
/// changing modes alone never rewrites a draft or an existing immutable event.
class RichComposer extends StatefulWidget {
  const RichComposer({
    super.key,
    required this.controller,
    this.label = 'Message',
    this.hint = 'Write something…',
    this.maxLength = 16000,
    this.minHeight = 48,
    this.maxHeight = 150,
    this.enabled = true,
    this.compact = true,
    this.onSubmit,
    this.onAttach,
    this.onChanged,
    this.validator,
  });
  final TextEditingController controller;
  final String label, hint;
  final int maxLength;
  final double minHeight, maxHeight;
  final bool enabled, compact;
  final VoidCallback? onSubmit, onAttach;
  final ValueChanged<String>? onChanged;
  final FormFieldValidator<String>? validator;

  @override
  State<RichComposer> createState() => _RichComposerState();
}

class _RichComposerState extends State<RichComposer> {
  final focus = FocusNode(), scroll = ScrollController();
  final field = GlobalKey<FormFieldState<String>>();
  final toMarkdown = DeltaToMarkdown();
  final toDelta = MarkdownToDelta(
    markdownDocument: md.Document(
      encodeHtml: false,
      extensionSet: md.ExtensionSet.gitHubFlavored,
    ),
  );
  late q.QuillController editor;
  StreamSubscription<q.DocChange>? subscription;
  String mode = 'Write', loaded = '', editMode = 'Write';
  bool syncing = false, extended = false;

  @override
  void initState() {
    super.initState();
    load();
    widget.controller.addListener(sourceChanged);
  }

  // Quill cannot represent every Markdown block. Preserve those documents in
  // the source editor instead of silently deleting images, tables or raw HTML.
  bool needsSource(String source) {
    bool unsupported(md.Node node, {bool code = false, bool quote = false}) {
      if (node is md.Text) {
        return !code && RegExp(r'<[!/]?[a-zA-Z]').hasMatch(node.text);
      }
      if (node is! md.Element) return false;
      if (['img', 'table', 'hr'].contains(node.tag)) return true;
      if (quote &&
          [
            'h1',
            'h2',
            'h3',
            'h4',
            'h5',
            'h6',
            'ul',
            'ol',
            'pre',
          ].contains(node.tag)) {
        return true;
      }
      return (node.children ?? []).any(
        (child) => unsupported(
          child,
          code: code || ['code', 'pre'].contains(node.tag),
          quote: quote || node.tag == 'blockquote',
        ),
      );
    }

    return md.Document(
      encodeHtml: false,
      extensionSet: md.ExtensionSet.gitHubFlavored,
    ).parseLines(source.split('\n')).any(unsupported);
  }

  void load() {
    loaded = widget.controller.text;
    extended = needsSource(loaded);
    if (extended) mode = 'Markdown';
    editor = q.QuillController(
      document: extended || loaded.isEmpty
          ? q.Document()
          : q.Document.fromDelta(toDelta.convert(loaded)),
      selection: const TextSelection.collapsed(offset: 0),
      // Files use River's peer transport. Rich clipboard HTML must not embed
      // remote images, unsupported formatting, or hidden tracking content.
      config: const q.QuillControllerConfig(
        clipboardConfig: q.QuillClipboardConfig(enableExternalRichPaste: false),
      ),
    )..readOnly = !widget.enabled;
    listenDocument();
    editor.addListener(selectionChanged);
  }

  void listenDocument() {
    subscription?.cancel();
    subscription = editor.changes.listen((change) {
      if (syncing || change.source != q.ChangeSource.local) return;
      final source = toMarkdown.convert(editor.document.toDelta()).trimRight();
      if (source.characters.length > widget.maxLength) {
        // Reject the entire edit, including a large paste, rather than truncate
        // Markdown delimiters or split a grapheme/IME composition.
        syncing = true;
        final old = editor.document;
        editor.document = q.Document.fromDelta(change.before);
        listenDocument();
        old.close();
        syncing = false;
        return;
      }
      syncing = true;
      loaded = source;
      widget.controller.value = TextEditingValue(
        text: source,
        selection: TextSelection.collapsed(offset: source.length),
      );
      syncing = false;
      field.currentState?.didChange(source);
      widget.onChanged?.call(source);
      if (mounted) setState(() {});
    });
  }

  void replaceDocument() {
    final old = editor.document;
    editor.document = extended || loaded.isEmpty
        ? q.Document()
        : q.Document.fromDelta(toDelta.convert(loaded));
    listenDocument();
    old.close();
  }

  void selectionChanged() {
    if (!syncing && mounted) setState(() {});
  }

  void sourceChanged() {
    if (syncing || loaded == widget.controller.text) return;
    loaded = widget.controller.text;
    if (mode != 'Markdown') {
      syncing = true;
      extended = needsSource(loaded);
      if (extended) mode = 'Markdown';
      replaceDocument();
      syncing = false;
    }
    field.currentState?.didChange(loaded);
    // Includes programmatic clears and toolbar edits: audience capture uses the
    // same notification path as keyboard input.
    widget.onChanged?.call(loaded);
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant RichComposer old) {
    super.didUpdateWidget(old);
    if (widget.controller != old.controller) {
      old.controller.removeListener(sourceChanged);
      widget.controller.addListener(sourceChanged);
      sourceChanged();
    }
    editor.readOnly = !widget.enabled;
  }

  void changeMode(String next) {
    if (next == 'Write' &&
        mode != 'Write' &&
        loaded != toMarkdown.convert(editor.document.toDelta()).trimRight()) {
      if (needsSource(widget.controller.text)) {
        setState(() => extended = true);
        return;
      }
      syncing = true;
      extended = false;
      replaceDocument();
      syncing = false;
    }
    setState(() {
      if (next == 'Preview' && mode != 'Preview') editMode = mode;
      mode = next;
      extended = needsSource(widget.controller.text);
    });
  }

  void format(q.Attribute attribute) {
    final current = editor.getSelectionStyle().attributes[attribute.key];
    editor.formatSelection(
      current?.value == attribute.value
          ? q.Attribute.clone(attribute, null)
          : attribute,
    );
    focus.requestFocus();
  }

  Future<void> link() async {
    final selected = editor.selection;
    final current =
        editor.getSelectionStyle().attributes[q.Attribute.link.key]?.value
            as String? ??
        '';
    final input = TextEditingController(text: current);
    String? error;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: const Text('Insert link'),
          content: TextField(
            controller: input,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Link URL',
              hintText: 'https://example.com',
              errorText: error,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            if (current.isNotEmpty)
              TextButton(
                onPressed: () => Navigator.pop(ctx, ''),
                child: const Text('Remove link'),
              ),
            FilledButton(
              onPressed: () {
                final url = input.text.trim();
                if (contentLink(url) == null) {
                  update(() => error = 'Use a web, mail or relative URL.');
                } else {
                  Navigator.pop(ctx, url);
                }
              },
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
    // The dialog's closing animation can still reference its input controller.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    input.dispose();
    if (result == null || !mounted) return;
    editor.updateSelection(selected, q.ChangeSource.local);
    if (selected.isCollapsed && result.isNotEmpty) {
      editor.replaceText(
        selected.start,
        0,
        result,
        TextSelection.collapsed(offset: selected.start + result.length),
      );
      editor.formatText(selected.start, result.length, q.LinkAttribute(result));
    } else {
      editor.formatSelection(q.LinkAttribute(result.isEmpty ? null : result));
    }
    focus.requestFocus();
  }

  Future<void> insertMedia({bool sticker = false}) async {
    final url = sticker
        ? await chooseSticker(context)
        : await askMediaLink(context);
    if (url == null || !mounted || !widget.enabled) return;
    final text = widget.controller.text;
    final selection = widget.controller.selection;
    final start = selection.isValid ? selection.start : text.length;
    final end = selection.isValid ? selection.end : text.length;
    final inserted = '\n\n${mediaMarkdown(url, sticker: sticker)}\n\n';
    if ((text.length - (end - start) + inserted.length) > widget.maxLength) {
      return;
    }
    widget.controller.value = TextEditingValue(
      text: text.replaceRange(start, end, inserted),
      selection: TextSelection.collapsed(offset: start + inserted.length),
    );
  }

  @override
  void dispose() {
    widget.controller.removeListener(sourceChanged);
    subscription?.cancel();
    editor.removeListener(selectionChanged);
    editor.dispose();
    focus.dispose();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Localizations.override(
    context: context,
    delegates: const [q.FlutterQuillLocalizations.delegate],
    child: buildEditor(context),
  );

  List<Widget> visualTools() => [
    for (final item in <(String, IconData, q.Attribute)>[
      ('Bold', Icons.format_bold, q.Attribute.bold),
      ('Italic', Icons.format_italic, q.Attribute.italic),
      ('Strikethrough', Icons.format_strikethrough, q.Attribute.strikeThrough),
      ('Heading', Icons.title, q.Attribute.h2),
      ('Bullet list', Icons.format_list_bulleted, q.Attribute.ul),
      ('Numbered list', Icons.format_list_numbered, q.Attribute.ol),
      ('Quote', Icons.format_quote, q.Attribute.blockQuote),
      ('Code', Icons.code, q.Attribute.inlineCode),
      ('Code block', Icons.data_object, q.Attribute.codeBlock),
    ])
      IconButton(
        tooltip: item.$1,
        isSelected:
            editor.getSelectionStyle().attributes[item.$3.key]?.value ==
            item.$3.value,
        onPressed: widget.enabled && mode != 'Preview'
            ? () => format(item.$3)
            : null,
        icon: Icon(item.$2, size: 18),
      ),
    IconButton(
      tooltip: 'Insert link',
      onPressed: widget.enabled && mode != 'Preview' ? link : null,
      icon: const Icon(Icons.link, size: 18),
    ),
    IconButton(
      tooltip: 'Undo',
      onPressed: widget.enabled && mode != 'Preview' && editor.hasUndo
          ? editor.undo
          : null,
      icon: const Icon(Icons.undo, size: 18),
    ),
    IconButton(
      tooltip: 'Redo',
      onPressed: widget.enabled && mode != 'Preview' && editor.hasRedo
          ? editor.redo
          : null,
      icon: const Icon(Icons.redo, size: 18),
    ),
  ];

  Widget buildEditor(BuildContext context) => FormField<String>(
    key: field,
    initialValue: widget.controller.text,
    validator: (_) => widget.validator?.call(widget.controller.text),
    builder: (state) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IconButtonTheme(
          data: IconButtonThemeData(
            style: IconButton.styleFrom(
              minimumSize: const Size(32, 32),
              padding: const EdgeInsets.all(4),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (mode == 'Markdown' ||
                    mode == 'Preview' && editMode == 'Markdown')
                  MarkdownToolbar(
                    controller: widget.controller,
                    inline: true,
                    enabled: widget.enabled && mode != 'Preview',
                  )
                else
                  ...visualTools(),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                  child: Text('|'),
                ),
                IconButton(
                  tooltip: 'Attach files',
                  onPressed: widget.enabled && mode != 'Preview'
                      ? widget.onAttach
                      : null,
                  icon: const Icon(Icons.attach_file, size: 18),
                ),
                IconButton(
                  tooltip: 'Insert image or GIF',
                  onPressed: widget.enabled && mode != 'Preview'
                      ? insertMedia
                      : null,
                  icon: const Icon(Icons.gif_box_outlined, size: 18),
                ),
                IconButton(
                  tooltip: 'Insert sticker',
                  onPressed: widget.enabled && mode != 'Preview'
                      ? () => insertMedia(sticker: true)
                      : null,
                  icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                  child: Text('|'),
                ),
                TextButton(
                  onPressed: widget.enabled
                      ? () => changeMode(
                          mode == 'Markdown' ? 'Write' : 'Markdown',
                        )
                      : null,
                  style: TextButton.styleFrom(
                    foregroundColor: mode == 'Markdown'
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        mode == 'Markdown'
                            ? Icons.check_box_outlined
                            : Icons.check_box_outline_blank,
                        size: 16,
                      ),
                      const SizedBox(width: 4),
                      const Text('Markdown'),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () =>
                      changeMode(mode == 'Preview' ? editMode : 'Preview'),
                  child: const Text('Preview'),
                ),
              ],
            ),
          ),
        ),
        if (extended && mode == 'Markdown')
          const Text(
            'This draft uses extended Markdown. Edit its source to preserve all formatting.',
          ),
        if (mode == 'Write') ...[
          Semantics(
            label: widget.label,
            textField: true,
            child: CallbackShortcuts(
              bindings: {
                for (final meta in [false, true]) ...{
                  SingleActivator(
                    LogicalKeyboardKey.keyB,
                    control: !meta,
                    meta: meta,
                  ): () =>
                      format(q.Attribute.bold),
                  SingleActivator(
                    LogicalKeyboardKey.keyI,
                    control: !meta,
                    meta: meta,
                  ): () =>
                      format(q.Attribute.italic),
                  SingleActivator(
                    LogicalKeyboardKey.keyX,
                    control: !meta,
                    meta: meta,
                    shift: true,
                  ): () =>
                      format(q.Attribute.strikeThrough),
                  if (widget.onSubmit != null)
                    SingleActivator(
                      LogicalKeyboardKey.enter,
                      control: !meta,
                      meta: meta,
                    ): widget.onSubmit!,
                },
              },
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: q.QuillEditor(
                  controller: editor,
                  focusNode: focus,
                  scrollController: scroll,
                  config: q.QuillEditorConfig(
                    minHeight: widget.minHeight,
                    maxHeight: widget.maxHeight,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 8,
                    ),
                    placeholder: widget.hint,
                    onLaunchUrl: (value) => openContentLink(context, value),
                  ),
                ),
              ),
            ),
          ),
        ] else if (mode == 'Markdown') ...[
          MarkdownShortcuts(
            controller: widget.controller,
            onSubmit: widget.onSubmit,
            child: TextField(
              controller: widget.controller,
              enabled: widget.enabled,
              minLines: widget.minHeight >= 100 ? 5 : 1,
              maxLines: widget.minHeight >= 100 ? 12 : 4,
              maxLength: widget.maxLength,
              decoration: InputDecoration(
                labelText: widget.label,
                hintText: widget.hint,
                counterText: '',
              ),
            ),
          ),
        ] else
          ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: widget.minHeight,
              maxHeight: widget.maxHeight,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: RichBody(widget.controller.text),
            ),
          ),
        if (state.errorText != null)
          Text(
            state.errorText!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    ),
  );
}
