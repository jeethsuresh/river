import 'package:flutter/material.dart';

class UsernameLogin extends StatefulWidget {
  const UsernameLogin({
    super.key,
    required this.defaultDomain,
    required this.onSubmit,
    required this.onRegister,
    this.onContinue,
    this.accessRequired = false,
    this.accessDenied = false,
  });
  final String defaultDomain;
  final Future<void> Function(String) onSubmit;
  final Future<void> Function() onRegister;
  final Future<void> Function()? onContinue;
  final bool accessRequired;
  final bool accessDenied;
  @override
  State<UsernameLogin> createState() => _UsernameLoginState();
}

class _UsernameLoginState extends State<UsernameLogin> {
  final username = TextEditingController();
  bool busy = false;
  bool showUsername = false;
  String? error;
  @override
  void dispose() {
    username.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    final value = username.text.trim();
    if (value.isNotEmpty) await run(() => widget.onSubmit(value));
  }

  Future<void> run(Future<void> Function() operation) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await operation();
    } catch (caught) {
      if (mounted) {
        setState(
            () => error = caught is StateError ? caught.message : '$caught',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (widget.onContinue != null) ...[
        FilledButton(
          onPressed: busy ? null : () => run(widget.onContinue!),
          child: Text(
            busy
                ? 'Connecting…'
                : widget.accessRequired
                ? 'Grant access'
                : 'Continue with Gravitas',
          ),
        ),
        if (!showUsername)
          TextButton(
            onPressed: busy ? null : () => setState(() => showUsername = true),
            child: const Text('Use another account'),
          ),
      ],
      if (widget.onContinue == null || showUsername) ...[
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: username,
                enabled: !busy,
                textCapitalization: TextCapitalization.none,
                autocorrect: false,
                enableSuggestions: false,
                autofillHints: const [AutofillHints.username],
                textInputAction: TextInputAction.go,
                onSubmitted: (_) => submit(),
                decoration: InputDecoration(
                  labelText: 'Username',
                  hintText: 'username@${widget.defaultDomain}',
                ),
              ),
            ),
            const SizedBox(width: 8),
            Semantics(
              label: 'Sign in',
              button: true,
              child: FilledButton(
                onPressed: busy ? null : submit,
                child: const Text('🔥'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Without a domain, sign in at ${widget.defaultDomain}.',
          style: const TextStyle(fontSize: 12),
        ),
      ],
      if (error != null || widget.accessDenied)
        Text(
          error ?? 'Access was declined.',
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      TextButton(
        onPressed: busy ? null : () => run(widget.onRegister),
        child: Text('Register at ${widget.defaultDomain}'),
      ),
    ],
  );
}
