import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_status_colors.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/status_badge.dart';
import '../../../../core/widgets/viz/progress_bar.dart';
import '../../../auth/domain/user.dart';
import '../../domain/dashboard.dart';
import '../../domain/dashboard_registry.dart';
import 'dashboard_nav.dart';
import 'section_error_body.dart';

/// Kart oluşturucularının ortak girdisi.
class DashCardContext {
  const DashCardContext({
    required this.data,
    required this.user,
    required this.onboardingActive,
    required this.hideTaskList,
    required this.onQuickAction,
    required this.onRetry,
  });

  final Dashboard data;
  final User? user;
  final bool onboardingActive;

  /// Görevlerim üst sıraya taşındıysa Görevler kartı listesini gizler.
  final bool hideTaskList;

  /// Boş durum CTA'ları hızlı işlem akışını (proje seçici vb.) paylaşır.
  final void Function(QuickActionKey action) onQuickAction;
  final VoidCallback onRetry;

  bool failed(ModuleKey key) => data.sectionErrors.contains(key.wire);
}

/// Standart modül kartının tek anatomisi (spec §1.3/§6.4): başlık (ikon,
/// ad, dikkat çipi, ok), gövde, varsa altta en çok 2 dikkat satırı. Kartların kenarlığı ASLA renklenmez -- renk yalnızca
/// alt satırlardadır.
class ModuleCardFrame extends StatelessWidget {
  const ModuleCardFrame({
    super.key,
    required this.def,
    required this.groups,
    required this.child,
    this.failed = false,
    this.onRetry,
  });

  final ModuleDef def;
  final List<AttentionGroup> groups;
  final Widget child;
  final bool failed;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final route = def.route;
    final chip = failed ? null : attentionChip(groups);
    return AppCard(
      onTap: route == null ? null : () => openModuleRoute(context, route),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(color: AppColors.background, borderRadius: BorderRadius.circular(8)),
                child: Icon(def.icon, size: 20, color: AppColors.textMuted),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(def.title, style: AppTypography.cardTitle, maxLines: 2, overflow: TextOverflow.ellipsis),
              ),
              if (chip != null) ...[
                const SizedBox(width: AppSpacing.sm),
                // Dar ekran + büyük yazıda çip başlığı taşırmasın diye en çok
                // 120dp; sığmazsa küçülür.
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 120),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: StatusBadge(label: chip.$1, tone: chip.$2),
                  ),
                ),
              ],
              if (route != null) const Icon(Icons.chevron_right, color: AppColors.textMuted),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          if (failed) SectionErrorBody(onRetry: onRetry ?? () {}) else child,
          // Alt satır yalnızca bekleyen iş varsa: her kartın altında tekrar
          // eden "Bekleyen iş yok" sahada gürültüydü (2026-10); "her şey
          // yolunda" bilgisi Dikkat Gerektirenler kartında tek yerde.
          if (!failed && groups.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            const Divider(height: 1),
            AttentionFooter(groups: groups),
          ],
        ],
      ),
    );
  }
}

/// Kart altı: modülün en çok 2 dikkat grubu (Dikkat panelinin kısaltılmış
/// hali, spec D11) ya da sessiz satır.
class AttentionFooter extends StatelessWidget {
  const AttentionFooter({super.key, required this.groups, this.quiet = true});

  final List<AttentionGroup> groups;

  /// Grup yoksa "Bekleyen iş yok" satırı çizilsin mi.
  final bool quiet;

  @override
  Widget build(BuildContext context) {
    if (groups.isEmpty) {
      if (!quiet) return const SizedBox.shrink();
      return const Padding(
        padding: EdgeInsets.only(top: AppSpacing.md),
        child: Row(
          children: [
            Icon(Icons.check_circle_outline, size: 16, color: AppStatusColors.success),
            SizedBox(width: AppSpacing.sm),
            Expanded(child: Text(kCopyQuiet, style: AppTypography.helper)),
          ],
        ),
      );
    }
    return Column(children: [for (final g in groups.take(2)) _FooterLine(group: g)]);
  }
}

class _FooterLine extends StatelessWidget {
  const _FooterLine({required this.group});
  final AttentionGroup group;

  @override
  Widget build(BuildContext context) {
    final target = attentionGroupTarget(group);
    final color = severityColor(group.severity);
    return InkWell(
      onTap: target == null ? null : () => openModuleRoute(context, target),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Row(
          children: [
            Icon(severityIcon(group.severity), size: 18, color: color),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                attentionTitle(group),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.helper.copyWith(color: color, fontWeight: FontWeight.w600),
              ),
            ),
            if (target != null) const Icon(Icons.chevron_right, size: 16, color: AppColors.textMuted),
          ],
        ),
      ),
    );
  }
}

/// Birincil metrik: büyük değer + etiket (dar ekranda alt satıra kayar).
class PrimaryMetric extends StatelessWidget {
  const PrimaryMetric({super.key, required this.value, required this.label, this.color});

  final String value;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.end,
      children: [
        Text(value, style: AppTypography.metricPrimary.copyWith(color: color)),
        Padding(
          padding: const EdgeInsets.only(bottom: 1),
          child: Text(label, style: AppTypography.metadata),
        ),
      ],
    );
  }
}

class ModuleStat {
  const ModuleStat(this.value, this.label, {this.color});
  final String value;
  final String label;
  final Color? color;
}

/// Küçük istatistikler: satır başına 3 sütun; yazı ölçeği >= 1,3 ya da
/// kart 300dp'den darsa 2 sütun (spec §6.4).
class StatsGrid extends StatelessWidget {
  const StatsGrid({super.key, required this.stats});

  final List<ModuleStat> stats;

  @override
  Widget build(BuildContext context) {
    if (stats.isEmpty) return const SizedBox.shrink();
    final scale = MediaQuery.textScalerOf(context).scale(1);
    return LayoutBuilder(
      builder: (context, constraints) {
        // constraints kartın İÇ genişliğidir (16dp iç boşluk x2). İstatistik
        // sayısından fazla sütun açılmaz (2 istatistik yarı yarıya bölünür,
        // boş üçüncü sütun kalmaz).
        final maxColumns = scale >= 1.3 || constraints.maxWidth + 32 < 300 ? 2 : 3;
        final columns = stats.length < maxColumns ? stats.length : maxColumns;
        final rows = <List<ModuleStat>>[
          for (var i = 0; i < stats.length; i += columns) stats.sublist(i, (i + columns).clamp(0, stats.length)),
        ];
        return Column(
          children: [
            for (var r = 0; r < rows.length; r++) ...[
              if (r > 0) const SizedBox(height: AppSpacing.md),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var c = 0; c < columns; c++)
                    Expanded(
                      child: c < rows[r].length
                          ? Padding(
                              padding: const EdgeInsets.only(right: AppSpacing.sm),
                              child: _StatCell(stat: rows[r][c]),
                            )
                          : const SizedBox.shrink(),
                    ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

class _StatCell extends StatelessWidget {
  const _StatCell({required this.stat});
  final ModuleStat stat;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            stat.value,
            style: AppTypography.body.copyWith(
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: stat.color,
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(stat.label, style: AppTypography.helper, maxLines: 3, overflow: TextOverflow.ellipsis),
      ],
    );
  }
}

/// Kartın nötr bilgi notu (Dikkat'e girmeyen bilgi-yalnız olgular, D10).
class CardNote extends StatelessWidget {
  const CardNote(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Text(text, style: AppTypography.helper);
}

/// Boş durum metni + (izin varsa) tek CTA (spec §7.4).
class EmptyCardBody extends StatelessWidget {
  const EmptyCardBody({super.key, required this.text, this.ctaLabel, this.onCta});

  final String text;
  final String? ctaLabel;
  final VoidCallback? onCta;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          text,
          style: AppTypography.body.copyWith(color: AppColors.textMuted, fontWeight: FontWeight.w400),
        ),
        if (ctaLabel != null && onCta != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: TextButton(
              style: TextButton.styleFrom(padding: EdgeInsets.zero, alignment: Alignment.centerLeft),
              onPressed: onCta,
              child: Text(ctaLabel!),
            ),
          ),
      ],
    );
  }
}

/// Yüzdelik çubuk + altında kısa açıklama ("%59,2 tahsil edildi").
class CaptionedProgress extends StatelessWidget {
  const CaptionedProgress({super.key, required this.pct, required this.color, required this.caption, this.trailing});

  final double? pct;
  final Color color;
  final String caption;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppProgressBar(pct: pct, color: color, semanticsLabel: caption),
        const SizedBox(height: 6),
        Row(
          children: [
            Flexible(child: Text(caption, style: AppTypography.helper)),
            ?trailing,
          ],
        ),
      ],
    );
  }
}

/// Proje satırındaki etiketli ince çubuk ("Süre ███ %74,7").
class LabeledBar extends StatelessWidget {
  const LabeledBar({super.key, required this.label, required this.pct, required this.color});

  final String label;
  final double? pct;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(label, style: AppTypography.helper, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          Expanded(
            flex: 7,
            child: AppProgressBar(pct: pct, color: color, height: 5, semanticsLabel: label),
          ),
          Expanded(
            flex: 3,
            child: Text(
              pct == null ? '–' : Formatters.percent(pct!),
              textAlign: TextAlign.right,
              maxLines: 1,
              style: AppTypography.helper.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ),
        ],
      ),
    );
  }
}

/// Kart içindeki dokunulabilir liste satırı (proje/görev).
class CardListRow extends StatelessWidget {
  const CardListRow({super.key, required this.child, this.route});

  final Widget child;
  final String? route;

  @override
  Widget build(BuildContext context) {
    final target = route;
    return InkWell(
      onTap: target == null ? null : () => openRecordRoute(context, target),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: child,
      ),
    );
  }
}
