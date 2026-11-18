import 'package:flutter/material.dart';

import 'api.dart';
import 'river_feedback.dart';

class AddGravitasFriendButton extends StatelessWidget {
  const AddGravitasFriendButton({
    super.key,
    required this.app,
    this.initialUsername = '',
    this.enabled = true,
    this.onSent,
  });

  final RiverApi app;
  final String initialUsername;
  final bool enabled;
  final VoidCallback? onSent;

  Future<void> _open(BuildContext context) async {
    final account = app.accountKey;
    final sent = await showDialog<bool>(
      context: context,
      builder: (_) =>
          _AddGravitasFriendDialog(app: app, initialUsername: initialUsername),
    );
    if (sent == true && context.mounted && account == app.accountKey) {
      if (onSent case final callback?) {
        callback();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Gravitas contact request sent.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => RiverPress(
    enabled: enabled,
    child: FilledButton.tonalIcon(
      onPressed: enabled ? () => _open(context) : null,
      icon: const ElasticArt(child: Icon(Icons.person_add_outlined)),
      label: const Text('Add a friend'),
    ),
  );
}

class _AddGravitasFriendDialog extends StatefulWidget {
  const _AddGravitasFriendDialog({
    required this.app,
    required this.initialUsername,
  });

  final RiverApi app;
  final String initialUsername;

  @override
  State<_AddGravitasFriendDialog> createState() =>
      _AddGravitasFriendDialogState();
}

class _AddGravitasFriendDialogState extends State<_AddGravitasFriendDialog> {
  late final String? _account;
  late final _username = TextEditingController(text: widget.initialUsername);
  bool _sending = false;
  bool _needsConsent = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _account = widget.app.accountKey;
    _needsConsent = widget.app.friendsStatus == 403;
  }

  @override
  void dispose() {
    _username.dispose();
    super.dispose();
  }

  Future<void> _reconnect() async {
    if (_account != widget.app.accountKey) return;
    try {
      await widget.app.login();
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not reconnect to Gravitas. Try again.');
      }
    }
  }

  Future<void> _send() async {
    final username = _username.text.trim();
    if (_sending || username.isEmpty || _account != widget.app.accountKey) {
      return;
    }
    final route = ModalRoute.of(context);
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.app.friendAction(username, 'request');
      if (mounted && route?.isCurrent == true) Navigator.pop(context, true);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _needsConsent = error.code == 'insufficient_scope';
        _error = switch (error.code) {
          'invalid_member' ||
          'invalid_request' => 'Check the Gravitas username and try again.',
          'invalid_membership' =>
            'You may already be connected or have a pending request. Check Friends.',
          'forbidden' => 'This person can’t receive your request.',
          _ => '$error',
        };
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not send the request. Try again.');
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canSend = !_sending && _username.text.trim().isNotEmpty;
    return AlertDialog(
      title: const Text('Add a Gravitas contact'),
      scrollable: true,
      content: TextField(
        controller: _username,
        autofocus: true,
        readOnly: _sending,
        maxLength: 100,
        textInputAction: TextInputAction.send,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: 'Gravitas username',
          hintText: 'alice',
          errorText:
              _error ??
              (_needsConsent
                  ? 'Reconnect to give River access to your Gravitas contacts.'
                  : null),
          errorMaxLines: 3,
        ),
        onChanged: (_) => setState(() => _error = null),
        onSubmitted: (_) => _send(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(_sending ? 'Close' : 'Cancel'),
        ),
        if (_needsConsent)
          TextButton(
            onPressed: _sending ? null : _reconnect,
            child: const Text('Reconnect'),
          ),
        RiverPress(
          enabled: canSend,
          child: FilledButton.icon(
            onPressed: canSend ? _send : null,
            icon: _sending
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const ElasticArt(child: Icon(Icons.send_outlined, size: 18)),
            label: Semantics(
              liveRegion: true,
              child: Text(_sending ? 'Sending…' : 'Send request'),
            ),
          ),
        ),
      ],
    );
  }
}
