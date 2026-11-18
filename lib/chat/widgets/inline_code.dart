import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../theme/app_theme.dart';
import '../chat_find.dart' show ChatFindMarks;

/// Inline code: its text, on `textPreformat.background` painted by the
/// [InlineCodeText] it is in.
class InlineCodeSpan extends TextSpan {
  const InlineCodeSpan({
    super.text,
    super.style,
    super.children,
    super.recognizer,
    super.mouseCursor,
  });

  /// Compact ~4px (`px-1`) horizontal padding space on each side of [code],
  /// matching Antigravity's inline `<code>` pill without wide monospace gaps.
  static const _padStyle = TextStyle(fontSize: 6.6, letterSpacing: 0);

  factory InlineCodeSpan.padded(
    String code, {
    TextStyle? style,
    GestureRecognizer? recognizer,
    MouseCursor? mouseCursor,
  }) => InlineCodeSpan(
    style: style,
    recognizer: recognizer,
    mouseCursor: mouseCursor,
    children: [
      TextSpan(
        text: ' ',
        style: _padStyle,
        recognizer: recognizer,
        mouseCursor: mouseCursor,
      ),
      TextSpan(
        text: code,
        recognizer: recognizer,
        mouseCursor: mouseCursor,
      ),
      TextSpan(
        text: ' ',
        style: _padStyle,
        recognizer: recognizer,
        mouseCursor: mouseCursor,
      ),
    ],
  );
}

/// [span] as [Text.rich] does, its [InlineCodeSpan]s on their background.
///
/// Not the text's own `backgroundColor`: a paragraph paints the selection
/// under its text, and that background with the text, over the selection:
/// opaque (Dark Modern's), it hid a selected code's highlight. Painted here
/// before the paragraph, the background is under the selection instead, in
/// every theme.
class InlineCodeText extends StatelessWidget {
  const InlineCodeText(this.span, {super.key, this.maxLines});

  final InlineSpan span;

  /// Cut to as many lines, an ellipsis at the end; all of it when null.
  final int? maxLines;

  @override
  Widget build(BuildContext context) => _InlineCodeBackdrop(
    color: AppColors.inlineCodeBackground,
    child: ChatFindMarks(
      child: Text.rich(
        span,
        maxLines: maxLines,
        overflow: maxLines == null ? null : TextOverflow.ellipsis,
      ),
    ),
  );
}

class _InlineCodeBackdrop extends SingleChildRenderObjectWidget {
  const _InlineCodeBackdrop({required this.color, required super.child});

  final Color color;

  @override
  RenderInlineCodeBackdrop createRenderObject(BuildContext context) =>
      RenderInlineCodeBackdrop(color);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderInlineCodeBackdrop renderObject,
  ) => renderObject.color = color;
}

/// Paints, under its child, the background of each [InlineCodeSpan] of
/// the paragraph in it.
class RenderInlineCodeBackdrop extends RenderProxyBox {
  RenderInlineCodeBackdrop(this._color);

  static const radius = Radius.circular(4);

  Color get color => _color;
  Color _color;
  set color(Color value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  /// The paragraph within: [Text] may put a mouse region around it.
  RenderParagraph? get _paragraph {
    RenderObject? node = child;
    while (node != null && node is! RenderParagraph) {
      RenderObject? only;
      node.visitChildren((c) => only ??= c);
      node = only;
    }
    return node as RenderParagraph?;
  }

  /// Where in [span]'s text each [InlineCodeSpan] is.
  static List<TextSelection> codeRanges(InlineSpan span) {
    final ranges = <TextSelection>[];
    var at = 0;
    void walk(InlineSpan span) {
      switch (span) {
        case TextSpan(:final text, :final children):
          final start = at;
          at += text?.length ?? 0;
          children?.forEach(walk);
          if (span is InlineCodeSpan && at > start) {
            ranges.add(TextSelection(baseOffset: start, extentOffset: at));
          }
        case PlaceholderSpan():
          // Its object replacement character.
          at += 1;
      }
    }

    walk(span);
    return ranges;
  }

  /// [range] without the spaces that pad it at either end.
  static TextSelection _trimmed(String text, TextSelection range) {
    var start = range.start;
    var end = range.end;
    while (start < end && text[start] == ' ') {
      start++;
    }
    while (end > start && text[end - 1] == ' ') {
      end--;
    }
    return TextSelection(baseOffset: start, extentOffset: end);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_paragraph case final paragraph? when _color.a > 0) {
      final ranges = codeRanges(paragraph.text);
      if (ranges.isNotEmpty) {
        final transform = paragraph.getTransformTo(this);
        final paint = Paint()..color = _color;
        final text = paragraph.text.toPlainText(includeSemanticsLabels: false);
        for (final range in ranges) {
          final trimmed = _trimmed(text, range);
          if (trimmed.isCollapsed) continue;
          final merged = <Rect>[];
          for (final box in paragraph.getBoxesForSelection(trimmed)) {
            final rect = box.toRect();
            if (merged.isNotEmpty &&
                merged.last.top < rect.bottom &&
                rect.top < merged.last.bottom) {
              merged[merged.length - 1] = merged.last.expandToInclude(rect);
            } else {
              merged.add(rect);
            }
          }
          for (final boxRect in merged) {
            final raw = MatrixUtils.transformRect(
              transform,
              boxRect,
            ).shift(offset);
            final rect = Rect.fromLTRB(
              raw.left - 3.6,
              raw.top - 0.5,
              raw.right + 3.6,
              raw.bottom + 0.5,
            );
            context.canvas.drawRRect(
              RRect.fromRectAndRadius(rect, radius),
              paint,
            );
          }
        }
      }
    }
    super.paint(context, offset);
  }
}
