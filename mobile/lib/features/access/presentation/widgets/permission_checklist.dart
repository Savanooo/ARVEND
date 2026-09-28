import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../domain/access_models.dart';
import '../../domain/permission_rules.dart';
import '../../domain/tr_text.dart';

/// İzin kataloğunu kategori kategori kutucuk listesi olarak çizer -- hem
/// kişiye özel matris ([PermissionMatrix]) hem rol düzenleyicisi (Roller &
/// Yetkiler) kullanır. Kategoriler telefonda uzun bir listeye dönmesin diye
/// katlanabilir; başlıkta "(açık/toplam)" sayısı ve "Tümünü Seç/Kaldır"
/// her zaman görünür. Kişiye özel fark içeren kategoriler açık başlar.
class PermissionChecklist extends StatefulWidget {
  const PermissionChecklist({
    super.key,
    required this.catalog,
    required this.selected,
    required this.enabled,
    this.onToggle,
    this.onSetCategory,
    this.isLocked,
    this.lockedLabel = '(yalnızca Sahip/Yönetici)',
    this.baseline,
    this.expandAll = false,
  });

  final List<PermissionDef> catalog;
  final Set<String> selected;

  /// false: kutucuklar salt-okunur, "Tümünü Seç" gizli.
  final bool enabled;
  final ValueChanged<String>? onToggle;

  /// Kategorideki DÜZENLENEBİLİR kodlar + hedef durum (true = hepsini aç).
  final void Function(List<String> codes, bool on)? onSetCategory;

  /// true dönen kutucuk değiştirilemez ve [lockedLabel] ile işaretlenir.
  final bool Function(String code)? isLocked;
  final String lockedLabel;

  /// Verilirse (rolün varsayılanları) bundan farklı kutucuklar "+ kişiye
  /// özel" / "− kişiye özel" diye işaretlenir.
  final Set<String>? baseline;
  final bool expandAll;

  @override
  State<PermissionChecklist> createState() => _PermissionChecklistState();
}

class _PermissionChecklistState extends State<PermissionChecklist> {
  late final Set<String> _expanded;

  @override
  void initState() {
    super.initState();
    final groups = groupByCategory(widget.catalog);
    _expanded = {
      for (final (category, perms) in groups)
        if (widget.expandAll || perms.any(_isDiff)) category,
    };
  }

  bool _isDiff(PermissionDef p) {
    final base = widget.baseline;
    return base != null && widget.selected.contains(p.code) != base.contains(p.code);
  }

  @override
  Widget build(BuildContext context) {
    final groups = groupByCategory(widget.catalog);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Ayırıcı yalnızca gruplar ARASINDA: sonuncunun altına çizilen çizgi
        // kartın kendi kenarlığıyla çift çizgi oluşturuyordu.
        for (var i = 0; i < groups.length; i++) _buildCategory(groups[i].$1, groups[i].$2, last: i == groups.length - 1),
      ],
    );
  }

  Widget _buildCategory(String category, List<PermissionDef> perms, {required bool last}) {
    final codes = [for (final p in perms) p.code];
    final onCount = codes.where(widget.selected.contains).length;
    final locked = widget.isLocked ?? ((String _) => false);
    final editable = [
      for (final c in codes)
        if (!locked(c)) c,
    ];
    final allOn = editable.every(widget.selected.contains);
    final diffs = perms.where(_isDiff).length;
    final expanded = _expanded.contains(category);

    return Container(
      decoration: BoxDecoration(
        border: last ? null : const Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => expanded ? _expanded.remove(category) : _expanded.add(category)),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Row(
                children: [
                  Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 20, color: AppColors.textMuted),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: trUpper(category)),
                          TextSpan(
                            text: '  ($onCount/${codes.length})',
                            style: AppTypography.helper.copyWith(letterSpacing: 0),
                          ),
                          if (diffs > 0)
                            TextSpan(
                              text: '  · $diffs özel',
                              style: AppTypography.helper.copyWith(
                                color: AppColors.gold,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0,
                              ),
                            ),
                        ],
                      ),
                      style: AppTypography.overline,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (widget.enabled && editable.isNotEmpty && widget.onSetCategory != null)
                    TextButton(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 36),
                        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                      ),
                      onPressed: () {
                        setState(() => _expanded.add(category));
                        widget.onSetCategory!(editable, !allOn);
                      },
                      child: Text(
                        allOn ? 'Tümünü Kaldır' : 'Tümünü Seç',
                        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [for (final p in perms) _buildRow(p, locked(p.code))],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRow(PermissionDef p, bool locked) {
    final on = widget.selected.contains(p.code);
    final base = widget.baseline;
    final added = base != null && on && !base.contains(p.code);
    final removed = base != null && !on && base.contains(p.code);
    final canToggle = widget.enabled && !locked && widget.onToggle != null;

    final descStyle = removed
        ? AppTypography.body.copyWith(
            color: AppColors.textMuted,
            decoration: TextDecoration.lineThrough,
            decorationColor: AppColors.textMuted,
          )
        : locked
        ? AppTypography.body.copyWith(color: AppColors.textMuted)
        : AppTypography.body;
    const markerBase = TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, decoration: TextDecoration.none);

    return InkWell(
      onTap: canToggle ? () => widget.onToggle!(p.code) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 36,
              height: 32,
              child: Checkbox(
                value: on,
                onChanged: canToggle ? (_) => widget.onToggle!(p.code) : null,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 4),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: p.description, style: descStyle),
                      // İşaretler bölünmesin diye kelime aralarında bölünmez
                      // boşluk (\u00a0): "−" satır sonunda tek kalmasın.
                      if (added)
                        TextSpan(
                          text: '  +\u00a0kişiye\u00a0özel',
                          style: markerBase.copyWith(color: AppColors.success),
                        ),
                      if (removed)
                        TextSpan(
                          text: '  −\u00a0kişiye\u00a0özel',
                          style: markerBase.copyWith(color: AppColors.danger),
                        ),
                      if (locked)
                        TextSpan(
                          text: '  ${widget.lockedLabel.replaceAll(' ', '\u00a0')}',
                          style: markerBase.copyWith(color: AppColors.textMuted, fontWeight: FontWeight.w500),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
