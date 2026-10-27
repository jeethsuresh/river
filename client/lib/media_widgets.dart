import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'media.dart';

/// A thin white contour follows transparent pixels as well as rectangular GIFs.
/// All layers resolve the same provider, retaining its animated image stream.
class StickerImage extends StatelessWidget {
  const StickerImage({super.key, required this.image, this.size = 160});
  final ImageProvider image;
  final double size;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: size + 8,
    height: size + 8,
    child: Stack(
      alignment: Alignment.center,
      children: [
        for (var i = 0; i < 8; i++)
          Transform.translate(
            offset: Offset(
              2.5 * math.cos(i * math.pi / 4),
              2.5 * math.sin(i * math.pi / 4),
            ),
            child: Image(
              image: image,
              width: size,
              height: size,
              fit: BoxFit.contain,
              color: Colors.white,
              colorBlendMode: BlendMode.srcIn,
              excludeFromSemantics: true,
              errorBuilder: (_, _, _) => const SizedBox(),
            ),
          ),
        Image(
          image: image,
          width: size,
          height: size,
          fit: BoxFit.contain,
          semanticLabel: 'Sticker',
          errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
        ),
      ],
    ),
  );
}

class LinkedImageScope extends InheritedWidget {
  const LinkedImageScope({
    super.key,
    required this.cache,
    this.networkAvailable = true,
    required super.child,
  });
  final LinkedImageCache? cache;
  final bool networkAvailable;
  @override
  bool updateShouldNotify(LinkedImageScope oldWidget) =>
      cache != oldWidget.cache ||
      networkAvailable != oldWidget.networkAvailable;
}

class LinkedMedia extends StatefulWidget {
  const LinkedMedia({
    super.key,
    required this.url,
    this.sticker = false,
    this.label = 'Image',
  });
  final String url, label;
  final bool sticker;
  @override
  State<LinkedMedia> createState() => _LinkedMediaState();
}

class _LinkedMediaState extends State<LinkedMedia> {
  bool busy = false;
  Future<Uint8List>? image;
  LinkedImageCache? _cache;
  bool _online = true;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = context
        .dependOnInheritedWidgetOfExactType<LinkedImageScope>();
    final cache = scope?.cache;
    final online = scope?.networkAvailable ?? true;
    if (image == null || cache != _cache || (!_online && online)) {
      _cache = cache;
      image =
          cache?.load(widget.url) ?? LinkedImageCache.loadPublic(widget.url);
    }
    _online = online;
  }

  @override
  void didUpdateWidget(LinkedMedia oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      image =
          _cache?.load(widget.url) ?? LinkedImageCache.loadPublic(widget.url);
    }
  }

  Future<void> save({bool convert = false}) async {
    setState(() => busy = true);
    try {
      final bytes =
          await (_cache?.load(widget.url) ??
              LinkedImageCache.loadPublic(widget.url));
      // Reject HTML error pages and unsupported image data before saving.
      final codec = await ui.instantiateImageCodec(bytes);
      codec.dispose();
      if (convert || widget.sticker) {
        await StickerLibrary.device.save(widget.url, bytes);
      }
      if (!convert) {
        final path = Uri.parse(widget.url).pathSegments.lastOrNull ?? '';
        final name = path.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
        await FilePicker.saveFile(
          dialogTitle: widget.sticker ? 'Save sticker' : 'Save image',
          fileName: name.isEmpty ? 'image' : name,
          bytes: bytes,
        );
      }
      if (mounted && (convert || widget.sticker)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved to stickers on this device.')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Unable to save this image. Check the image link and try again.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (mediaUri(widget.url) == null) {
      return const Text('Unsupported image link');
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FutureBuilder<Uint8List>(
            key: ValueKey(widget.url),
            future: image,
            builder: (context, snapshot) {
              final bytes = snapshot.data;
              if (bytes == null) {
                if (!snapshot.hasError) return const Text('Loading image…');
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Image unavailable. Connect to download it.'),
                    TextButton(
                      onPressed: () => setState(() {
                        image =
                            _cache?.load(widget.url) ??
                            LinkedImageCache.loadPublic(widget.url);
                      }),
                      child: const Text('Retry image'),
                    ),
                  ],
                );
              }
              if (widget.sticker) {
                return StickerImage(image: MemoryImage(bytes));
              }
              return ConstrainedBox(
                constraints: const BoxConstraints(
                  maxHeight: 300,
                  maxWidth: 560,
                ),
                child: Image.memory(
                  bytes,
                  fit: BoxFit.contain,
                  cacheWidth: 1000,
                  semanticLabel: widget.label,
                  errorBuilder: (_, _, _) => const Text(
                    'Unable to display this image. Check the link.',
                  ),
                ),
              );
            },
          ),
          Wrap(
            spacing: 8,
            children: [
              if (!widget.sticker)
                TextButton.icon(
                  onPressed: busy ? null : () => save(convert: true),
                  icon: const Icon(Icons.auto_awesome_outlined, size: 17),
                  label: const Text('Make sticker'),
                ),
              TextButton.icon(
                onPressed: busy ? null : save,
                icon: const Icon(Icons.save_alt, size: 17),
                label: Text(widget.sticker ? 'Save sticker' : 'Save image'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

Future<String?> chooseSticker(BuildContext context) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const StickerPicker(),
    );

class StickerPicker extends StatefulWidget {
  const StickerPicker({super.key});
  @override
  State<StickerPicker> createState() => _StickerPickerState();
}

class _StickerPickerState extends State<StickerPicker> {
  late final ready = StickerLibrary.device.load();
  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: 420,
      child: FutureBuilder<void>(
        future: ready,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(
              child: Text('Unable to open stickers on this device.'),
            );
          }
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final stickers = StickerLibrary.device.items;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Stickers on this device',
                  style: TextStyle(fontSize: 20),
                ),
              ),
              if (stickers.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Use “Make sticker” on an image or GIF to save it here.',
                  ),
                ),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 150,
                    mainAxisExtent: 155,
                  ),
                  itemCount: stickers.length,
                  itemBuilder: (context, index) {
                    final sticker = stickers[index];
                    return Column(
                      children: [
                        InkWell(
                          onTap: () => Navigator.pop(context, sticker.url),
                          child: StickerImage(
                            image: MemoryImage(sticker.bytes),
                            size: 100,
                          ),
                        ),
                        TextButton(
                          onPressed: () async {
                            try {
                              await StickerLibrary.device.remove(sticker);
                              if (mounted) setState(() {});
                            } catch (_) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Unable to remove sticker. Try again.',
                                    ),
                                  ),
                                );
                              }
                            }
                          },
                          child: const Text('Remove'),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

Future<String?> askMediaLink(BuildContext context) async {
  final input = TextEditingController();
  String? error;
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, update) => AlertDialog(
        title: const Text('Insert image or GIF'),
        content: TextField(
          controller: input,
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'Image or GIF URL',
            hintText: 'https://…',
            errorText: error,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final url = input.text.trim();
              if (mediaUri(url) == null) {
                update(() => error = 'Use an HTTP or HTTPS image URL.');
              } else {
                Navigator.pop(ctx, url);
              }
            },
            child: const Text('Insert'),
          ),
        ],
      ),
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 300));
  input.dispose();
  return result;
}
