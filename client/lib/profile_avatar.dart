import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'api.dart';
import 'river_design.dart';

/// One avatar for chats, spaces and people. Matrix's mark stays visible even
/// when a picture is missing, offline, or cannot be decoded.
class RiverProfileAvatar extends StatefulWidget {
  const RiverProfileAvatar({
    super.key,
    required this.app,
    required this.name,
    this.avatarUrl,
    this.matrix = false,
    this.icon,
    this.size = 34,
  });
  final RiverApi app;
  final String name;
  final String? avatarUrl;
  final bool matrix;
  final IconData? icon;
  final double size;

  @override
  State<RiverProfileAvatar> createState() => _RiverProfileAvatarState();
}

class _RiverProfileAvatarState extends State<RiverProfileAvatar> {
  Future<Uint8List?>? picture;
  Object? device;
  String? account;
  bool networkUnavailable = false;

  void load() {
    account = widget.app.accountKey;
    networkUnavailable = widget.app.networkUnavailable;
    device = widget.app.matrixConnected ? widget.app.matrix.transport : null;
    picture = widget.avatarUrl != null && device != null
        ? widget.app.matrix.avatar(widget.avatarUrl!)
        : null;
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(RiverProfileAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final reconnected = networkUnavailable && !widget.app.networkUnavailable;
    networkUnavailable = widget.app.networkUnavailable;
    if (oldWidget.app != widget.app ||
        oldWidget.avatarUrl != widget.avatarUrl ||
        account != widget.app.accountKey ||
        reconnected ||
        device !=
            (widget.app.matrixConnected ? widget.app.matrix.transport : null)) {
      load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final fallback = RiverAvatar(
      name: widget.name,
      icon: widget.icon,
      size: widget.size,
    );
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: FutureBuilder<Uint8List?>(
              key: ValueKey((account, device, widget.avatarUrl)),
              future: picture,
              builder: (context, snapshot) => snapshot.data == null
                  ? fallback
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(widget.size * .28),
                      child: Image.memory(
                        snapshot.data!,
                        width: widget.size,
                        height: widget.size,
                        fit: BoxFit.cover,
                        cacheWidth: 96,
                        errorBuilder: (_, _, _) => fallback,
                      ),
                    ),
            ),
          ),
          if (widget.matrix)
            Positioned(
              right: -3,
              bottom: -3,
              child: Tooltip(
                message: 'Matrix',
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 2,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: riverInk,
                    border: Border.all(color: Colors.white, width: 1.5),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const CustomPaint(
                    size: Size(14, 12),
                    painter: _MatrixMark(),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MatrixMark extends CustomPainter {
  const _MatrixMark();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 14, size.height / 12);
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawPath(
      Path()
        ..moveTo(3, 1)
        ..lineTo(1, 1)
        ..lineTo(1, 11)
        ..lineTo(3, 11)
        ..moveTo(11, 1)
        ..lineTo(13, 1)
        ..lineTo(13, 11)
        ..lineTo(11, 11)
        ..moveTo(4, 9)
        ..lineTo(4, 4)
        ..moveTo(4, 6)
        ..cubicTo(4, 4, 7, 4, 7, 6)
        ..lineTo(7, 9)
        ..moveTo(7, 6)
        ..cubicTo(7, 4, 10, 4, 10, 6)
        ..lineTo(10, 9),
      paint,
    );
  }

  @override
  bool shouldRepaint(_MatrixMark oldDelegate) => false;
}
