import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'api.dart';
import 'file_models.dart';

class AttachmentCard extends StatelessWidget {
  const AttachmentCard({super.key, required this.app, required this.file});
  final RiverApi app;
  final Json file;
  @override
  Widget build(BuildContext context) {
    final files = app.files;
    if (files == null) {
      return ListTile(
        leading: const Icon(Icons.insert_drive_file_outlined),
        title: Text(file.text('name')),
        subtitle: const Text('Reconnect to access this file'),
      );
    }
    return ListenableBuilder(
      listenable: files,
      builder: (context, _) {
        final status = files.status(file);
        final busy = [
          'locating',
          'queued',
          'receiving',
          'verifying',
        ].contains(status.phase);
        return FutureBuilder<Uint8List?>(
          future: status.phase == 'ready'
              ? files.cache.get(file)
              : Future.value(null),
          builder: (context, snapshot) {
            final bytes = snapshot.data;
            final image = [
              'image/png',
              'image/jpeg',
              'image/webp',
              'image/gif',
              'image/avif',
            ].contains(file.text('mime'));
            return Container(
              margin: const EdgeInsets.symmetric(vertical: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xfff1f5ff),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (image && bytes != null)
                    InkWell(
                      onTap: () => showDialog<void>(
                        context: context,
                        builder: (ctx) => Dialog.fullscreen(
                          child: Stack(
                            children: [
                              Center(
                                child: InteractiveViewer(
                                  child: Image.memory(bytes),
                                ),
                              ),
                              Positioned(
                                top: 16,
                                right: 16,
                                child: SafeArea(
                                  child: IconButton.filledTonal(
                                    tooltip: 'Close image',
                                    onPressed: () => Navigator.pop(ctx),
                                    icon: const Icon(Icons.close),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      child: Image.memory(
                        bytes,
                        height: 200,
                        width: double.infinity,
                        fit: BoxFit.contain,
                        cacheWidth: 800,
                        errorBuilder: (_, _, _) =>
                            const Icon(Icons.broken_image_outlined),
                      ),
                    ),
                  Row(
                    children: [
                      Icon(
                        image
                            ? Icons.image_outlined
                            : Icons.insert_drive_file_outlined,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          file.text('name'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(fileSize(file.number('size'))),
                    ],
                  ),
                  if (busy)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: LinearProgressIndicator(
                        value:
                            status.phase == 'receiving' ||
                                status.phase == 'verifying'
                            ? status.progress
                            : null,
                      ),
                    ),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          bytes != null
                              ? 'Saved on this device · shared with room members'
                              : status.detail ?? status.phase,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                      if (!busy && bytes == null)
                        IconButton(
                          tooltip: 'Retry file transfer',
                          onPressed: () => files.retry(file),
                          icon: const Icon(Icons.refresh),
                        ),
                      if (bytes != null)
                        IconButton(
                          tooltip: 'Save a copy',
                          onPressed: () async {
                            try {
                              await FilePicker.saveFile(
                                dialogTitle: 'Save a copy',
                                fileName: file.text('name'),
                                bytes: bytes,
                              );
                            } catch (_) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Unable to save this copy. Please try again.',
                                    ),
                                  ),
                                );
                              }
                            }
                          },
                          icon: const Icon(Icons.save_alt),
                        ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class PendingAttachments extends StatelessWidget {
  const PendingAttachments({
    super.key,
    required this.files,
    required this.remove,
  });
  final List<Json> files;
  final void Function(Json) remove;
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final f in files)
        InputChip(
          avatar: const Icon(Icons.attach_file, size: 16),
          label: Text('${f.text('name')} · ${fileSize(f.number('size'))}'),
          onDeleted: () => remove(f),
        ),
    ],
  );
}
