import 'package:flutter/material.dart';

/// A rounded box with "弹" in it, the usual danmaku icon of Chinese players.
/// Filled while on, outlined and struck through while off; [settings] adds a
/// gear at the bottom right instead. Takes its color from the [IconTheme].
class DanmakuIcon extends StatelessWidget {
  const DanmakuIcon({
    super.key,
    this.enabled = true,
    this.settings = false,
    this.size = 24,
  });

  final bool enabled;

  final bool settings;

  final double size;

  @override
  Widget build(BuildContext context) {
    var color = IconTheme.of(context).color ?? Colors.white;
    var filled = enabled && !settings;
    var boxWidth = size * (settings ? 0.8 : 0.92);
    var box = Container(
      width: boxWidth,
      height: boxWidth * 0.8,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: filled ? color : null,
        border: Border.all(color: color, width: size / 14),
        borderRadius: BorderRadius.circular(size / 6),
      ),
      child: Text(
        '弹',
        style: TextStyle(
          color: filled
              ? (color.computeLuminance() > 0.5 ? Colors.black : Colors.white)
              : color,
          fontSize: boxWidth * 0.52,
          fontWeight: FontWeight.bold,
          height: 1,
        ),
      ),
    );
    return SizedBox.square(
      dimension: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (settings)
            Positioned(left: 0, top: size * 0.06, child: box)
          else
            box,
          if (settings)
            Positioned(
              right: 0,
              bottom: 0,
              child: Icon(Icons.settings_rounded, size: size * 0.5,
                  color: color),
            ),
          if (!enabled && !settings)
            CustomPaint(
              size: Size.square(size),
              painter: _Slash(color, size / 12),
            ),
        ],
      ),
    );
  }
}

class _Slash extends CustomPainter {
  _Slash(this.color, this.width);

  final Color color;

  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(
      Offset(size.width * 0.12, size.height * 0.12),
      Offset(size.width * 0.88, size.height * 0.88),
      Paint()
        ..color = color
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_Slash old) => old.color != color || old.width != width;
}
