import 'package:flutter/material.dart';
import 'api.dart';

/// Finishes device setup before the account can enter River's messaging UI.
class MatrixSetup extends StatefulWidget {
  const MatrixSetup({super.key, required this.app});
  final RiverApi app;
  @override
  State<MatrixSetup> createState() => _MatrixSetupState();
}

class _MatrixSetupState extends State<MatrixSetup> {
  bool busy = false;
  int attempt = 0;
  String? error;

  Future<void> connect() async {
    if (busy || widget.app.matrix.connecting) return;
    final current = ++attempt;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.app.connectMessaging();
    } catch (e) {
      if (mounted && current == attempt) setState(() => error = '$e');
    } finally {
      if (mounted && current == attempt) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final connecting = busy || app.matrix.connecting;
    return PopScope(
      canPop: false,
      child: Scaffold(
        key: const ValueKey('required-matrix-setup'),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.forum_outlined, size: 48),
                    const SizedBox(height: 20),
                    Text(
                      'Connect messaging to finish signing in',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Signed in as ${app.user?['user_id'] ?? app.user?['username'] ?? ''}.',
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'River uses Matrix to send and receive messages. Connect this device before continuing to your conversations.',
                    ),
                    const SizedBox(height: 20),
                    if (connecting) ...[
                      const LinearProgressIndicator(),
                      const SizedBox(height: 12),
                      const Text(
                        'Confirm Matrix messaging in your browser, then return to River.',
                      ),
                    ],
                    if (error ?? app.matrix.error case final message?) ...[
                      const SizedBox(height: 12),
                      Text(
                        message,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      key: const ValueKey('complete-matrix-setup'),
                      onPressed: connecting ? null : connect,
                      icon: const Icon(Icons.lock_outline),
                      label: Text(
                        connecting
                            ? 'Connecting…'
                            : 'Connect Matrix and continue',
                      ),
                    ),
                    if (app.matrix.connecting)
                      TextButton(
                        onPressed: () async {
                          await app.matrix.cancelConnect();
                          if (mounted) {
                            setState(() {
                              attempt++;
                              busy = false;
                              error = null;
                            });
                          }
                        },
                        child: const Text('Cancel connection'),
                      ),
                    TextButton(
                      onPressed: () async {
                        try {
                          await app.logout();
                        } catch (e) {
                          if (mounted) setState(() => error = '$e');
                        }
                      },
                      child: const Text('Sign out'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
