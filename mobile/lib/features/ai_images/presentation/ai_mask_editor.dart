import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_buttons.dart';
import '../data/ai_mask.dart';

/// "Alanı işaretle" sonucu: [mask] null = hiçbir yer boyanmadı (bütün
/// görsel düzenlenir). Sayfa vazgeçilerek kapanırsa sonuç hiç dönmez.
typedef AiMaskEditResult = ({AiMask? mask});

/// Kalem kalınlığı EKRAN noktasıyla (yakınlaştırınca ince iş yapılabilsin):
/// küçük / orta / büyük.
const kAiBrushSizes = [(label: 'Küçük', size: 12.0), (label: 'Orta', size: 28.0), (label: 'Büyük', size: 56.0)];

/// Tam ekran işaretleme: tek parmak boyar, iki parmak yakınlaştırır ve
/// kaydırır. Kırmızı yarı saydam katman işaretli alanı gösterir.
Future<AiMaskEditResult?> showAiMaskEditor(
  BuildContext context, {
  required Uint8List sourceBytes,
  List<AiMaskStroke> initial = const [],
}) {
  return Navigator.of(context, rootNavigator: true).push<AiMaskEditResult>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => AiMaskEditorScreen(sourceBytes: sourceBytes, initial: initial),
    ),
  );
}

class AiMaskEditorScreen extends StatefulWidget {
  const AiMaskEditorScreen({super.key, required this.sourceBytes, this.initial = const []});
  final Uint8List sourceBytes;
  final List<AiMaskStroke> initial;

  @override
  State<AiMaskEditorScreen> createState() => _AiMaskEditorScreenState();
}

class _AiMaskEditorScreenState extends State<AiMaskEditorScreen> {
  ui.Image? _image;
  bool _failed = false;
  bool _saving = false;
  late final List<AiMaskStroke> _strokes = List.of(widget.initial);
  AiMaskStroke? _current;
  int _brush = 1;

  // Görünüm dönüşümü: ekran = _offset + _scale * (sığdırılmış görsel).
  double _scale = 1;
  Offset _offset = Offset.zero;
  double _startScale = 1;
  Offset _startOffset = Offset.zero;
  Offset _startFocal = Offset.zero;
  int _pointers = 0;

  /// Ekrandaki parmak sayısı ve bu dokunuşta yakınlaştırma yapıldı mı:
  /// iki parmaktan biri kalkınca kalan parmak boyamaya başlamasın (tanıyıcı
  /// tek parmakla yeniden başlar); hepsi kalkınca sıfırlanır.
  int _down = 0;
  bool _pinched = false;

  /// Görselin ekrana sığdırılması (LayoutBuilder'da hesaplanır).
  double _fit = 1;
  Offset _base = Offset.zero;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  Future<void> _decode() async {
    try {
      // Maskenin boyutu, çözülen kaynağın GERÇEK piksel boyutu.
      final codec = await ui.instantiateImageCodec(widget.sourceBytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() => _image = frame.image);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  /// Ekran noktası -> kaynak piksel.
  Offset _toImage(Offset view) => ((view - _offset) / _scale - _base) / _fit;

  void _onScaleStart(ScaleStartDetails d) {
    _pointers = d.pointerCount;
    _startScale = _scale;
    _startOffset = _offset;
    _startFocal = d.localFocalPoint;
    if (d.pointerCount == 1 && !_pinched) {
      final width = kAiBrushSizes[_brush].size / (_scale * _fit);
      setState(() => _current = AiMaskStroke(points: [_toImage(d.localFocalPoint)], width: width));
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (d.pointerCount >= 2) {
      // İkinci parmak değdi: başlayan çizgi boyama değil yakınlaştırmaymış.
      _pinched = true;
      if (_pointers < 2) {
        _pointers = d.pointerCount;
        _startScale = _scale;
        _startOffset = _offset;
        _startFocal = d.localFocalPoint;
      }
      final next = (_startScale * d.scale).clamp(1.0, 8.0);
      final content = (_startFocal - _startOffset) / _startScale;
      setState(() {
        _current = null;
        _scale = next;
        _offset = d.localFocalPoint - content * next;
      });
      return;
    }
    final current = _current;
    if (current == null || _pointers >= 2) return;
    setState(() => current.points.add(_toImage(d.localFocalPoint)));
  }

  void _onScaleEnd(ScaleEndDetails d) {
    final current = _current;
    if (current != null && _pointers < 2) _strokes.add(current);
    setState(() => _current = null);
    if (d.pointerCount == 0) _pointers = 0;
  }

  void _lift() {
    _down = math.max(0, _down - 1);
    if (_down == 0) _pinched = false;
  }

  Future<void> _done() async {
    final image = _image;
    if (image == null) return;
    setState(() => _saving = true);
    final mask = await aiMaskFromStrokes(width: image.width, height: image.height, strokes: _strokes);
    if (!mounted) return;
    Navigator.of(context).pop<AiMaskEditResult>((mask: mask));
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Alanı işaretle'),
        actions: [
          IconButton(
            key: const ValueKey('ai-mask-undo'),
            tooltip: 'Geri al',
            icon: const Icon(Icons.undo),
            onPressed: _strokes.isEmpty ? null : () => setState(_strokes.removeLast),
          ),
          IconButton(
            key: const ValueKey('ai-mask-clear'),
            tooltip: 'Temizle',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: _strokes.isEmpty ? null : () => setState(_strokes.clear),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: image == null
                  ? Center(
                      child: _failed
                          ? const Text('Fotoğraf açılamadı.', style: TextStyle(color: Colors.white70))
                          : const CircularProgressIndicator(color: Colors.white),
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        final view = constraints.biggest;
                        _fit = math.min(view.width / image.width, view.height / image.height);
                        _base = Offset((view.width - image.width * _fit) / 2, (view.height - image.height * _fit) / 2);
                        return ClipRect(
                          child: Listener(
                            onPointerDown: (_) => _down++,
                            onPointerUp: (_) => _lift(),
                            onPointerCancel: (_) => _lift(),
                            child: GestureDetector(
                              key: const ValueKey('ai-mask-canvas'),
                              behavior: HitTestBehavior.opaque,
                              onScaleStart: _onScaleStart,
                              onScaleUpdate: _onScaleUpdate,
                              onScaleEnd: _onScaleEnd,
                              child: CustomPaint(
                                size: view,
                                painter: _MaskPainter(
                                  image: image,
                                  strokes: [..._strokes, ?_current],
                                  scale: _scale,
                                  offset: _offset,
                                  fit: _fit,
                                  base: _base,
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            _Panel(
              brush: _brush,
              onBrush: (i) => setState(() => _brush = i),
              saving: _saving,
              onCancel: () => Navigator.of(context).pop(),
              onDone: image == null || _saving ? null : _done,
            ),
          ],
        ),
      ),
    );
  }
}

/// Alt bölüm: ipucu, kalem kalınlığı, Vazgeç / Tamam. Wrap ve esnek satırlar:
/// 320 pt'de ve büyük yazıda taşmasın.
class _Panel extends StatelessWidget {
  const _Panel({
    required this.brush,
    required this.onBrush,
    required this.saving,
    required this.onCancel,
    required this.onDone,
  });

  final int brush;
  final ValueChanged<int> onBrush;
  final bool saving;
  final VoidCallback onCancel;
  final VoidCallback? onDone;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.sm),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Değişecek yeri tek parmakla boya; iki parmakla yakınlaştır ve kaydır. Boyamazsan bütün görsel düzenlenir.',
            style: AppTypography.helper,
          ),
          Row(
            children: [
              const Icon(Icons.brush_outlined, size: 18, color: AppColors.textMuted),
              Expanded(
                child: Slider(
                  key: const ValueKey('ai-mask-brush'),
                  value: brush.toDouble(),
                  min: 0,
                  max: (kAiBrushSizes.length - 1).toDouble(),
                  divisions: kAiBrushSizes.length - 1,
                  label: kAiBrushSizes[brush].label,
                  onChanged: (v) => onBrush(v.round()),
                ),
              ),
              Text(kAiBrushSizes[brush].label, style: AppTypography.metadata),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: SecondaryButton(label: 'Vazgeç', onPressed: saving ? null : onCancel),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: PrimaryButton(
                  key: const ValueKey('ai-mask-done'),
                  label: 'Tamam',
                  loading: saving,
                  onPressed: onDone,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MaskPainter extends CustomPainter {
  _MaskPainter({
    required this.image,
    required this.strokes,
    required this.scale,
    required this.offset,
    required this.fit,
    required this.base,
  });

  final ui.Image image;
  final List<AiMaskStroke> strokes;
  final double scale;
  final Offset offset;
  final double fit;
  final Offset base;

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..save()
      ..translate(offset.dx, offset.dy)
      ..scale(scale)
      ..translate(base.dx, base.dy)
      ..scale(fit);
    canvas.drawImage(image, Offset.zero, Paint()..filterQuality = FilterQuality.medium);
    final bounds = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    // Katman: üst üste binen çizgiler koyulaşmasın, alan tek renk görünsün.
    canvas.saveLayer(bounds, Paint()..color = const Color(0x73FF0000));
    final red = Paint()..color = const Color(0xFFFF0000);
    for (final s in strokes) {
      paintAiMaskStroke(canvas, s, red);
    }
    canvas
      ..restore()
      ..restore();
  }

  @override
  bool shouldRepaint(_MaskPainter old) => true;
}

/// Düzenleme sayfalarındaki isteğe bağlı adım: "Alanı işaretle" düğmesi ya
/// da işaretliyse durum + Değiştir / Kaldır. [loadSource] kaynağın baytları
/// (telefon dosyası, proje fotoğrafı ya da stüdyo görseli); gelmezse null.
class AiMaskField extends StatefulWidget {
  const AiMaskField({
    super.key,
    required this.value,
    required this.onChanged,
    required this.loadSource,
    this.enabled = true,
  });

  final AiMask? value;
  final ValueChanged<AiMask?> onChanged;
  final Future<Uint8List?> Function() loadSource;
  final bool enabled;

  @override
  State<AiMaskField> createState() => _AiMaskFieldState();
}

class _AiMaskFieldState extends State<AiMaskField> {
  bool _loading = false;

  Future<void> _open() async {
    setState(() => _loading = true);
    Uint8List? bytes;
    try {
      bytes = await widget.loadSource();
    } catch (_) {
      bytes = null;
    }
    if (!mounted) return;
    setState(() => _loading = false);
    if (bytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Fotoğraf açılamadı; tekrar deneyin.')));
      return;
    }
    final result = await showAiMaskEditor(context, sourceBytes: bytes, initial: widget.value?.strokes ?? const []);
    if (result != null) widget.onChanged(result.mask);
  }

  @override
  Widget build(BuildContext context) {
    final marked = widget.value != null;
    final enabled = widget.enabled && !_loading;
    if (!marked) {
      return SecondaryButton(
        key: const ValueKey('ai-mask-open'),
        icon: Icons.brush_outlined,
        label: 'Alanı işaretle (isteğe bağlı)',
        loading: _loading,
        onPressed: enabled ? _open : null,
      );
    }
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: AppSpacing.xs,
      children: [
        const Icon(Icons.brush, size: 18, color: AppColors.danger),
        const Text('Yalnızca işaretli alan düzenlenecek', key: ValueKey('ai-mask-marked'), style: AppTypography.body),
        TextButton(onPressed: enabled ? _open : null, child: const Text('Değiştir')),
        TextButton(
          key: const ValueKey('ai-mask-remove'),
          onPressed: enabled ? () => widget.onChanged(null) : null,
          child: const Text('Kaldır'),
        ),
      ],
    );
  }
}
