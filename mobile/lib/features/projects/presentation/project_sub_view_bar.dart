import 'package:flutter/material.dart';

import '../../../core/theme/app_spacing.dart';

/// Alt görünüm seçici -- yatay kaydırılabilir tek satır çip. Finans (6) ve
/// Operasyon (6) alt görünümü 360 dp'de `SegmentedButton`'a sığmıyordu
/// (etiketler 2-3 satıra kırılıyordu); çipler tek satırda kalır, seçili çip
/// görünür alana kaydırılır (derin bağlantıyla sondaki bir görünüm açılınca).
/// Modül golden testlerinin ev sahipleri de aynı şeridi kullanır.
class ProjectSubViewBar extends StatefulWidget {
  const ProjectSubViewBar({super.key, required this.items, required this.selected, required this.onSelected});

  /// Sırasıyla çipler: `?alt=` anahtarı + etiket.
  final List<({String alt, String label})> items;
  final String selected;
  final ValueChanged<String> onSelected;

  @override
  State<ProjectSubViewBar> createState() => _ProjectSubViewBarState();
}

class _ProjectSubViewBarState extends State<ProjectSubViewBar> {
  final _controller = ScrollController();
  final _chipKeys = <String, GlobalKey>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(widget.selected, animate: false));
  }

  @override
  void didUpdateWidget(covariant ProjectSubViewBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(widget.selected, animate: true));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Yalnızca BU satırın kaydırma konumu değişir -- `Scrollable.ensureVisible`
  /// üstteki TabBarView'u (PageView) da kaydırıp sayfa hizasını bozardı.
  ///
  /// Şerit henüz yerleşmemişse (ör. derin bağlantıyla alt bir ekran açılınca
  /// proje detayı üstteki rotanın ALTINDA, ekran dışında kurulur ve hiç
  /// ölçülmez) ölçülmemiş kutuya dokunulmaz -- debug'da assert, release'de
  /// null hatası olurdu. Bir sonraki karede yeniden denenir; rota öne
  /// geldiğinde (üstteki kapanınca) seçili çip görünür alana kaydırılır.
  void _reveal(String alt, {required bool animate}) {
    if (!mounted || !_controller.hasClients) return;
    final box = _chipKeys[alt]?.currentContext?.findRenderObject();
    if (box is! RenderBox) return;
    if (!box.hasSize || !_controller.position.hasContentDimensions) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (widget.selected == alt) _reveal(alt, animate: animate);
      });
      return;
    }
    _controller.position.ensureVisible(
      box,
      alignment: 0.5,
      duration: animate ? const Duration(milliseconds: 200) : Duration.zero,
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller: _controller,
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.sm),
      child: Row(
        children: [
          for (var i = 0; i < widget.items.length; i++) ...[
            if (i > 0) const SizedBox(width: AppSpacing.sm),
            KeyedSubtree(
              key: _chipKeys.putIfAbsent(widget.items[i].alt, GlobalKey.new),
              child: ChoiceChip(
                key: ValueKey('proje-alt-${widget.items[i].alt}'),
                label: Text(widget.items[i].label),
                selected: widget.items[i].alt == widget.selected,
                showCheckmark: false,
                onSelected: (_) => widget.onSelected(widget.items[i].alt),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
