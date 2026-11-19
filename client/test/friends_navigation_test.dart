import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:river/api.dart';
import 'package:river/friends_sidebar.dart';
import 'package:river/friends_view.dart';
import 'package:river/home_widgets.dart';
import 'package:river/main.dart';
import 'package:river/rich_composer.dart';

import 'gravitas_navigation_test.dart' as navigation;
import 'matrix_messaging_test.dart' show MemoryMatrixStorage;

class NavigationApi extends RiverApi {
  NavigationApi() : super(live: false, matrixStorage: MemoryMatrixStorage());
  String? messaged;

  @override
  Future<void> messageFriend(String person) async {
    messaged = person;
    selected = 'conversation';
    notifyListeners();
  }
}

void main() {
  for (final width in [390.0, 1280.0]) {
    testWidgets(
      'sidebar shows request status and opens the right contact at $width',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 850));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final narrow = width < 1000;
        if (!narrow) {
          tester.platformDispatcher.accessibilityFeaturesTestValue =
              const FakeAccessibilityFeatures(disableAnimations: true);
          addTearDown(
            tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
          );
        }

        final api = NavigationApi()
          ..loading = false
          ..user = {'sub': 'alice', 'username': 'Alice'}
          ..friends = [
            {'username': 'Bob', 'user_id': '@bob:home'},
          ]
          ..requests = [
            {
              'username': 'Cara',
              'user_id': '@cara:home',
              'direction': 'incoming',
            },
            {
              'username': 'Devon',
              'user_id': '@devon:home',
              'direction': 'outgoing',
            },
          ];
        await tester.pumpWidget(RiverApp(api: api, boot: false));
        await tester.pumpAndSettle();

        Future<void> showSidebar() async {
          if (narrow) {
            await tester.tap(find.byTooltip('Open navigation menu'));
            await tester.pumpAndSettle();
          }
        }

        Finder inSidebar(Finder matching) => find.descendant(
          of: find.byType(FriendsSidebar),
          matching: matching,
        );
        await showSidebar();
        expect(inSidebar(find.text('Bob')), findsOneWidget);
        expect(inSidebar(find.text('Incoming request')), findsOneWidget);
        expect(inSidebar(find.text('Sent · Pending')), findsOneWidget);

        await tester.tap(inSidebar(find.text('Devon')));
        await tester.pumpAndSettle();
        final search = find.widgetWithText(
          TextField,
          'Find a friend or request',
        );
        expect(
          tester.widget<TextField>(search).controller!.text,
          '@devon:home',
        );
        expect(find.text('Cancel request'), findsOneWidget);
        expect(find.text('Accept'), findsNothing);
        await navigation.back(tester);
        expect(find.byType(RiverHome), findsOneWidget);
        await navigation.forward(tester);
        expect(
          tester.widget<TextField>(search).controller!.text,
          '@devon:home',
        );

        final request = api.requests.removeAt(0);
        api.friends.add(request);
        api.notifyListeners();
        await tester.pumpAndSettle();
        await showSidebar();
        expect(
          tester
              .widget<ListTile>(
                inSidebar(find.widgetWithText(ListTile, 'Devon')),
              )
              .selected,
          isTrue,
        );
        expect(inSidebar(find.text('Cara')), findsOneWidget);
        expect(inSidebar(find.text('Incoming request')), findsNothing);
        expect(inSidebar(find.text('Sent · Pending')), findsOneWidget);
        await tester.tap(inSidebar(find.text('Friends')));
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(search).controller!.text, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final width in [390.0, 1440.0]) {
    for (final startInRoom in [false, true]) {
      testWidgets(
        'Friends stays open from ${startInRoom ? 'a room' : 'Home'} at $width',
        (tester) async {
          await tester.binding.setSurfaceSize(Size(width, 1100));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final api = NavigationApi()
            ..loading = false
            ..user = {'sub': 'alice', 'username': 'Alice'}
            ..groups = [
              {
                'id': 'conversation',
                'kind': 'dm',
                'membership': 'join',
                'name': 'Chat with Bob',
                'members': <Json>[],
              },
            ]
            ..friends = [
              {'username': 'Bob', 'user_id': '@bob:home', 'uses_app': true},
            ]
            ..selected = startInRoom ? 'conversation' : null;
          await tester.pumpWidget(RiverApp(api: api, boot: false));
          await tester.pumpAndSettle();

          Future<void> navigate(String name) async {
            if (width < 1000) {
              await tester.tap(find.byTooltip('Open navigation menu'));
              await tester.pumpAndSettle();
            }
            await tester.tap(find.widgetWithText(ListTile, name));
            await tester.pumpAndSettle();
          }

          await navigate('Friends');
          expect(api.selected, isNull);
          expect(find.byType(FriendsView), findsOneWidget);
          expect(find.byType(RiverHome), findsNothing);
          api.notifyListeners();
          await tester.pumpAndSettle();
          expect(find.byType(FriendsView), findsOneWidget);

          await navigation.back(tester);
          expect(find.byType(FriendsView), findsNothing);
          await navigation.forward(tester);
          expect(find.byType(FriendsView), findsOneWidget);
          await tester.ensureVisible(find.text('Message'));
          await tester.tap(find.text('Message'));
          await tester.pumpAndSettle();
          expect(api.messaged, '@bob:home');
          expect(api.selected, 'conversation');
          expect(find.byType(FriendsView), findsNothing);
          expect(find.byType(RichComposer), findsOneWidget);

          await navigate('Friends');
          await navigate('Home');
          expect(find.byType(RiverHome), findsOneWidget);
          expect(find.byType(FriendsView), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
