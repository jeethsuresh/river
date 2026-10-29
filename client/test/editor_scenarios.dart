import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_test/flutter_test.dart';
import 'package:river/content_widgets.dart';
import 'package:river/rich_composer.dart';

void editorScenarios() {
  for (final width in [360.0, 768.0, 1440.0]) {
    testWidgets('visual editor, Markdown, preview and undo at width $width', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 1000));
      final source = TextEditingController(text: 'Hello River');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: RichComposer(controller: source, compact: false),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final editor = tester
          .widget<q.QuillEditor>(find.byType(q.QuillEditor))
          .controller;
      expect(editor.document.toPlainText(), 'Hello River\n');
      editor.updateSelection(
        const TextSelection(baseOffset: 0, extentOffset: 5),
        q.ChangeSource.local,
      );
      await tester.tap(find.byTooltip('Bold'));
      await tester.pumpAndSettle();
      expect(source.text, '**Hello** River');
      expect(editor.document.toDelta().toJson().first['attributes'], {
        'bold': true,
      });
      await tester.ensureVisible(find.byTooltip('Undo'));
      await tester.tap(find.byTooltip('Undo'));
      await tester.pumpAndSettle();
      expect(source.text, 'Hello River');
      await tester.tap(find.byTooltip('Redo'));
      await tester.pumpAndSettle();
      expect(source.text, '**Hello** River');
      await tester.ensureVisible(find.text('Markdown'));
      await tester.tap(find.text('Markdown'));
      await tester.pumpAndSettle();
      const exact =
          '# Heading\n\nA **bold** and _italic_ 🫶🏽 draft.\n\n- first\n- second\n\n```go\nfmt.Println("River")\n```';
      await tester.enterText(find.byType(TextField), exact);
      await tester.ensureVisible(find.text('Preview'));
      await tester.tap(find.text('Preview'));
      await tester.pumpAndSettle();
      expect(find.byType(RichBody), findsOneWidget);
      expect(source.text, exact);
      await tester.tap(find.text('Preview'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Markdown'));
      await tester.tap(find.text('Markdown'));
      await tester.pumpAndSettle();
      expect(
        source.text,
        exact,
      ); // A mode switch never normalizes stored Markdown.
      final current = tester
          .widget<q.QuillEditor>(find.byType(q.QuillEditor))
          .controller;
      expect(current.document.toPlainText(), contains('Heading'));
      current.updateSelection(
        const TextSelection.collapsed(offset: 0),
        q.ChangeSource.local,
      );
      current.replaceText(
        0,
        0,
        'New ',
        const TextSelection.collapsed(offset: 4),
      );
      await tester.pumpAndSettle();
      expect(source.text, contains('New Heading'));
      source.clear();
      await tester.pumpAndSettle();
      expect(current.document.toPlainText(), '\n');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      // Quill's web caret reveal waits 500 ms for the software keyboard; it
      // checks mounted, but the test must drain that delayed callback as well.
      await tester.pump(const Duration(milliseconds: 600));
      source.dispose();
      await tester.binding.setSurfaceSize(null);
    });
  }

  testWidgets(
    'extended Markdown is preserved and never fetches remote embeds',
    (tester) async {
      const draft =
          '![private](file:///secret)\n\n| A | B |\n|---|---|\n| 1 | 2 |';
      final source = TextEditingController(text: draft);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RichComposer(controller: source, compact: false),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(q.QuillEditor), findsNothing);
      await tester.ensureVisible(find.text('Markdown'));
      await tester.tap(find.text('Markdown'));
      await tester.pumpAndSettle();
      expect(source.text, draft);
      expect(find.byType(q.QuillEditor), findsNothing);
      await tester.ensureVisible(find.text('Preview'));
      await tester.tap(find.text('Preview'));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNothing);
      expect(source.text, draft);
      await tester.pumpWidget(const SizedBox());
      // Quill's web caret reveal waits 500 ms for the software keyboard; it
      // checks mounted, but the test must drain that delayed callback as well.
      await tester.pump(const Duration(milliseconds: 600));
      source.dispose();
    },
  );

  testWidgets(
    'visual paste limits preserve the existing draft and source validation',
    (tester) async {
      final source = TextEditingController(text: 'Keep');
      final form = GlobalKey<FormState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Form(
              key: form,
              child: RichComposer(
                controller: source,
                maxLength: 12,
                validator: (value) =>
                    value?.isEmpty == true ? 'Write a message' : null,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final editor = tester
          .widget<q.QuillEditor>(find.byType(q.QuillEditor))
          .controller;
      editor.replaceText(4, 0, 'too large a paste', null);
      await tester.pumpAndSettle();
      expect(source.text, 'Keep');
      expect(editor.document.toPlainText(), 'Keep\n');
      source.clear();
      await tester.pumpAndSettle();
      expect(form.currentState!.validate(), isFalse);
      await tester.pumpAndSettle();
      expect(find.text('Write a message'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      // Quill's web caret reveal waits 500 ms for the software keyboard; it
      // checks mounted, but the test must drain that delayed callback as well.
      await tester.pump(const Duration(milliseconds: 600));
      source.dispose();
    },
  );

  testWidgets(
    'rich keyboard formatting and submit preserve portable event bodies',
    (tester) async {
      final source = TextEditingController(text: 'Selected');
      var submits = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RichComposer(controller: source, onSubmit: () => submits++),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final widget = tester.widget<q.QuillEditor>(find.byType(q.QuillEditor));
      widget.focusNode.requestFocus();
      widget.controller.updateSelection(
        const TextSelection(baseOffset: 0, extentOffset: 8),
        q.ChangeSource.local,
      );
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(source.text, '**Selected**');
      expect(submits, 1);
      await tester.pumpWidget(const SizedBox());
      // Quill's web caret reveal waits 500 ms for the software keyboard; it
      // checks mounted, but the test must drain that delayed callback as well.
      await tester.pump(const Duration(milliseconds: 600));
      source.dispose();
    },
  );
}
