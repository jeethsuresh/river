import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'api.dart';
import 'calls.dart';

Future<void> joinRiverCall(
  BuildContext context,
  RiverApi api,
  Json target,
) async {
  if (api.calls.active && api.calls.target?['id'] != target['id']) {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Switch calls?'),
        content: Text(
          'Leave ${api.calls.target?['name']} and join ${target['name']}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Stay here'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Switch'),
          ),
        ],
      ),
    );
    if (yes != true || !context.mounted) return;
  }
  try {
    await api.calls.join(target);
    if (context.mounted && api.calls.active) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => RiverCallScreen(api: api)),
      );
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(api.calls.error ?? 'Unable to join the call.')),
      );
    }
  }
}

class RiverCallBar extends StatelessWidget {
  const RiverCallBar({super.key, required this.api});
  final RiverApi api;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: api.calls,
    builder: (_, _) => !api.calls.active
        ? const SizedBox.shrink()
        : Material(
            color: const Color(0xffdfeaff),
            child: SafeArea(
              top: false,
              bottom: false,
              child: ListTile(
                dense: true,
                leading: const Icon(Icons.graphic_eq),
                title: Text(
                  api.calls.target?['name'] as String? ?? 'In a call',
                ),
                subtitle: Text(api.calls.error ?? 'Connected'),
                onTap: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(builder: (_) => RiverCallScreen(api: api)),
                ),
                trailing: Wrap(
                  children: [
                    IconButton(
                      tooltip: api.calls.muted
                          ? 'Unmute microphone'
                          : 'Mute microphone',
                      onPressed: api.calls.toggleMute,
                      icon: Icon(api.calls.muted ? Icons.mic_off : Icons.mic),
                    ),
                    IconButton(
                      tooltip: 'Leave call',
                      onPressed: api.calls.leave,
                      icon: const Icon(Icons.call_end, color: Colors.red),
                    ),
                  ],
                ),
              ),
            ),
          ),
  );
}

class RiverCallScreen extends StatelessWidget {
  const RiverCallScreen({super.key, required this.api});
  final RiverApi api;
  String name(Participant participant, RiverCalls calls) {
    if (participant.identity == calls.identity) return 'You';
    for (final call in api.activeCalls) {
      for (final p in ((call['participants'] as List?) ?? []).cast<Json>()) {
        if (p['identity'] == participant.identity) {
          return p['user_id'] as String;
        }
      }
    }
    return 'Unverified participant';
  }

  @override
  Widget build(BuildContext context) {
    final calls = api.calls;
    return ListenableBuilder(
      listenable: Listenable.merge([calls, api]),
      builder: (_, _) {
        final people = <Participant>[
          if (calls.room?.localParticipant != null)
            calls.room!.localParticipant!,
          ...?calls.room?.remoteParticipants.values,
        ];
        final tiles = <Widget>[];
        for (final person in people) {
          final videos = person.videoTrackPublications
              .where((p) => p.track is VideoTrack && !p.muted)
              .toList();
          if (videos.isEmpty) {
            tiles.add(
              _VideoTile(
                label: name(person, calls),
                speaking: person.isSpeaking,
              ),
            );
          }
          for (final publication in videos) {
            tiles.add(
              _VideoTile(
                label:
                    '${name(person, calls)}${publication.source == TrackSource.screenShareVideo ? ' · Screen' : ''}',
                track: publication.track as VideoTrack,
                speaking: person.isSpeaking,
              ),
            );
          }
        }
        return Scaffold(
          appBar: AppBar(
            title: Text(calls.target?['name'] as String? ?? 'Call'),
            actions: [
              IconButton(
                tooltip: 'Call chat',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.chat_bubble_outline),
              ),
            ],
          ),
          body: !calls.active
              ? const Center(child: Text('You’ve left the call.'))
              : Column(
                  children: [
                    if (calls.error != null)
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          calls.error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, box) => GridView.count(
                          padding: const EdgeInsets.all(16),
                          crossAxisCount: box.maxWidth > 700 ? 2 : 1,
                          childAspectRatio: 1.5,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          children: tiles,
                        ),
                      ),
                    ),
                    SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _control(
                              calls.muted ? 'Unmute' : 'Mute',
                              calls.muted ? Icons.mic_off : Icons.mic,
                              calls.toggleMute,
                              selected: calls.muted,
                              enabled: !calls.busy,
                            ),
                            _control(
                              'Camera',
                              Icons.videocam,
                              calls.toggleCamera,
                              selected: calls.cameraOn,
                              enabled: !calls.busy,
                            ),
                            _control(
                              calls.sharing ? 'Stop sharing' : 'Share screen',
                              Icons.screen_share_outlined,
                              calls.toggleSharing,
                              selected: calls.sharing,
                              enabled: !calls.busy,
                            ),
                            _control(
                              'Deafen',
                              Icons.headphones,
                              calls.toggleDeafen,
                              selected: calls.deafened,
                              enabled: !calls.busy,
                            ),
                            if (calls.android)
                              _control(
                                calls.speaker ? 'Speaker' : 'Earpiece',
                                Icons.volume_up,
                                calls.toggleSpeaker,
                                selected: calls.speaker,
                                enabled: !calls.busy,
                              ),
                            if (calls.cameraOn)
                              _control(
                                'Flip camera',
                                Icons.cameraswitch,
                                calls.switchCamera,
                                enabled: !calls.busy,
                              ),
                            _control('Leave', Icons.call_end, calls.leave),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }

  Widget _control(
    String label,
    IconData icon,
    VoidCallback action, {
    bool selected = false,
    bool enabled = true,
  }) => FilledButton.tonalIcon(
    style: FilledButton.styleFrom(
      backgroundColor: selected ? const Color(0xffbcd1ff) : null,
    ),
    onPressed: enabled ? action : null,
    icon: Icon(icon),
    label: Text(label),
  );
}

class _VideoTile extends StatelessWidget {
  const _VideoTile({required this.label, this.track, this.speaking = false});
  final String label;
  final VideoTrack? track;
  final bool speaking;
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: const Color(0xffe5edff),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(
        color: speaking ? Colors.blue : Colors.transparent,
        width: 3,
      ),
    ),
    clipBehavior: Clip.antiAlias,
    child: Stack(
      fit: StackFit.expand,
      children: [
        if (track != null)
          VideoTrackRenderer(track!)
        else
          const Center(child: Icon(Icons.person_outline, size: 64)),
        Positioned(
          left: 12,
          bottom: 12,
          child: Container(
            padding: const EdgeInsets.all(8),
            color: Colors.black54,
            child: Text(label, style: const TextStyle(color: Colors.white)),
          ),
        ),
      ],
    ),
  );
}
