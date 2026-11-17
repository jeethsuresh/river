import 'package:flutter/material.dart';

/// Tactile presentation around an existing control; never owns its action.
class RiverPress extends StatefulWidget {
  const RiverPress({super.key, required this.child, this.enabled = true});
  final Widget child;
  final bool enabled;
  @override
  State<RiverPress> createState() => _RiverPressState();
}

class _RiverPressState extends State<RiverPress> {
  bool pressed = false;
  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    return Listener(
      onPointerDown: (_) {
        if (widget.enabled) setState(() => pressed = true);
      },
      onPointerUp: (_) => setState(() => pressed = false),
      onPointerCancel: (_) => setState(() => pressed = false),
      child: AnimatedScale(
        scale: pressed && widget.enabled && !reduced ? .95 : 1,
        duration: reduced
            ? Duration.zero
            : Duration(milliseconds: pressed ? 80 : 170),
        curve: Curves.easeOutCubic,
        child: widget.child,
      ),
    );
  }
}

/// Only genuinely new event IDs opt in. Hydrated/paginated history stays still.
class RiverMessageArrival extends StatefulWidget {
  const RiverMessageArrival({
    super.key,
    required this.animate,
    required this.child,
  });
  final bool animate;
  final Widget child;
  @override
  State<RiverMessageArrival> createState() => _RiverMessageArrivalState();
}

class _RiverMessageArrivalState extends State<RiverMessageArrival>
    with SingleTickerProviderStateMixin {
  late final controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: widget.animate ? 0 : 1,
  );
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      controller.value = 1;
    } else if (widget.animate &&
        !controller.isCompleted &&
        !controller.isAnimating) {
      controller.forward();
    }
  }

  @override
  void didUpdateWidget(covariant RiverMessageArrival oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate &&
        !oldWidget.animate &&
        !MediaQuery.disableAnimationsOf(context)) {
      controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    child: widget.child,
    builder: (context, child) {
      final t = Curves.easeOutCubic.transform(controller.value);
      return Transform.translate(
        offset: Offset(0, 6 * (1 - t)),
        child: Opacity(opacity: .78 + .22 * t, child: child),
      );
    },
  );
}

class RiverPageTransitions extends PageTransitionsBuilder {
  const RiverPageTransitions();
  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    final curved = animation.drive(CurveTween(curve: Curves.easeOutCubic));
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: curved.drive(
          Tween<Offset>(begin: const Offset(.025, 0), end: Offset.zero),
        ),
        child: child,
      ),
    );
  }
}
