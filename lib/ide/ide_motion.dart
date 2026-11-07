import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// How the popups and controls under it come and go: still, or [lively]:
/// dialogs and menus grow in from a little smaller, fading, and fade out;
/// collapsible sections keep their content mounted until their exit
/// animation finishes; buttons rebound with a spring on release.
class IdeMotion extends InheritedWidget {
  const IdeMotion({super.key, required this.lively, required super.child});

  final bool lively;

  /// Fast start, gentle deceleration (`cubic-bezier(0.22, 1, 0.36, 1)`).
  /// Used for layout shifts, accordions, drawers, switches, and sliding pills.
  static const Curve easeOut = Cubic(0.22, 1.0, 0.36, 1.0);

  /// Dramatic expo settle (`cubic-bezier(0.16, 1, 0.3, 1)`).
  /// Used for modals, command palettes, popovers, and dropdown menus.
  static const Curve expoOut = Cubic(0.16, 1.0, 0.3, 1.0);

  /// Tactile overshoot rebound (`cubic-bezier(0.34, 1.56, 0.64, 1)`).
  /// Used for press-release scale feedback (`press-rebound`).
  static const Curve springOut = Cubic(0.34, 1.56, 0.64, 1.0);

  /// Crisp exit acceleration (`cubic-bezier(0.4, 0, 1, 1)`).
  static const Curve easeIn = Cubic(0.4, 0.0, 1.0, 1.0);

  static bool livelyOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<IdeMotion>()?.lively ?? true;

  /// A dialog's or a menu's coming in: [animation] from 0 to 1.
  static Widget enter(
    Animation<double> animation,
    Widget child, {
    Alignment alignment = Alignment.center,
    double from = 0.96,
    Offset slideFrom = const Offset(0, -0.015),
  }) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: expoOut,
      reverseCurve: easeIn,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: slideFrom,
          end: Offset.zero,
        ).animate(curved),
        child: ScaleTransition(
          alignment: alignment,
          scale: Tween(begin: from, end: 1.0).animate(curved),
          child: child,
        ),
      ),
    );
  }

  static const enterDuration = Duration(milliseconds: 200);
  static const exitDuration = Duration(milliseconds: 120);

  @override
  bool updateShouldNotify(IdeMotion oldWidget) => lively != oldWidget.lively;
}

/// [child] coming in as it is first built: fading, from a little smaller
/// and a few pixels [offset] off, settling where it is. A floating bar's
/// or menu's showing; keyed anew, it comes in again.
class PopIn extends StatelessWidget {
  const PopIn({
    super.key,
    required this.child,
    this.alignment = Alignment.bottomCenter,
    this.offset = const Offset(0, 4),
    this.duration = const Duration(milliseconds: 180),
  });

  final Widget child;

  /// Where it grows from.
  final Alignment alignment;
  final Offset offset;
  final Duration duration;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: duration,
    curve: IdeMotion.expoOut,
    child: child,
    builder: (context, t, child) => Opacity(
      opacity: t.clamp(0.0, 1.0),
      child: Transform.translate(
        offset: offset * (1 - t),
        child: Transform.scale(
          alignment: alignment,
          scale: 0.96 + 0.04 * t,
          child: child,
        ),
      ),
    ),
  );
}

/// Pure `transform` + `opacity` reveal without layout reflow or clipping.
///
/// The child takes its full layout size on the very first frame (so hit
/// testing works immediately and parent scrollables do not relayout every
/// frame) while visually fading and gliding into place.
class IdeReveal extends StatelessWidget {
  const IdeReveal({
    super.key,
    required this.child,
    this.offset = const Offset(0, -4),
    this.duration = const Duration(milliseconds: 180),
  });

  final Widget child;
  final Offset offset;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: duration,
      curve: IdeMotion.easeOut,
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: Transform.translate(offset: offset * (1 - t), child: child),
      ),
    );
  }
}

/// Tactile press-down and spring-rebound wrapper (`scale-feedback` /
/// `press-rebound`).
///
/// Scales down to [pressedScale] on pointer down (`100ms` ease-out) and
/// rebounds to `1.0` with [IdeMotion.springOut] (`180ms`) on release.
/// Uses [Listener] so it never competes with [GestureDetector] in the
/// gesture arena.
class IdePressScale extends StatefulWidget {
  const IdePressScale({
    super.key,
    required this.child,
    this.enabled = true,
    this.pressedScale = 0.95,
  });

  final Widget child;
  final bool enabled;
  final double pressedScale;

  @override
  State<IdePressScale> createState() => _IdePressScaleState();
}

class _IdePressScaleState extends State<IdePressScale> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || MediaQuery.disableAnimationsOf(context)) {
      return widget.child;
    }
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _setPressed(true),
      onPointerUp: (_) => _setPressed(false),
      onPointerCancel: (_) => _setPressed(false),
      child: AnimatedScale(
        scale: _pressed ? widget.pressedScale : 1.0,
        duration: _pressed
            ? const Duration(milliseconds: 95)
            : const Duration(milliseconds: 180),
        curve: _pressed ? IdeMotion.easeOut : IdeMotion.springOut,
        child: widget.child,
      ),
    );
  }
}

/// Standalone collapsible container that keeps its last built [child]
/// mounted while collapsing (`modal-exit` / `accordion`) and only unmounts
/// it after the collapse animation completes.
class IdeExpandable extends StatefulWidget {
  const IdeExpandable({
    super.key,
    required this.expanded,
    required this.child,
    this.alignment = Alignment.topCenter,
    this.duration = const Duration(milliseconds: 220),
    this.reverseDuration = const Duration(milliseconds: 170),
  });

  final bool expanded;
  final Widget? child;
  final Alignment alignment;
  final Duration duration;
  final Duration reverseDuration;

  @override
  State<IdeExpandable> createState() => _IdeExpandableState();
}

class _IdeExpandableState extends State<IdeExpandable>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    reverseDuration: widget.reverseDuration,
    value: widget.expanded && widget.child != null ? 1.0 : 0.0,
  )..addStatusListener(_onStatus);

  late final Animation<double> _heightFactor = CurvedAnimation(
    parent: _controller,
    curve: IdeMotion.easeOut,
    reverseCurve: Curves.easeInOutCubic,
  );

  late final Animation<double> _opacity = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.1, 1.0, curve: Curves.easeOut),
    reverseCurve: const Interval(0.2, 1.0, curve: Curves.easeIn),
  );

  Widget? _lastChild;

  @override
  void initState() {
    super.initState();
    if (widget.expanded) _lastChild = widget.child;
  }

  @override
  void didUpdateWidget(IdeExpandable oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller
      ..duration = widget.duration
      ..reverseDuration = widget.reverseDuration;
    if (widget.expanded && widget.child != null) {
      _lastChild = widget.child;
    }
    final shouldOpen = widget.expanded && widget.child != null;
    final wasOpen = oldWidget.expanded && oldWidget.child != null;
    if (shouldOpen != wasOpen) {
      if (MediaQuery.disableAnimationsOf(context)) {
        _controller.value = shouldOpen ? 1.0 : 0.0;
        if (!shouldOpen) _lastChild = null;
      } else if (shouldOpen) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && !widget.expanded && mounted) {
      setState(() => _lastChild = null);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final child = widget.expanded ? widget.child : _lastChild;
    if (child == null && _controller.isDismissed) {
      return const SizedBox.shrink();
    }
    return AnimatedBuilder(
      animation: _controller,
      child: child,
      builder: (context, child) {
        if (child == null || (_controller.isDismissed && !widget.expanded)) {
          return const SizedBox.shrink();
        }
        return ClipRect(
          child: Align(
            alignment: widget.alignment,
            heightFactor: _heightFactor.value.clamp(0.0, 1.0),
            child: Opacity(
              opacity: _opacity.value.clamp(0.0, 1.0),
              child: IgnorePointer(
                ignoring: !widget.expanded,
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Expandable body for chat steps ([EditStep], [CommandStep], [ToolCallRow])
/// inside `ChatHistoryView`'s `_HeightMotion`.
///
/// Does not wrap in `AnimatedSize` (avoiding double-height interpolation
/// against `_HeightMotion`). When opening, the body takes its full layout
/// height immediately so `_HeightMotion` measures the target height on
/// frame 0, while fading and gliding in. When closing, reports `0` layout
/// height immediately to `_HeightMotion` while keeping the closing body
/// painted in a zero-height overflow box for [closeDuration] so `_HeightMotion`
/// smoothly clips and fades it up instead of snapping to blank on frame 0.
class IdeStepBody extends StatefulWidget {
  const IdeStepBody({
    super.key,
    required this.expanded,
    required this.child,
    this.closeDuration = const Duration(milliseconds: 220),
  });

  final bool expanded;
  final Widget? child;
  final Duration closeDuration;

  @override
  State<IdeStepBody> createState() => _IdeStepBodyState();
}

class _IdeStepBodyState extends State<IdeStepBody>
    with SingleTickerProviderStateMixin {
  late final AnimationController _closeController = AnimationController(
    vsync: this,
    duration: widget.closeDuration,
  )..addStatusListener(_onCloseStatus);

  Widget? _closingChild;
  bool _animateOpen = false;

  @override
  void initState() {
    super.initState();
    if (widget.expanded) _closingChild = widget.child;
  }

  @override
  void didUpdateWidget(IdeStepBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    final openNow = widget.expanded && widget.child != null;
    final openBefore = oldWidget.expanded && oldWidget.child != null;
    if (openNow) {
      _closingChild = widget.child;
      if (!openBefore) {
        _closeController.stop();
        _animateOpen = true;
      }
    } else if (openBefore && !openNow) {
      if (MediaQuery.disableAnimationsOf(context)) {
        _closingChild = null;
      } else {
        _closeController.forward(from: 0);
      }
    }
  }

  void _onCloseStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && !widget.expanded && mounted) {
      setState(() => _closingChild = null);
    }
  }

  @override
  void dispose() {
    _closeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.expanded && widget.child != null) {
      if (_animateOpen) {
        return IdeReveal(
          offset: const Offset(0, -4),
          duration: const Duration(milliseconds: 190),
          child: widget.child!,
        );
      }
      return widget.child!;
    }
    final closing = _closingChild;
    if (closing == null || !_closeController.isAnimating) {
      return const SizedBox.shrink();
    }
    return Offstage(
      offstage: false,
      child: IgnorePointer(
        child: ExcludeSemantics(
          child: ExcludeFocus(
            child: AnimatedBuilder(
              animation: _closeController,
              child: closing,
              builder: (context, child) {
                final t = Curves.easeOutCubic.transform(_closeController.value);
                return _ZeroHeightOverflow(
                  child: Opacity(
                    opacity: (1.0 - t).clamp(0.0, 1.0),
                    child: Transform.translate(
                      offset: Offset(0, -4 * t),
                      child: child,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _ZeroHeightOverflow extends SingleChildRenderObjectWidget {
  const _ZeroHeightOverflow({super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderZeroHeightOverflow();
}

class _RenderZeroHeightOverflow extends RenderProxyBox {
  @override
  void performLayout() {
    final child = this.child;
    if (child != null) {
      child.layout(
        BoxConstraints(
          minWidth: constraints.minWidth,
          maxWidth: constraints.maxWidth,
        ),
        parentUsesSize: false,
      );
    }
    size = constraints.constrain(Size(constraints.maxWidth, 0));
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) => false;
}
