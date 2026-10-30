import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// "Alanı işaretle": kullanıcının parmakla boyadığı bir çizgi. Noktalar ve
/// kalınlık KAYNAK görselin pikselleriyle tutulur -- ekrandaki yakınlaştırmadan
/// bağımsız; maske de aynı koordinatlarla çizilir.
class AiMaskStroke {
  const AiMaskStroke({required this.points, required this.width});
  final List<Offset> points;
  final double width;
}

/// Gönderilecek maske: kaynakla aynı piksel boyutunda PNG; değişecek alan
/// saydam (alfa 0), geri kalanı opak (OpenAI düzenleme maskesi kuralı).
/// [strokes] sayfada tutulur: "Değiştir" dendiğinde çizgiler geri gelir.
class AiMask {
  const AiMask({required this.png, required this.width, required this.height, required this.strokes});
  final Uint8List png;
  final int width;
  final int height;
  final List<AiMaskStroke> strokes;
}

/// Çizgiyi [canvas]a çizer (maske de ekrandaki kırmızı katman da aynı yolu
/// kullanır: ikisi birebir aynı alanı gösterir). Tek dokunuş nokta olur.
void paintAiMaskStroke(Canvas canvas, AiMaskStroke stroke, Paint paint) {
  if (stroke.points.isEmpty) return;
  if (stroke.points.length == 1) {
    canvas.drawCircle(stroke.points.first, stroke.width / 2, Paint()
      ..color = paint.color
      ..blendMode = paint.blendMode
      ..style = PaintingStyle.fill);
    return;
  }
  final path = Path()..moveTo(stroke.points.first.dx, stroke.points.first.dy);
  for (final p in stroke.points.skip(1)) {
    path.lineTo(p.dx, p.dy);
  }
  canvas.drawPath(
    path,
    Paint()
      ..color = paint.color
      ..blendMode = paint.blendMode
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke.width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round,
  );
}

/// [width]x[height] PNG: her yer opak beyaz, boyanan yerler saydam.
Future<Uint8List> buildAiMaskPng({required int width, required int height, required List<AiMaskStroke> strokes}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()));
  canvas.drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint()..color = const Color(0xFFFFFFFF));
  final clear = Paint()
    ..color = const Color(0xFF000000)
    ..blendMode = BlendMode.clear;
  for (final s in strokes) {
    paintAiMaskStroke(canvas, s, clear);
  }
  final image = await recorder.endRecording().toImage(width, height);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

/// Hiçbir yer boyanmadıysa maske YOK (bütün görsel düzenlenir, eskisi gibi).
Future<AiMask?> aiMaskFromStrokes({required int width, required int height, required List<AiMaskStroke> strokes}) async {
  final painted = [for (final s in strokes) if (s.points.isNotEmpty) s];
  if (painted.isEmpty) return null;
  final png = await buildAiMaskPng(width: width, height: height, strokes: painted);
  return AiMask(png: png, width: width, height: height, strokes: painted);
}
