import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:river/api.dart';
import 'matrix_messaging_test.dart' show matrixProfile;
import 'messaging_flows_test.dart' show FlowTransport, device, room;

class DirectTransport extends FlowTransport {
  bool denyEncryption = false;
  @override
  Future<Json> action(Json payload) async {
    if (denyEncryption && payload['action'] == 'encrypt') {
      actions.add(payload);
      throw StateError('Encryption permission changed');
    }
    return super.action(payload);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final scenario in [
    'new',
    'creator',
    'encrypted',
    'non-owner',
    'sync-change',
    'denied',
  ]) {
    test(
      'canonical DM $scenario preserves SDK encryption and permissions',
      () async {
        final encrypted = scenario == 'encrypted' || scenario == 'sync-change';
        final canEncrypt = ![
          'encrypted',
          'non-owner',
          'sync-change',
        ].contains(scenario);
        final sdk = <String, dynamic>{
          ...room('direct', '!direct:example.org'),
          'kind': 'dm',
          'encrypted': encrypted,
          'can_encrypt': canEncrypt,
        };
        final stale = {...sdk, 'encrypted': false, 'can_encrypt': true};
        final engine = DirectTransport()
          ..denyEncryption = scenario == 'denied'
          ..roomList = scenario == 'new'
              ? []
              : [scenario == 'sync-change' ? stale : sdk];
        final saved = await device(engine);
        final delegated = <Json>[
          if (scenario != 'new')
            {
              ...sdk,
              'owner': true,
              'encrypted': !encrypted,
              'can_encrypt': !canEncrypt,
            },
        ];
        final writes = <http.Request>[];
        final api = RiverApi(
          live: false,
          matrixEnabled: true,
          matrixFactory: (_) async => engine,
          matrixStorage: saved.storage,
          client: MockClient((request) async {
            if (request.method != 'GET') writes.add(request);
            if (request.url.path == '/api/direct') {
              if (scenario == 'new') delegated.add({...sdk, 'owner': true});
              engine.nextRooms = [sdk];
              return http.Response(
                '{"id":"direct","room_id":"!direct:example.org"}',
                200,
              );
            }
            return http.Response(
              jsonEncode(
                request.url.path == '/api/overview'
                    ? {'groups': delegated, 'recent': []}
                    : {
                        'friends': [
                          {'user_id': '@bob:example.org'},
                        ],
                        'requests': [],
                        'blocked': [],
                      },
              ),
              200,
            );
          }),
        )..user = Map.of(matrixProfile);
        await api.matrix.bind(matrixProfile);
        await api.refresh();

        if (scenario == 'denied') {
          await expectLater(
            api.conversation('Bob', ['@bob:example.org']),
            throwsStateError,
          );
          expect(api.selected, isNull);
          expect(engine.roomList.single['encrypted'], false);
        } else {
          await api.conversation('Bob', ['@bob:example.org']);
          expect(api.selected, 'direct');
          expect(api.encrypted('direct'), encrypted || canEncrypt);
          expect(api.group('direct')?['can_encrypt'], canEncrypt);
        }
        final encrypts = engine.actions.where((a) => a['action'] == 'encrypt');
        expect(encrypts, hasLength(canEncrypt && !encrypted ? 1 : 0));
        expect(engine.actions.where((a) => a['action'] == 'state'), isEmpty);
        expect(writes.map((r) => r.url.path), ['/api/direct']);
        api.dispose();
      },
    );
  }
}
