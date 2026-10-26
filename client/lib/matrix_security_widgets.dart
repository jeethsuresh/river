import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import 'matrix_messaging.dart';
import 'matrix_camera_capture.dart';

/// Shows only device metadata. Recovery secrets and QR pixels live in this
/// screen's memory and never travel through the River relay or analytics.
class MatrixSecurityPanel extends StatefulWidget {
  const MatrixSecurityPanel({super.key, required this.messaging});
  final MatrixMessaging messaging;
  @override
  State<MatrixSecurityPanel> createState() => _MatrixSecurityPanelState();
}

class _MatrixSecurityPanelState extends State<MatrixSecurityPanel> {
  MatrixJson? snapshot;
  String? error, recoveryKey, qrFlow;
  MatrixJson? qr;
  bool busy = false, loading = false;
  Timer? timer;
  MatrixMessaging get messaging => widget.messaging;

  @override
  void initState() {
    super.initState();
    unawaited(load());
    timer = Timer.periodic(const Duration(seconds: 3), (_) => load());
  }

  @override
  void dispose() {
    timer?.cancel();
    recoveryKey = null;
    qr = null;
    super.dispose();
  }

  Future<void> load() async {
    if (loading || busy || !messaging.connected) return;
    loading = true;
    final engine = messaging.transport;
    try {
      final value = await engine.security();
      if (mounted && messaging.connected && messaging.transport == engine) {
        setState(() {
          snapshot = value;
          final flow = (value['requests'] as List)
              .cast<MatrixJson>()
              .where((r) => r['id'] == qrFlow)
              .firstOrNull;
          if (flow == null ||
              flow['done'] == true ||
              flow['cancelled'] == true) {
            qr = null;
            qrFlow = null;
          }
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Unable to refresh device security. Try again.');
      }
    } finally {
      loading = false;
    }
  }

  Future<void> run(Future<void> Function(MatrixTransport) operation) async {
    if (busy || !messaging.connected) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await operation(messaging.transport);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) {
        setState(() => busy = false);
        await load();
      }
    }
  }

  Future<String?> secret(String title, String label) async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
          decoration: InputDecoration(labelText: label),
          onSubmitted: (value) => Navigator.pop(ctx, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    // The route may still be animating; dispose after its text field unmounts.
    Future<void>.delayed(const Duration(seconds: 1), controller.dispose);
    return value;
  }

  Future<void> setup(MatrixTransport engine) async {
    var result = await engine.setupRecovery(null);
    final challenge = result['authentication'] as Map?;
    if (challenge != null) {
      if (!mounted) return;
      final password = await secret(
        'Confirm your Gravitas password',
        'Password',
      );
      if (password == null || password.isEmpty || !mounted) return;
      result = await engine.setupRecovery({
        'type': 'm.login.password',
        'session': challenge['session'],
        'identifier': {'type': 'm.id.user', 'user': messaging.userId},
        'password': password,
      });
    }
    if (result['authentication'] != null) {
      throw StateError('Authentication was not accepted. Try again.');
    }
    if (mounted) {
      setState(() => recoveryKey = result['recovery_key'] as String?);
    }
  }

  Future<void> scan(
    MatrixTransport engine,
    String flow, {
    bool camera = false,
  }) async {
    final Uint8List? bytes;
    if (camera) {
      bytes = await showDialog<Uint8List>(
        context: context,
        builder: (_) => const MatrixQrCamera(),
      );
    } else {
      final file = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['png', 'jpg', 'jpeg', 'webp'],
        withData: true,
      );
      final selected = file?.files.single;
      if (selected != null && selected.size > 16 * 1024 * 1024) {
        throw StateError('Choose an image smaller than 16 MiB.');
      }
      bytes = selected?.bytes;
    }
    if (bytes == null || !mounted) return;
    await engine.scanVerificationImage(flow, bytes);
    if (mounted) {
      setState(() {
        qr = null;
        qrFlow = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Encryption and devices',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          const Text(
            'Verify another device with a Matrix QR code or matching numbers. Your devices exchange keys using encrypted messages; Gravitas cannot read your private keys.',
          ),
          if (!messaging.connected) ...[
            const SizedBox(height: 12),
            Text(
              messaging.error ??
                  (messaging.connecting
                      ? 'Confirm Matrix messaging in your browser, then return to River.'
                      : 'Connect this device to send and read encrypted Matrix messages.'),
            ),
            FilledButton.icon(
              onPressed: messaging.connecting ? null : messaging.connect,
              icon: const Icon(Icons.lock_outline),
              label: const Text('Connect Matrix messaging'),
            ),
            if (messaging.connecting)
              TextButton(
                onPressed: messaging.cancelConnect,
                child: const Text('Cancel connection'),
              ),
          ] else ...[
            if (snapshot == null) const LinearProgressIndicator(),
            if (snapshot != null) ...[
              SelectableText('This device: ${snapshot!['device_id']}'),
              Text(
                snapshot!['identity_verified'] == true
                    ? 'Identity verified'
                    : 'Verify this device to restore your identity',
              ),
              Text(
                snapshot!['backup_enabled'] == true
                    ? 'Encrypted key backup enabled'
                    : 'Encrypted key backup is not enabled on this device',
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (snapshot!['has_identity'] != true ||
                      snapshot!['has_private_identity'] == true)
                    OutlinedButton(
                      onPressed: busy ? null : () => run(setup),
                      child: const Text('Set up encrypted recovery'),
                    ),
                  OutlinedButton(
                    onPressed: busy
                        ? null
                        : () => run((engine) async {
                            final key = await secret(
                              'Restore encrypted keys',
                              'Recovery key',
                            );
                            if (key != null && key.trim().isNotEmpty) {
                              await engine.recover(key.trim());
                            }
                          }),
                    child: const Text('Use recovery key'),
                  ),
                ],
              ),
              if (recoveryKey != null)
                Container(
                  margin: const EdgeInsets.symmetric(vertical: 12),
                  padding: const EdgeInsets.all(16),
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Keep this recovery key somewhere safe. You will need it if all your verified devices are lost.',
                      ),
                      const SizedBox(height: 8),
                      SelectableText(recoveryKey!),
                      TextButton(
                        onPressed: () => setState(() => recoveryKey = null),
                        child: const Text('I saved my key'),
                      ),
                    ],
                  ),
                ),
              for (final device
                  in (snapshot!['devices'] as List).cast<MatrixJson>())
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    device['verified'] == true
                        ? Icons.verified_user_outlined
                        : Icons.devices,
                  ),
                  title: Text(
                    '${device['name'] ?? device['device_id']}${device['is_current'] == true ? ' (this device)' : ''}',
                  ),
                  subtitle: Text(
                    '${device['device_id']} · ${device['verified'] == true ? 'Verified' : 'Unverified'}',
                  ),
                  trailing: device['is_current'] == true
                      ? null
                      : OutlinedButton(
                          onPressed: busy
                              ? null
                              : () => run((e) async {
                                  await e.requestVerification(
                                    device['device_id'] as String,
                                  );
                                }),
                          child: const Text('Verify'),
                        ),
                ),
              for (final flow
                  in (snapshot!['requests'] as List).cast<MatrixJson>())
                verification(flow),
            ],
          ],
          if (busy) const LinearProgressIndicator(),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    ),
  );

  Widget verification(MatrixJson flow) {
    final id = flow['id'] as String;
    if (flow['cancelled'] == true) {
      return const ListTile(title: Text('Device verification cancelled'));
    }
    if (flow['done'] == true) {
      return const ListTile(
        leading: Icon(Icons.verified_user),
        title: Text('Device verified. Encrypted keys can now sync.'),
      );
    }
    final ready = flow['ready'] == true;
    final numbers = flow['numbers'] as List?;
    return Container(
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(top: 12),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Verify ${flow['device_id'] ?? 'your other device'}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (!ready && flow['method'] == null) ...[
            Text(
              flow['started_here'] == true
                  ? 'Accept the request on your other device.'
                  : 'Only accept if you are signing in on another device.',
            ),
            if (flow['started_here'] != true)
              FilledButton(
                onPressed: busy
                    ? null
                    : () => run((e) async {
                        await e.verificationAction(id, 'accept');
                      }),
                child: const Text('Accept verification'),
              ),
          ],
          if (ready && flow['method'] != 'sas' && flow['method'] != 'qr')
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: busy
                      ? null
                      : () => run((e) async {
                          final code = await e.verificationQr(id);
                          if (mounted) {
                            setState(() {
                              qr = code;
                              qrFlow = id;
                            });
                          }
                        }),
                  child: const Text('Show QR code'),
                ),
                OutlinedButton(
                  onPressed: busy
                      ? null
                      : () => run((e) => scan(e, id, camera: true)),
                  child: const Text('Scan with camera'),
                ),
                TextButton(
                  onPressed: busy ? null : () => run((e) => scan(e, id)),
                  child: const Text('Read QR image'),
                ),
                TextButton(
                  onPressed: busy
                      ? null
                      : () => run((e) async {
                          await e.verificationAction(id, 'sas');
                        }),
                  child: const Text('Compare numbers instead'),
                ),
              ],
            ),
          if (qrFlow == id && qr != null) ...[
            const Text(
              'Scan this code with your other device. Keep this screen open.',
            ),
            Center(
              child: Semantics(
                label: 'Matrix device verification QR code',
                image: true,
                child: SizedBox(
                  width: 280,
                  height: 280,
                  child: CustomPaint(painter: MatrixQrPainter(qr!)),
                ),
              ),
            ),
          ],
          if (flow['method'] == 'qr' && flow['scanned'] == true) ...[
            const Text(
              'Did you scan this QR code on the device you want to trust?',
            ),
            FilledButton(
              onPressed: busy
                  ? null
                  : () => run((e) async {
                      await e.verificationAction(id, 'confirm_qr');
                    }),
              child: const Text('Yes, trust this device'),
            ),
          ],
          if (flow['method'] == 'qr' && flow['scanned'] != true && qrFlow != id)
            const Text('Confirm the scan on the device showing the QR code.'),
          if (flow['method'] == 'sas') ...[
            if (numbers == null)
              OutlinedButton(
                onPressed: busy
                    ? null
                    : () => run((e) async {
                        await e.verificationAction(id, 'accept_sas');
                      }),
                child: const Text('Show matching numbers'),
              ),
            if (numbers != null) ...[
              const Text('Check that all three numbers match on both devices.'),
              SelectableText(
                numbers.join('   '),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              FilledButton(
                onPressed: busy
                    ? null
                    : () => run((e) async {
                        await e.verificationAction(id, 'confirm_sas');
                      }),
                child: const Text('All numbers match'),
              ),
            ],
          ],
          TextButton(
            onPressed: busy
                ? null
                : () => run((e) async {
                    await e.verificationAction(id, 'cancel');
                    if (mounted) {
                      setState(() {
                        qr = null;
                        qrFlow = null;
                      });
                    }
                  }),
            child: const Text('Cancel / does not match'),
          ),
        ],
      ),
    );
  }
}

class MatrixQrPainter extends CustomPainter {
  MatrixQrPainter(this.code);
  final MatrixJson code;
  @override
  void paint(Canvas canvas, Size size) {
    final modules = code['size'] as int;
    final pixels = code['pixels'] as List;
    if (modules <= 0 || pixels.length != modules * modules) return;
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    // Four modules of quiet zone; whole-pixel modules keep the camera image crisp.
    final scale = (size.shortestSide / (modules + 8)).floorToDouble();
    final start = (size.shortestSide - modules * scale) / 2;
    final paint = Paint()
      ..color = Colors.black
      ..isAntiAlias = false;
    for (var y = 0; y < modules; y++) {
      for (var x = 0; x < modules; x++) {
        if (pixels[y * modules + x] == true) {
          canvas.drawRect(
            Rect.fromLTWH(start + x * scale, start + y * scale, scale, scale),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(MatrixQrPainter oldDelegate) => oldDelegate.code != code;
}

class MatrixQrCamera extends StatefulWidget {
  const MatrixQrCamera({super.key});
  @override
  State<MatrixQrCamera> createState() => _MatrixQrCameraState();
}

class _MatrixQrCameraState extends State<MatrixQrCamera> {
  final renderer = rtc.RTCVideoRenderer();
  rtc.MediaStream? stream;
  String? error;
  bool ready = false, capturing = false;
  @override
  void initState() {
    super.initState();
    unawaited(start());
  }

  Future<void> start() async {
    try {
      await renderer.initialize();
      final media = await rtc.navigator.mediaDevices.getUserMedia({
        'audio': false,
        'video': {
          'facingMode': 'environment',
          'width': {'ideal': 1280},
          'height': {'ideal': 720},
        },
      });
      if (!mounted) {
        for (final t in media.getTracks()) {
          await t.stop();
        }
        await media.dispose();
        return;
      }
      stream = media;
      renderer.srcObject = media;
      setState(() => ready = true);
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Camera unavailable. Allow camera access or use Read QR image.',
        );
      }
    }
  }

  Future<void> capture() async {
    setState(() => capturing = true);
    try {
      final bytes = await captureMatrixQrFrame(stream!.getVideoTracks().single);
      if (mounted) Navigator.pop(context, bytes);
    } catch (_) {
      if (mounted) {
        setState(() {
          error = 'Unable to read this frame. Try again or choose a QR image.';
          capturing = false;
        });
      }
    }
  }

  @override
  void dispose() {
    final media = stream;
    renderer.srcObject = null;
    if (media != null) {
      for (final track in media.getTracks()) {
        unawaited(track.stop());
      }
      unawaited(media.dispose());
    }
    unawaited(renderer.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Scan your other device’s QR code'),
    content: SizedBox(
      width: 480,
      height: 320,
      child: error != null
          ? Center(child: Text(error!))
          : ready
          ? rtc.RTCVideoView(
              renderer,
              objectFit: rtc.RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
            )
          : const Center(child: CircularProgressIndicator()),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: ready && !capturing ? capture : null,
        child: const Text('Read QR code'),
      ),
    ],
  );
}
