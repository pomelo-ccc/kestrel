import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Wheel and trackpad scrolling of a scroll view inside another:
///
/// - When the inner view can scroll in the gesture's direction, it scrolls the
///   inner view.
/// - As soon as the inner view reaches its top or bottom edge (or if the
///   gesture started outside the inner view), scrolling seamlessly continues
///   on the outer conversation scroll view instead of getting stuck.
class WheelLatch extends StatefulWidget {
  const WheelLatch({super.key, required this.child, this.keep = false});

  final Widget child;

  /// Legacy flag kept for API compatibility; edge overflow always passes to the
  /// outer scroll view so nested cards never trap page scrolling.
  final bool keep;

  static const gap = Duration(milliseconds: 300);

  @override
  State<WheelLatch> createState() => _WheelLatchState();
}

class _WheelLatchState extends State<WheelLatch> {
  // One gesture at a time, app wide: the last wheel event, and the scroll
  // view that has the gesture (null: none of these inner ones).
  static Duration? _lastWheel;
  static Object? _latched;
  static Duration? _latchedAt;
  static bool _watching = false;

  VelocityTracker? _panTracker;
  double _panForwarded = 0;

  /// Sees every wheel event, after the views under the pointer have: a
  /// gesture started anywhere else belongs to no inner view.
  static void _watch(PointerEvent event) {
    if (event is! PointerScrollEvent) return;
    final last = _lastWheel;
    final starts = last == null || event.timeStamp - last >= WheelLatch.gap;
    if (starts && _latchedAt != event.timeStamp) _latched = null;
    _lastWheel = event.timeStamp;
  }

  @override
  void initState() {
    super.initState();
    if (!_watching) {
      _watching = true;
      GestureBinding.instance.pointerRouter.addGlobalRoute(_watch);
    }
  }

  /// The wheel's move as [view]'s offset takes it: across with Shift held
  /// (a mouse's), so none of it down; turned round in a reversed view (live
  /// output's). As [Scrollable] itself does.
  static double _deltaIn(ScrollableState view, PointerScrollEvent event) {
    final across =
        event.kind == PointerDeviceKind.mouse &&
        HardwareKeyboard.instance.isShiftPressed;
    final dy = across ? event.scrollDelta.dx : event.scrollDelta.dy;
    return axisDirectionIsReversed(view.axisDirection) ? -dy : dy;
  }

  static bool _canMove(ScrollPosition position, double delta) {
    if (delta > 0) return position.pixels < position.maxScrollExtent - 0.5;
    if (delta < 0) return position.pixels > position.minScrollExtent + 0.5;
    return false;
  }

  void _handleSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final inner = Scrollable.maybeOf(context);
    if (inner == null) return;
    final delta = _deltaIn(inner, event);
    final position = inner.position;
    final canMove = _canMove(position, delta);

    final last = _lastWheel;
    if (last == null || event.timeStamp - last >= WheelLatch.gap) {
      _latched = canMove ? this : null;
      _latchedAt = event.timeStamp;
    } else if (_latched == this && !canMove) {
      // Reached the top or bottom edge mid-gesture: release latch so the outer
      // conversation continues scrolling smoothly.
      _latched = null;
    }

    if (_latched == this && canMove) {
      GestureBinding.instance.pointerSignalResolver.register(event, (event) {
        final pos = inner.position;
        final target = (pos.pixels + delta).clamp(
          pos.minScrollExtent,
          pos.maxScrollExtent,
        );
        if (target != pos.pixels) pos.pointerScroll(delta);
      });
      return;
    }

    final outer = Scrollable.maybeOf(inner.context);
    if (outer == null) return;
    GestureBinding.instance.pointerSignalResolver.register(
      event,
      (_) => outer.position.pointerScroll(_deltaIn(outer, event)),
    );
  }

  void _handlePanZoomStart(PointerPanZoomStartEvent event) {
    _panTracker = VelocityTracker.withKind(event.kind);
    _panForwarded = 0;
  }

  void _handlePanZoomUpdate(PointerPanZoomUpdateEvent event) {
    final inner = Scrollable.maybeOf(context);
    if (inner == null) return;
    final outer = Scrollable.maybeOf(inner.context);
    if (outer == null) return;

    final innerDelta = axisDirectionIsReversed(inner.axisDirection)
        ? event.panDelta.dy
        : -event.panDelta.dy;
    if (innerDelta == 0) return;

    // If the inner scrollable can move in this direction, let its own drag
    // recognizer handle it; once it hits its top or bottom boundary, forward
    // the trackpad pan directly to the outer conversation scrollable.
    if (_canMove(inner.position, innerDelta)) return;

    final outerDelta = axisDirectionIsReversed(outer.axisDirection)
        ? event.panDelta.dy
        : -event.panDelta.dy;
    final outerPos = outer.position;
    final next = (outerPos.pixels + outerDelta).clamp(
      outerPos.minScrollExtent,
      outerPos.maxScrollExtent,
    );
    if (next != outerPos.pixels) {
      outerPos.jumpTo(next);
    }
    _panForwarded += outerDelta;
    _panTracker?.addPosition(event.timeStamp, Offset(0, _panForwarded));
  }

  void _handlePanZoomEnd(PointerPanZoomEndEvent event) {
    final tracker = _panTracker;
    _panTracker = null;
    if (tracker == null || _panForwarded == 0) return;
    final inner = Scrollable.maybeOf(context);
    if (inner == null) return;
    final outer = Scrollable.maybeOf(inner.context);
    if (outer == null) return;
    final velocity = -tracker.getVelocity().pixelsPerSecond.dy;
    final outerPos = outer.position;
    if (velocity.abs() > kMinFlingVelocity &&
        outerPos is ScrollPositionWithSingleContext) {
      outerPos.goBallistic(velocity);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerSignal: _handleSignal,
      onPointerPanZoomStart: _handlePanZoomStart,
      onPointerPanZoomUpdate: _handlePanZoomUpdate,
      onPointerPanZoomEnd: _handlePanZoomEnd,
      child: widget.child,
    );
  }
}
