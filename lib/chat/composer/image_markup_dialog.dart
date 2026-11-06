import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/codicons.dart';
import '../chat_models.dart';

enum MarkupTool { rect, arrow, pen, mosaic }

class _MarkupStroke {
  _MarkupStroke({
    required this.tool,
    required this.color,
    required this.points,
  });

  final MarkupTool tool;
  final Color color;
  final List<Offset> points;
  final double strokeWidth = 3.5;
}

/// Opens the built-in lightweight image annotation & mosaic editor for [image],
/// returning the updated [ImageAttachment] if saved, or null if cancelled.
Future<ImageAttachment?> showImageMarkupDialog(
  BuildContext context,
  ImageAttachment image,
) async {
  final codec = await ui.instantiateImageCodec(image.bytes);
  final frame = await codec.getNextFrame();
  final decoded = frame.image;
  codec.dispose();
  if (!context.mounted) {
    decoded.dispose();
    return null;
  }
  return showDialog<ImageAttachment>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) =>
        _ImageMarkupDialog(attachment: image, decodedImage: decoded),
  );
}

class _ImageMarkupDialog extends StatefulWidget {
  const _ImageMarkupDialog({
    required this.attachment,
    required this.decodedImage,
  });

  final ImageAttachment attachment;
  final ui.Image decodedImage;

  @override
  State<_ImageMarkupDialog> createState() => _ImageMarkupDialogState();
}

class _ImageMarkupDialogState extends State<_ImageMarkupDialog> {
  MarkupTool _tool = MarkupTool.rect;
  Color _color = const Color(0xFFE53935);
  final List<_MarkupStroke> _strokes = [];
  _MarkupStroke? _activeStroke;
  bool _saving = false;

  static const _palette = <Color>[
    Color(0xFFE53935), // Red
    Color(0xFFF59E0B), // Amber
    Color(0xFF10B981), // Emerald
    Color(0xFF3B82F6), // Blue
  ];

  @override
  void dispose() {
    widget.decodedImage.dispose();
    super.dispose();
  }

  Offset _clampNormalized(Offset pos, Size canvasSize) {
    if (canvasSize.width <= 0 || canvasSize.height <= 0) return Offset.zero;
    return Offset(
      (pos.dx / canvasSize.width).clamp(0.0, 1.0),
      (pos.dy / canvasSize.height).clamp(0.0, 1.0),
    );
  }

  void _onPanStart(DragStartDetails details, Size canvasSize) {
    final pt = _clampNormalized(details.localPosition, canvasSize);
    setState(() {
      _activeStroke = _MarkupStroke(
        tool: _tool,
        color: _color,
        points: [pt, pt],
      );
    });
  }

  void _onPanUpdate(DragUpdateDetails details, Size canvasSize) {
    final active = _activeStroke;
    if (active == null) return;
    final pt = _clampNormalized(details.localPosition, canvasSize);
    setState(() {
      if (active.tool == MarkupTool.rect || active.tool == MarkupTool.arrow) {
        active.points[1] = pt;
      } else {
        active.points.add(pt);
      }
    });
  }

  void _onPanEnd(DragEndDetails details) {
    final active = _activeStroke;
    if (active == null) return;
    setState(() {
      _strokes.add(active);
      _activeStroke = null;
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final img = widget.decodedImage;
      final w = img.width.toDouble();
      final h = img.height.toDouble();
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w, h));
      final painter = _MarkupCanvasPainter(
        image: img,
        strokes: _strokes,
        activeStroke: null,
      );
      painter.paint(canvas, Size(w, h));
      final picture = recorder.endRecording();
      final rendered = await picture.toImage(img.width, img.height);
      final byteData = await rendered.toByteData(
        format: ui.ImageByteFormat.png,
      );
      rendered.dispose();
      picture.dispose();
      if (byteData == null || !mounted) return;
      final bytes = Uint8List.view(
        byteData.buffer,
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );
      Navigator.of(context).pop(
        ImageAttachment(
          bytes: bytes,
          mediaType: 'image/png',
          name: widget.attachment.name,
          number: widget.attachment.number,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accent;
    final imgW = widget.decodedImage.width.toDouble();
    final imgH = widget.decodedImage.height.toDouble();
    final aspect = imgH > 0 ? imgW / imgH : 1.0;

    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: AppColors.partBorder),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820, maxHeight: 680),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Codicons.edit, size: 16, color: accent),
                  const SizedBox(width: 8),
                  Text(
                    '🖼️ 图片标注与马赛克画板',
                    style: TextStyle(
                      color: AppColors.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 16),
                  _ToolButton(
                    label: '红框',
                    icon: Icons.crop_square_rounded,
                    selected: _tool == MarkupTool.rect,
                    onTap: () => setState(() => _tool = MarkupTool.rect),
                  ),
                  const SizedBox(width: 6),
                  _ToolButton(
                    label: '箭头',
                    icon: Icons.north_east_rounded,
                    selected: _tool == MarkupTool.arrow,
                    onTap: () => setState(() => _tool = MarkupTool.arrow),
                  ),
                  const SizedBox(width: 6),
                  _ToolButton(
                    label: '画笔',
                    icon: Icons.gesture_rounded,
                    selected: _tool == MarkupTool.pen,
                    onTap: () => setState(() => _tool = MarkupTool.pen),
                  ),
                  const SizedBox(width: 6),
                  _ToolButton(
                    label: '马赛克',
                    icon: Icons.grid_on_rounded,
                    selected: _tool == MarkupTool.mosaic,
                    onTap: () => setState(() => _tool = MarkupTool.mosaic),
                  ),
                  const SizedBox(width: 12),
                  if (_tool != MarkupTool.mosaic)
                    for (final c in _palette)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: GestureDetector(
                          onTap: () => setState(() => _color = c),
                          child: Container(
                            width: 18,
                            height: 18,
                            decoration: BoxDecoration(
                              color: c,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: _color == c
                                    ? Colors.white
                                    : Colors.transparent,
                                width: 2,
                              ),
                            ),
                          ),
                        ),
                      ),
                  const Spacer(),
                  IconButton(
                    tooltip: '撤销上一步',
                    onPressed: _strokes.isEmpty
                        ? null
                        : () => setState(() => _strokes.removeLast()),
                    icon: Icon(
                      Codicons.discard,
                      size: 15,
                      color: _strokes.isEmpty
                          ? AppColors.textFaint
                          : AppColors.text,
                    ),
                  ),
                  IconButton(
                    tooltip: '清空全部标注',
                    onPressed: _strokes.isEmpty
                        ? null
                        : () => setState(_strokes.clear),
                    icon: Icon(
                      Codicons.trash,
                      size: 15,
                      color: _strokes.isEmpty
                          ? AppColors.textFaint
                          : AppColors.text,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Flexible(
                child: Center(
                  child: AspectRatio(
                    aspectRatio: aspect,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final size = Size(
                          constraints.maxWidth,
                          constraints.maxHeight,
                        );
                        return ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: GestureDetector(
                            onPanStart: (d) => _onPanStart(d, size),
                            onPanUpdate: (d) => _onPanUpdate(d, size),
                            onPanEnd: _onPanEnd,
                            child: CustomPaint(
                              size: size,
                              painter: _MarkupCanvasPainter(
                                image: widget.decodedImage,
                                strokes: _strokes,
                                activeStroke: _activeStroke,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    '提示：在图片上按住鼠标拖拽即可绘制红框、箭头或涂抹马赛克',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 11.5),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(
                      '取消',
                      style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: accent),
                    onPressed: _saving ? null : _save,
                    icon: const Icon(Codicons.check, size: 14),
                    label: Text(
                      _saving ? '保存中…' : '保存标注并替换原图',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accent;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? accent.withValues(alpha: 0.16) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: selected ? accent : AppColors.partBorder,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 13,
              color: selected ? accent : AppColors.textMuted,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: selected ? accent : AppColors.text,
                fontSize: 11.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MarkupCanvasPainter extends CustomPainter {
  _MarkupCanvasPainter({
    required this.image,
    required this.strokes,
    required this.activeStroke,
  });

  final ui.Image image;
  final List<_MarkupStroke> strokes;
  final _MarkupStroke? activeStroke;

  @override
  void paint(Canvas canvas, Size size) {
    final src = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    final dst = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawImageRect(image, src, dst, Paint());

    final scale = math.max(size.width, size.height) / 600.0;
    final all = [...strokes, ?activeStroke];

    for (final s in all) {
      if (s.points.isEmpty) continue;
      final paint = Paint()
        ..color = s.color
        ..strokeWidth = s.strokeWidth * scale
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      Offset denorm(Offset p) => Offset(p.dx * size.width, p.dy * size.height);

      switch (s.tool) {
        case MarkupTool.rect:
          if (s.points.length >= 2) {
            final rect = Rect.fromPoints(
              denorm(s.points.first),
              denorm(s.points.last),
            );
            canvas.drawRRect(
              RRect.fromRectAndRadius(rect, Radius.circular(4 * scale)),
              paint,
            );
          }
        case MarkupTool.arrow:
          if (s.points.length >= 2) {
            final p1 = denorm(s.points.first);
            final p2 = denorm(s.points.last);
            canvas.drawLine(p1, p2, paint);
            final angle = math.atan2(p2.dy - p1.dy, p2.dx - p1.dx);
            final headLen = 14.0 * scale;
            const headAngle = 0.48;
            final path = Path()
              ..moveTo(p2.dx, p2.dy)
              ..lineTo(
                p2.dx - headLen * math.cos(angle - headAngle),
                p2.dy - headLen * math.sin(angle - headAngle),
              )
              ..moveTo(p2.dx, p2.dy)
              ..lineTo(
                p2.dx - headLen * math.cos(angle + headAngle),
                p2.dy - headLen * math.sin(angle + headAngle),
              );
            canvas.drawPath(path, paint);
          }
        case MarkupTool.pen:
          final path = Path();
          final first = denorm(s.points.first);
          path.moveTo(first.dx, first.dy);
          for (var i = 1; i < s.points.length; i++) {
            final pt = denorm(s.points[i]);
            path.lineTo(pt.dx, pt.dy);
          }
          canvas.drawPath(path, paint);
        case MarkupTool.mosaic:
          final cellSize = 14.0 * scale;
          for (final normPt in s.points) {
            final pt = denorm(normPt);
            for (var dx = -1; dx <= 1; dx++) {
              for (var dy = -1; dy <= 1; dy++) {
                final gx = ((pt.dx / cellSize).floor() + dx) * cellSize;
                final gy = ((pt.dy / cellSize).floor() + dy) * cellSize;
                final checker =
                    (((gx / cellSize).round() + (gy / cellSize).round()) & 1) ==
                    0;
                canvas.drawRect(
                  Rect.fromLTWH(gx, gy, cellSize, cellSize),
                  Paint()
                    ..style = PaintingStyle.fill
                    ..color = checker
                        ? const Color(0xEE22242A)
                        : const Color(0xEE383B44),
                );
              }
            }
          }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _MarkupCanvasPainter oldDelegate) => true;
}
