import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as q;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart';
import 'package:river/api.dart';
import 'package:river/main.dart';
import 'package:river/content_widgets.dart';
import 'package:river/publishing_widgets.dart';
import 'package:river/rich_composer.dart';
import 'package:river/workspace_widgets.dart';
import 'package:river/friends_view.dart';
import 'package:river/call_widgets.dart';

const journeyBridge = String.fromEnvironment('RIVER_JOURNEY_BRIDGE');

// The bridge binds only loopback, preserves real production responses and uses
// normal disposable-account native envelopes. No password/token is a Dart define.
class JourneyApi extends RiverApi {
  JourneyApi(this.actor) : super(live: true);
  final String actor;
  @override
  Uri uri(String path) => Uri.parse('$journeyBridge/$actor$path');
  @override
  Future<void> boot() async {
    // Peer-file discovery has its own transport suite. This journey covers
    // accounts/workspaces/content/calls, without opening file discovery meshes.
    defaultDomain =
        (await request('/auth/gravitas/config'))['defaultDomain'] as String;
    user = (await request('/api/session'))['user'] as Json;
    await refresh();
    loading = false;
    notifyListeners();
    startLive();
  }
}

void productionJourneyScenarios() {
  testWidgets(
    'real production contacts, workspace, content, unread and media revocation',
    (tester) async {
      final runtime = kIsWeb ? 'web' : 'android';
      final a = JourneyApi('alice'),
          b = JourneyApi('bob'),
          c = JourneyApi('carol');
      Future<T> io<T>(Future<T> Function() f) async {
        T? result;
        Object? failure;
        StackTrace? trace;
        await tester.runAsync(() async {
          try {
            result = await f();
          } catch (error, stack) {
            failure = error;
            trace = stack;
          }
        });
        if (failure != null) Error.throwWithStackTrace(failure!, trace!);
        return result as T;
      }

      Future<void> tick() async {
        await io(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 100));
      }

      Future<void> until(
        bool Function() condition,
        String reason, {
        int attempts = 200,
      }) async {
        for (var i = 0; i < attempts && !condition(); i++) {
          await tick();
        }
        expect(condition(), isTrue, reason: reason);
      }

      Future<void> visible(Finder f) async =>
          until(() => f.evaluate().isNotEmpty, 'missing $f');
      Future<void> tap(Finder f) async {
        await visible(f);
        await tester.ensureVisible(f);
        await tester.tap(f);
        await tester.pump(const Duration(milliseconds: 300));
      }

      Future<void> show(Widget child) async {
        await tester.pumpWidget(
          MaterialApp(
            key: UniqueKey(),
            localizationsDelegates:
                q.FlutterQuillLocalizations.localizationsDelegates,
            theme: ThemeData(useMaterial3: true),
            home: AnimatedBuilder(
              animation: Listenable.merge([a, b, c]),
              builder: (_, _) =>
                  child is RiverShell ? RiverShell(app: child.app) : child,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
      }

      Future<void> dialog(Widget child) async {
        await show(
          Builder(
            builder: (ctx) => Scaffold(
              body: TextButton(
                child: const Text('Open journey dialog'),
                onPressed: () =>
                    showDialog<void>(context: ctx, builder: (_) => child),
              ),
            ),
          ),
        );
        await tap(find.text('Open journey dialog'));
      }

      Future<void> source(String text) async {
        final composer = find.byType(RichComposer).last;
        await tap(
          find.descendant(of: composer, matching: find.text('Markdown')),
        );
        await tester.enterText(
          find.descendant(of: composer, matching: find.byType(TextField)).first,
          text,
        );
        await tester.pump(const Duration(milliseconds: 100));
      }

      Future<void> denied(Future<dynamic> Function() run, int status) async {
        try {
          await io(run);
          fail('expected HTTP $status');
        } on ApiException catch (e) {
          expect(e.status, status);
        }
      }

      void passed(String stage) {
        debugPrint('JOURNEY PASS [$runtime] $stage');
      }

      var stage = 'boot';
      try {
        await io(() async {
          await a.boot();
          await b.boot();
          await c.boot();
        });
        expect(a.error, isNull);
        expect(b.error, isNull);
        expect(c.error, isNull);
        expect(a.friends.length, 2);
        passed('real account profiles and central contact projection');
        stage = 'friend requests';
        // The counterpart initiates this cycle; initial setup exercised Alice's
        // requests. Keep production rate limits intact during repeated tests.
        await io(() => b.friendAction(a.user!['user_id'] as String, 'remove'));
        await io(() => b.friendAction(a.user!['user_id'] as String, 'request'));
        await io(() => b.friendAction(a.user!['user_id'] as String, 'cancel'));
        expect(b.requests, isEmpty);
        await io(() => b.friendAction(a.user!['user_id'] as String, 'request'));
        await io(a.refresh);
        await show(
          Scaffold(
            body: FriendsView(app: a, onConversation: () {}),
          ),
        );
        await tap(find.text('Accept'));
        await until(
          () => a.friends.any((p) => p['user_id'] == b.user!['user_id']),
          'accepted contact missing',
        );
        await io(b.refresh);
        passed('request, cancel, UI accept and central friendship');
        stage = 'space and channel creation';
        final spaceName = 'Automated $runtime journey';
        var space = a.groups
            .where((g) => g['name'] == spaceName && g['kind'] == 'space')
            .firstOrNull;
        if (space == null) {
          await io(() => a.open(null));
          await show(RiverShell(app: a));
          await tap(find.text('Create a space'));
          await tester.enterText(
            find.widgetWithText(TextField, 'Space name'),
            spaceName,
          );
          await tap(find.text('Continue'));
          await until(
            () => a.groups.any((g) => g['name'] == spaceName),
            'space create failed',
          );
          space = a.groups.firstWhere((g) => g['name'] == spaceName);
        }
        final sid = space['id'] as String;
        final lobby = a
            .channels(sid)
            .firstWhere(
              (g) => g['channel_kind'] == 'text' && g['name'] == 'lobby',
            );
        final voice = a
            .channels(sid)
            .firstWhere((g) => g['channel_kind'] == 'drop_in');
        expect(lobby['id'], isNot(voice['id']));
        await denied(() => c.request('/api/groups/$sid/events'), 403);
        // A failed prior attempt can leave this same disposable room invited.
        await io(b.refresh);
        final previous = b.groups.where((g) => g['id'] == sid).firstOrNull;
        if (previous?['membership'] == 'invite') {
          await io(() => b.membership(sid, 'leave'));
        } else if (previous?['membership'] == 'join') {
          await io(
            () => a.membership(sid, 'remove', b.user!['user_id'] as String),
          );
        }
        await io(
          () => a.membership(sid, 'invite', b.user!['user_id'] as String),
        );
        await io(b.refresh);
        expect(
          b.groups.firstWhere((g) => g['id'] == sid)['membership'],
          'invite',
        );
        await denied(() => b.request('/api/groups/$sid/events'), 403);
        await io(() => b.membership(sid, 'accept'));
        expect(
          b.channels(sid).map((g) => g['id']),
          containsAll([lobby['id'], voice['id']]),
        );
        await io(() => a.open(sid));
        await show(RiverShell(app: a));
        final channelName = 'journey-$runtime';
        var channel = a
            .channels(sid)
            .where((g) => g['name'] == channelName)
            .firstOrNull;
        if (channel == null) {
          await tap(find.byTooltip('Group options'));
          await tap(find.text('New text channel'));
          await tester.enterText(
            find.widgetWithText(TextField, 'Channel name'),
            channelName,
          );
          await tap(find.text('Continue'));
          await until(
            () => a.channels(sid).any((g) => g['name'] == channelName),
            'channel create failed',
          );
          channel = a.channels(sid).firstWhere((g) => g['name'] == channelName);
        }
        final cid = channel['id'] as String;
        await io(() => a.open(cid));
        await show(RiverShell(app: a));
        await source('Persisted $runtime channel message');
        await tap(find.byTooltip('Send'));
        await until(
          () => a.events.any(
            (e) =>
                (e['content'] as Json)['body'] ==
                'Persisted $runtime channel message',
          ),
          'message not saved',
        );
        expect(
          (await io(
            () => b.request('/api/groups/${lobby['id']}/events'),
          ))['events'].where(
            (dynamic e) =>
                (e['content'] as Json)['body'] ==
                'Persisted $runtime channel message',
          ),
          isEmpty,
        );
        passed(
          'UI space/channel creation, invitation/acceptance, channel isolation and ACLs',
        );
        stage = 'DM and group conversations';
        await io(() => a.messageFriend(b.user!['user_id'] as String));
        final dm = a.selected;
        await io(() => b.messageFriend(a.user!['user_id'] as String));
        expect(b.selected, dm);
        var conversation = a.groups
            .where((g) => g['name'] == '$runtime group journey')
            .firstOrNull;
        if (conversation == null) {
          await dialog(ConversationPicker(app: a));
          await tap(
            find.widgetWithText(
              CheckboxListTile,
              b.user!['username'] as String,
            ),
          );
          await tap(
            find.widgetWithText(
              CheckboxListTile,
              c.user!['username'] as String,
            ),
          );
          await tester.enterText(
            find.widgetWithText(TextField, 'Group name'),
            '$runtime group journey',
          );
          await tap(find.text('Start conversation'));
          await until(
            () => a.groups.any((g) => g['name'] == '$runtime group journey'),
            'group picker did not create conversation',
          );
          conversation = a.groups.firstWhere(
            (g) => g['name'] == '$runtime group journey',
          );
        }
        final conversationId = conversation['id'] as String;
        for (final peer in [b, c]) {
          await io(peer.refresh);
          if (peer.groups.firstWhere(
                (g) => g['id'] == conversationId,
              )['membership'] ==
              'invite') {
            await io(() => peer.membership(conversationId, 'accept'));
          }
        }
        await io(a.refresh);
        expect(
          (a.groups.firstWhere((g) => g['id'] == conversationId)['members']
                  as List)
              .length,
          3,
        );
        await io(() => a.inviteSpace(conversationId, sid));
        await io(c.refresh);
        expect(
          c.groups.firstWhere((g) => g['id'] == sid)['membership'],
          'invite',
        );
        await io(() => c.membership(sid, 'leave'));
        passed(
          'canonical pair DM, UI three-person group picker and space invitation card',
        );
        stage = 'unread and SSE';
        await io(() => b.open(null));
        final liveChanges = <void>[];
        final sub = b.changes.stream.listen((event) => liveChanges.add(event));
        final sent = await io(
          () => a.send(cid, 'm.room.message', {
            'body': 'Unread $runtime message',
            'msgtype': 'm.text',
          }, transactionId()),
        );
        const requireSse = bool.fromEnvironment(
          'RIVER_JOURNEY_REQUIRE_SSE',
          defaultValue: true,
        );
        if (requireSse) {
          await until(
            () => liveChanges.isNotEmpty,
            'production SSE invalidation missing',
          );
        } else {
          debugPrint(
            'JOURNEY NOTE [$runtime] SSE verification deferred until fixed backend deployment; explicit refresh used for this diagnostic run',
          );
          await io(b.refresh);
        }
        await until(
          () =>
              (b.groups
                          .where((g) => g['id'] == cid)
                          .firstOrNull?['unread_count']
                      as int? ??
                  0) >
              0,
          'unread not refreshed through SSE',
        );
        await io(() => b.markRead(cid, sent['event_id'] as String));
        final another = JourneyApi('bob');
        final read = await io(() => another.request('/api/groups'));
        expect(
          (read['groups'] as List).cast<Json>().firstWhere(
            (g) => g['id'] == cid,
          )['unread_count'],
          0,
        );
        another.dispose();
        await sub.cancel();
        passed(
          requireSse
              ? 'real SSE invalidation and durable cross-session unread acknowledgement'
              : 'durable cross-session unread acknowledgement (SSE assertion deferred)',
        );
        stage = 'visual post creation and authored edit';
        await dialog(EntryEditor(app: a, room: sid));
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Title'),
          '$runtime original post',
        );
        final editor = tester
            .widget<q.QuillEditor>(find.byType(q.QuillEditor))
            .controller;
        editor.replaceText(
          0,
          0,
          'Visual $runtime post body',
          const TextSelection.collapsed(offset: 0),
        );
        await tap(find.text('Post'));
        await until(
          () => find.byType(EntryEditor).evaluate().isEmpty,
          'post editor did not close',
        );
        final entries = await io(
          () => a.request('/api/groups/$sid/entries?kind=post'),
        );
        final post = (entries['events'] as List).cast<Json>().firstWhere(
          (e) => rendered(e)['title'] == '$runtime original post',
        );
        final pid = post['event_id'] as String;
        await denied(() => b.editEntry(sid, pid, 'Unauthorized', 'No'), 403);
        await dialog(EntryEditor(app: a, room: sid, entry: post));
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Title'),
          '$runtime edited post',
        );
        await source('**Edited $runtime post body**');
        await tap(find.text('Preview'));
        await tap(find.text('Save changes'));
        await until(
          () => find.byType(EntryEditor).evaluate().isEmpty,
          'post edit did not close',
        );
        final projected = await io(() => b.publicPost(pid));
        expect(
          (projected['entry'] as Json)['content']['title'],
          '$runtime edited post',
        );
        await show(PostScreen(app: b, event: pid));
        await visible(find.text('$runtime edited post'));
        await source('Private $runtime member comment');
        await tap(find.byTooltip('Send comment'));
        await visible(find.text('Private $runtime member comment'));
        await io(() => a.publication(sid, pid, 'public', 'public'));
        final anon = JourneyApi('anonymous');
        final public = await io(() => anon.publicPost(pid));
        expect(
          (public['comments'] as List).where(
            (dynamic e) =>
                (e['content'] as Json)['body'] ==
                'Private $runtime member comment',
          ),
          isEmpty,
        );
        await io(
          () => c.postComment(
            pid,
            'Public $runtime outsider comment',
            transactionId(),
            audience: 'public',
          ),
        );
        final open = await io(() => anon.publicPost(pid));
        expect(
          (open['comments'] as List).any(
            (dynamic e) =>
                (e['content'] as Json)['body'] ==
                'Public $runtime outsider comment',
          ),
          isTrue,
        );
        await io(() => a.publication(sid, pid, 'public', 'disabled'));
        await denied(
          () => c.postComment(
            pid,
            'Denied comment',
            transactionId(),
            audience: 'public',
          ),
          403,
        );
        await io(() => a.publication(sid, pid, 'public', 'public'));
        await io(() => a.postReaction(pid, '🚀', true));
        final reacted = await io(() => anon.publicPost(pid));
        expect(
          (reacted['entry']['reaction_summary'] as List).any(
            (dynamic r) => r['key'] == '🚀' && r['count'] == 1,
          ),
          isTrue,
        );
        await io(() => a.postReaction(pid, '🚀', false));
        anon.dispose();
        await io(b.refresh);
        expect(b.catchUp.where((e) => e['event_id'] == pid), isEmpty);
        passed(
          'visual post, immutable authored edit, UI member comment, public/private isolation, disabled comments, canonical reactions and entry read',
        );
        stage = 'discussion and threaded replies';
        await dialog(EntryEditor(app: a, room: sid, kind: 'discussion'));
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Title'),
          '$runtime discussion',
        );
        await source('Discussion $runtime body');
        await tap(find.text('Post'));
        await until(
          () => find.byType(EntryEditor).evaluate().isEmpty,
          'discussion editor did not close',
        );
        final discussions = await io(
          () => a.request('/api/groups/$sid/entries?kind=discussion'),
        );
        final root = (discussions['events'] as List).cast<Json>().firstWhere(
          (e) => rendered(e)['title'] == '$runtime discussion',
        );
        final did = root['event_id'] as String;
        await io(
          () => a.editEntry(
            sid,
            did,
            '$runtime revised discussion',
            'Revised discussion',
          ),
        );
        await show(ThreadScreen(app: b, room: sid, rootId: did));
        await visible(find.text('$runtime revised discussion'));
        await source('Threaded $runtime reply');
        await tap(find.byTooltip('Send reply'));
        await visible(find.text('Threaded $runtime reply'));
        final thread = await io(() => a.thread(sid, did));
        final reply = (thread['events'] as List).cast<Json>().firstWhere(
          (e) => (e['content'] as Json)['body'] == 'Threaded $runtime reply',
        );
        expect(reply['content']['m.relates_to']['event_id'], did);
        await io(() => a.react(sid, reply['event_id'] as String, '👍', true));
        await io(() => a.react(sid, reply['event_id'] as String, '👍', false));
        passed(
          'discussion create/edit, UI canonical threaded reply and reaction removal',
        );
        stage = 'real production media';
        await show(const Scaffold(body: Text('Production media journey')));
        a.calls.adaptiveStreamForTesting = false;
        b.calls.adaptiveStreamForTesting = false;
        await io(() => a.calls.join(voice));
        await io(() => b.calls.join(voice));
        await until(
          () =>
              a.calls.room?.remoteParticipants.length == 1 &&
              b.calls.room?.remoteParticipants.length == 1,
          'real room peers missing',
        );
        await show(RiverCallScreen(api: b));
        await io(a.calls.toggleCamera);
        await until(
          () => b.calls.room!.remoteParticipants.values.any(
            (p) => p.videoTrackPublications.any(
              (v) => v.track is RemoteVideoTrack,
            ),
          ),
          'remote camera not subscribed',
        );
        final video =
            b
                    .calls
                    .room!
                    .remoteParticipants
                    .values
                    .first
                    .videoTrackPublications
                    .first
                    .track
                as RemoteVideoTrack;
        num frames = 0;
        for (var i = 0; i < 100 && frames == 0; i++) {
          await tick();
          frames = (await io(video.getReceiverStats))?.framesDecoded ?? 0;
        }
        expect(frames, greaterThan(0));
        expect(
          b.calls.room!.remoteParticipants.values.first.audioTrackPublications
              .any((p) => p.track is RemoteAudioTrack),
          isTrue,
        );
        await tap(find.text('Mute'));
        await until(() => b.calls.muted, 'mute failed');
        await tap(find.text('Unmute'));
        await until(() => !b.calls.muted, 'unmute failed');
        final chat = b.calls.chat!;
        await io(
          () => b.send(chat, 'm.room.message', {
            'body': '$runtime current call chat',
            'msgtype': 'm.text',
          }, transactionId()),
        );
        await denied(() => c.request('/api/groups/$chat/events'), 403);
        await io(
          () => a.membership(sid, 'remove', b.user!['user_id'] as String),
        );
        await until(
          () => !b.calls.active,
          'membership revocation did not disconnect media',
          attempts: 400,
        );
        await denied(() => b.request('/api/groups/$chat/events'), 403);
        await io(
          () => a.membership(sid, 'invite', b.user!['user_id'] as String),
        );
        await io(() => b.membership(sid, 'accept'));
        await io(() => b.calls.join(voice));
        await until(
          () => a.calls.room!.remoteParticipants.length == 1,
          'rejoined participant missing',
        );
        final revoke = await io(
          () => http.post(Uri.parse('$journeyBridge/bob/control/revoke')),
        );
        expect(revoke.statusCode, 200, reason: revoke.body);
        await until(
          () => !b.calls.active && b.user == null,
          'consent revocation did not expire client and media',
          attempts: 400,
        );
        await until(
          () => a.calls.room!.remoteParticipants.isEmpty,
          'revoked participant remains on SFU',
          attempts: 400,
        );
        passed(
          'real audio/video decoding, mute/unmute, call-chat ACL, membership removal and live consent revocation',
        );
        expect(tester.takeException(), isNull);
      } catch (e, stack) {
        debugPrintStack(stackTrace: stack);
        debugPrint('JOURNEY FAILED [$runtime] stage=$stage: $e');
        rethrow;
      } finally {
        await io(() async {
          await a.calls.leave();
          await b.calls.leave();
          await c.calls.leave();
        });
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(milliseconds: 600));
        a.dispose();
        b.dispose();
        c.dispose();
      }
    },
    skip: journeyBridge.isEmpty,
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
