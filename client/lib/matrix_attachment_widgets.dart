import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:mime/mime.dart';
import 'api.dart';

Future<void> sendMatrixAttachment(
  BuildContext context,
  RiverApi app,
  String room,
) async {
  final engine = app.matrix.transport;
  final wire = app.matrixRoom(room);
  final account = app.accountKey;
  if (wire == null) throw StateError('Room is not available.');
  final picked = await FilePicker.pickFiles(withData: true);
  if (picked == null || !context.mounted) return;
  final file = picked.files.single;
  if (file.size > 32 * 1024 * 1024 || file.bytes == null) {
    throw StateError('Choose a file smaller than 32 MiB.');
  }
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Send attachment'),
      content: Text(
        '${file.name}\n${app.encrypted(room) ? 'Encrypted for this room’s members' : 'Shared with this room’s members'}',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Send'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  if (account != app.accountKey || app.matrix.transport != engine) {
    throw StateError('Your account changed.');
  }
  await app.sendMatrixFile(
    room,
    file.name,
    lookupMimeType(file.name, headerBytes: file.bytes) ??
        'application/octet-stream',
    file.bytes!,
  );
}

class MatrixAttachmentCard extends StatefulWidget {
  const MatrixAttachmentCard({
    super.key,
    required this.app,
    required this.content,
  });
  final RiverApi app;
  final Json content;
  @override
  State<MatrixAttachmentCard> createState() => _MatrixAttachmentCardState();
}

class _MatrixAttachmentCardState extends State<MatrixAttachmentCard> {
  Uint8List? bytes;
  bool busy = false;
  String? error;
  Future<void> download() async {
    final account = widget.app.accountKey;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.app.matrix.transport.downloadAttachment(
        widget.content,
      );
      if (mounted && account == widget.app.accountKey) {
        setState(() => bytes = result);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Unable to download and verify this attachment. Try again.',
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
      if (bytes != null && widget.content['msgtype'] == 'm.image')
        Image.memory(
          bytes!,
          height: 240,
          fit: BoxFit.contain,
          cacheWidth: 1000,
          errorBuilder: (_, _, _) => const Text(
            'This image cannot be displayed. You can save a copy.',
          ),
        ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.attach_file),
        title: Text(
          widget.content['filename'] as String? ??
              widget.content['body'] as String? ??
              'Attachment',
        ),
        subtitle: Text(
          error ??
              (widget.content['file'] != null
                  ? 'Encrypted Matrix attachment'
                  : 'Matrix attachment'),
        ),
        trailing: busy
            ? const CircularProgressIndicator()
            : IconButton(
                tooltip: bytes == null ? 'Download attachment' : 'Save a copy',
                icon: Icon(bytes == null ? Icons.download : Icons.save_alt),
                onPressed: bytes == null
                    ? download
                    : () async {
                        try {
                          await FilePicker.saveFile(
                            fileName:
                                widget.content['filename'] as String? ??
                                widget.content['body'] as String? ??
                                'attachment',
                            bytes: bytes,
                          );
                        } catch (_) {
                          if (mounted) {
                            setState(
                              () => error =
                                  'Unable to save this copy. Try again.',
                            );
                          }
                        }
                      },
              ),
      ),
    ],
  );
}
