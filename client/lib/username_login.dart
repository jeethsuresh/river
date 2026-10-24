import 'package:flutter/material.dart';

class UsernameLogin extends StatefulWidget {
  const UsernameLogin({
    super.key,
    required this.defaultDomain,
    required this.onSubmit,
    required this.onRegister,
  });
  final String defaultDomain;
  final Future<void> Function(String) onSubmit;
  final Future<void> Function() onRegister;
  @override
  State<UsernameLogin> createState() => _UsernameLoginState();
}

class _UsernameLoginState extends State<UsernameLogin> {
  final username = TextEditingController();
  bool busy = false;
  String? error;
  @override
  void dispose() {
    username.dispose();
    super.dispose();
  }

  Future<void> submit({bool register = false}) async {
    if (busy || (!register && username.text.trim().isEmpty)) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (register) {
        await widget.onRegister();
      } else {
        await widget.onSubmit(username.text.trim());
      }
    } catch (caught) {
      if (mounted) setState(() => error = '$caught');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
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
      if (error != null)
        Text(
          error!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      TextButton(
        onPressed: busy ? null : () => submit(register: true),
        child: Text('Register at ${widget.defaultDomain}'),
      ),
    ],
  );
}
