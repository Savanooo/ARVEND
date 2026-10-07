import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/auth/auth_controller.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/widgets/access_notices.dart';
import '../../../../core/widgets/app_buttons.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_data_row.dart';
import '../../../../core/widgets/app_section_header.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../../../../core/widgets/money_text.dart';
import '../../../../core/widgets/skeleton_box.dart';
import '../../../../core/widgets/status_badge.dart';
import '../../../../core/widgets/viz/progress_bar.dart';
import '../../domain/project.dart' show Project;
import '../budget_paths.dart';
import '../data/budget_providers.dart';
import '../domain/budget.dart';
import 'sheets/adjustment_sheet.dart';
import 'sheets/forecast_sheet.dart';
import 'widgets/budget_ui.dart';
import 'widgets/cost_line_widgets.dart';

/// Proje detayı > Finans > "Maliyet Kontrolü" (`?grup=finans&alt=maliyet`)
/// -- web "maliyet" sekmesinin mobil merkezi. Eski salt-okunur görünümün
/// (özet + kalem listesi) üstüne kurulur: özet KPI'lar + bütçe aşımı
/// vurgusu, bütçe/WBS/revizyon/taahhüt/tahmin/gerçekleşen yönetim
/// ekranlarına geçiş kartları ve maliyet kırılımı (satıra dokununca tam
/// döküm + ETC/revizyon aksiyonları).
///
/// İzinler (router.go): özet/kırılım/taahhüt/tahmin `projects.cost_control.
/// read`, bütçe/WBS/revizyon `projects.budget.read`; ikisi de yoksa yetkisiz
/// görünümü (sekme zaten gizlenmeli). Para yalnızca ilgili okuma iznine
/// sahip kişiye gösterilir. Tamamlanan/iptal projede yazma aksiyonu YOK.
class BudgetCostControlTab extends ConsumerStatefulWidget {
  const BudgetCostControlTab({super.key, required this.projectId, required this.project, this.topPadding = 0});

  final String projectId;
  final Project project;

  /// Proje detayında 0 (üstte zaten grup segmenti ve dolgusu var); tam
  /// ekranda (bkz. BudgetCostControlScreen) normal sayfa dolgusu.
  final double topPadding;

  @override
  ConsumerState<BudgetCostControlTab> createState() => _BudgetCostControlTabState();
}

class _BudgetCostControlTabState extends ConsumerState<BudgetCostControlTab> {
  bool _overOnly = false;
  bool _creating = false;

  String get _pid => widget.projectId;

  Future<void> _refresh() async {
    invalidateBudgetModule(ref.invalidate, _pid);
    try {
      await ref.read(budgetCostControlProvider(_pid).future);
    } catch (_) {
      // Hata bölüm içinde gösterilir.
    }
  }

  /// Bütçesiz projede "Bütçe Oluştur": oluşturur ve kalem girişi için Bütçe
  /// ekranını açar. 409 (bu arada başka biri oluşturdu) -> tazele + mesaj.
  Future<void> _createBudget() async {
    setState(() => _creating = true);
    // Kapsayıcı ilk await'ten ÖNCE: istek sürerken sekme kapansa da bütçe
    // modülü tazelenir (WidgetRef dispose sonrası StateError atardı).
    final invalidate = ProviderScope.containerOf(context, listen: false).invalidate;
    try {
      await ref.read(budgetRepositoryProvider).createBudget(_pid);
      invalidateBudgetModule(invalidate, _pid);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Bütçe oluşturuldu.')));
      unawaited(context.push(budgetPath(_pid)));
    } catch (e) {
      if (isBudgetConflict(e)) invalidateBudgetModule(invalidate, _pid);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(budgetErrorText(e))));
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _openLine(CostControlLine line, String currency, {required bool locked}) async {
    final user = ref.read(authControllerProvider).valueOrNull;
    final lineId = line.budgetLineId;
    final canForecast = !locked && lineId != null && user.can(kCostControlManagePermission);
    final budget = user.can(kBudgetReadPermission) ? ref.read(projectBudgetProvider(_pid)).valueOrNull : null;
    final canAdjust = !locked && lineId != null && (budget?.isBaselined ?? false) && user.can(kBudgetManagePermission);

    CostForecast? override;
    if (canForecast) {
      try {
        // Sekme, tahmin girebilen kişi için listeyi zaten izler; henüz
        // gelmediyse depodan doğrudan (autoDispose sağlayıcıyı dinleyicisiz
        // okumak yerine) istenir.
        final all =
            ref.read(budgetForecastsProvider(_pid)).valueOrNull ??
            await ref.read(budgetRepositoryProvider).forecasts(_pid);
        override = all.where((f) => f.budgetLineId == lineId).firstOrNull;
      } catch (_) {
        override = null;
      }
    }
    if (!mounted) return;
    final action = await showCostLineSheet(
      context,
      line: line,
      currency: currency,
      canForecast: canForecast,
      canAdjust: canAdjust,
      hasForecastOverride: override != null,
    );
    if (!mounted || action == null || lineId == null) return;
    final label = line.description.isEmpty ? costLineTitle(line) : line.description;
    final bool? saved;
    switch (action) {
      case CostLineAction.forecast:
        saved = await showForecastSheet(
          context,
          projectId: _pid,
          budgetLineId: lineId,
          lineLabel: label,
          currency: currency,
          existing: override,
          defaultEtc: line.etc,
        );
      case CostLineAction.adjust:
        saved = await showAdjustmentSheet(
          context,
          projectId: _pid,
          currency: currency,
          initialLineId: lineId,
          initialLineLabel: label,
        );
    }
    if (saved == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            action == CostLineAction.forecast
                ? 'ETC tahmini kaydedildi.'
                : 'Revizyon oluşturuldu; onaylandığında revize bütçeye yansır.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final user = auth.valueOrNull;
    if (isAuthPending(auth)) return const LoadingState();
    final canCostControl = user.can(kCostControlReadPermission);
    final canBudget = user.can(kBudgetReadPermission);
    final canFinance = user.can(kFinanceReadPermission);
    if (!canCostControl && !canBudget) {
      return const BudgetNoAccessView(message: kBudgetModuleNoAccessText);
    }

    final locked = isProjectLocked(widget.project.status);
    final ccAsync = canCostControl ? ref.watch(budgetCostControlProvider(_pid)) : null;
    final budgetAsync = canBudget ? ref.watch(projectBudgetProvider(_pid)) : null;
    final adjustments = canBudget ? ref.watch(budgetAdjustmentsProvider(_pid)).valueOrNull : null;
    final commitments = canCostControl ? ref.watch(budgetCommitmentsProvider(_pid)).valueOrNull : null;
    // Satır dökümündeki "Manuel ETC Gir / ETC Düzenle" ayrımı için (yalnızca
    // tahmin girebilen kişide istenir).
    if (canCostControl && user.can(kCostControlManagePermission) && !locked) {
      ref.watch(budgetForecastsProvider(_pid));
    }
    final cc = ccAsync?.valueOrNull;
    final currency = cc?.summary.currency ?? budgetAsync?.valueOrNull?.currency ?? widget.project.currency;

    final children = <Widget>[
      if (locked) ...[const ReadOnlyNotice(kProjectLockedText), const SizedBox(height: AppSpacing.md)],
      if (ccAsync != null) ...[
        const AppSectionHeader(title: 'Maliyet Özeti'),
        const SizedBox(height: AppSpacing.sm),
        ccAsync.when(
          loading: () => const SkeletonBox(height: 260, radius: AppRadius.card),
          error: (e, _) => BudgetSectionError(error: e, onRetry: _refresh, forbiddenText: kCostControlNoAccessText),
          // Bütçesiz projede sıfırlarla dolu bir özet (ve %100 "marj")
          // yanıltıcıdır: yerine bütçeye yönlendiren kısa kart.
          data: (data) => data.summary.hasBudget
              ? _CostSummaryCard(
                  summary: data.summary,
                  overCount: overBudgetLines(data.lines).length,
                  showRevenue: canFinance,
                )
              : _NoBudgetSummaryCard(
                  summary: data.summary,
                  showRevenue: canFinance,
                  onOpenBudget: canBudget ? () => context.push(budgetPath(_pid)) : null,
                  onCreate: canBudget && user.can(kBudgetManagePermission) && !locked ? _createBudget : null,
                  creating: _creating,
                ),
        ),
      ] else
        const ReadOnlyNotice(
          'Maliyet özetini görmek için rolünde "Maliyet kontrolü (WBS/taahhüt/tahmin) görüntüleme" izni olmalı.',
        ),
      const SizedBox(height: AppSpacing.xl),
      const AppSectionHeader(title: 'Bütçe ve Maliyet Yönetimi'),
      const SizedBox(height: AppSpacing.sm),
      if (canBudget) ...[
        _budgetNavCard(context, budgetAsync!),
        BudgetNavCard(
          icon: Icons.account_tree_outlined,
          title: 'WBS (İş Kırılım Yapısı)',
          subtitle: 'Fiziksel/işlevsel iş grupları',
          onTap: () => context.push(wbsPath(_pid)),
        ),
        _adjustmentsNavCard(context, adjustments),
      ],
      if (canCostControl) ...[
        BudgetNavCard(
          icon: Icons.handshake_outlined,
          title: 'Taahhütler',
          subtitle: commitments == null
              ? 'Satın alma, taşeron ve manuel taahhütler'
              : '${commitments.where((c) => c.status == 'active').length} aktif taahhüt',
          onTap: () => context.push(commitmentsPath(_pid)),
        ),
        BudgetNavCard(
          icon: Icons.trending_up,
          title: 'Tahmin (ETC)',
          subtitle: 'Kalem bazında kalan maliyet tahmini',
          onTap: () => context.push(forecastPath(_pid)),
        ),
        if (canFinance)
          BudgetNavCard(
            icon: Icons.receipt_long_outlined,
            title: 'Gerçekleşen',
            subtitle: 'Maliyet koduna göre masraflar',
            onTap: () => context.push(actualCostPath(_pid)),
          ),
      ],
      if (cc != null) ..._breakdown(context, cc, currency, locked: locked),
    ];

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(AppSpacing.lg, widget.topPadding, AppSpacing.lg, AppSpacing.xxl),
        children: children,
      ),
    );
  }

  Widget _budgetNavCard(BuildContext context, AsyncValue<ProjectBudget?> budgetAsync) {
    final budget = budgetAsync.valueOrNull;
    final String subtitle;
    Widget? badge;
    if (budgetAsync.isLoading && budget == null) {
      subtitle = 'Yükleniyor…';
    } else if (budgetAsync.hasError) {
      subtitle = isBudgetForbidden(budgetAsync.error) ? 'Görüntüleme yetkin yok' : 'Bütçe yüklenemedi';
    } else if (budget == null) {
      subtitle = 'Henüz oluşturulmadı';
    } else {
      subtitle = budget.isBaselined
          ? (budget.baselinedAt == null ? 'Kalemler sabit' : Formatters.date(budget.baselinedAt))
          : 'Kalemler düzenlenebilir';
      badge = StatusRegistry.build(budget.status, BudgetStatusRegistry.budget);
    }
    return BudgetNavCard(
      icon: Icons.account_balance_wallet_outlined,
      title: 'Bütçe',
      subtitle: subtitle,
      badge: badge,
      onTap: () => context.push(budgetPath(_pid)),
    );
  }

  Widget _adjustmentsNavCard(BuildContext context, List<BudgetAdjustment>? adjustments) {
    final pending = adjustments?.where((a) => a.isPending).length ?? 0;
    return BudgetNavCard(
      icon: Icons.published_with_changes_outlined,
      title: 'Bütçe Revizyonları',
      subtitle: pending > 0 ? 'Karar bekliyor' : 'Baseline sonrası değişiklikler',
      badge: pending > 0 ? StatusBadge(label: '$pending bekliyor', tone: StatusTone.warning) : null,
      onTap: () => context.push(budgetAdjustmentsPath(_pid)),
    );
  }

  List<Widget> _breakdown(BuildContext context, CostControlData cc, String currency, {required bool locked}) {
    final over = overBudgetLines(cc.lines);
    final visible = _overOnly ? over : cc.lines;
    return [
      const SizedBox(height: AppSpacing.xl),
      AppSectionHeader(
        title: 'Maliyet Kırılımı',
        trailing: over.isEmpty
            ? null
            : FilterChip(
                key: const ValueKey('cost-lines-over-only'),
                label: Text('Aşanlar (${over.length})'),
                selected: _overOnly,
                onSelected: (v) => setState(() => _overOnly = v),
                visualDensity: VisualDensity.compact,
              ),
      ),
      const SizedBox(height: AppSpacing.sm),
      if (cc.lines.isEmpty)
        const EmptyStateView(
          message: 'Henüz maliyet hareketi yok. Bütçe kalemi, taahhüt veya gider eklendiğinde burada görünür.',
          icon: Icons.stacked_bar_chart,
        )
      else
        for (final l in visible)
          CostLineCard(
            line: l,
            currency: currency,
            onTap: () => _openLine(l, currency, locked: locked),
          ),
    ];
  }
}

/// Özet kartı: öne çıkan EAC + revize bütçeye göre çubuk, ardından web
/// özet kutucuklarının tamamı. Rakamların HEPSİ backend'den gelir.
class _CostSummaryCard extends StatelessWidget {
  const _CostSummaryCard({required this.summary, required this.overCount, required this.showRevenue});

  final CostControlSummary summary;
  final int overCount;

  /// Sözleşme bedeli (gelir), tahmini kâr ve marj yalnızca
  /// `projects.finance.read` ile. Maliyet rakamları (bütçe, EAC, taahhüt,
  /// gerçekleşen, varyans) `cost_control.read`/`budget.read` ile görünür:
  /// Proje Yöneticisi rolü bunları görmek için tasarlandı (migration 0035),
  /// ama gelir/kâr finans iznidir (HANDOFF §7.2). Backend `/cost-control`
  /// bu alanları cost_control.read'e de döndürür -- ekran göstermez.
  final bool showRevenue;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final c = s.currency;
    final over = isOverBudget(s.variance);
    final profitColor = s.forecastProfit < 0 ? AppColors.danger : AppColors.success;

    String? banner;
    if (over) {
      banner =
          'Tahmini nihai maliyet revize bütçeyi ${Formatters.money(s.variance.abs(), currency: c)} aşıyor.'
          '${overCount > 0 ? ' $overCount kalem bütçenin üzerinde.' : ''}';
    } else if (overCount > 0) {
      banner = '$overCount kalem bütçenin üzerinde; proje toplamı bütçe içinde.';
    }

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(child: Text('Tahmini Nihai Maliyet (EAC)', style: AppTypography.metadata)),
              if (s.hasBudget)
                over
                    ? const StatusBadge(label: 'Bütçe aşımı', tone: StatusTone.danger)
                    : const StatusBadge(label: 'Bütçe içinde', tone: StatusTone.success),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          MoneyText(s.eac, currency: c, style: AppTypography.metricHero),
          const SizedBox(height: 2),
          Text('Revize bütçe ${Formatters.money(s.revisedBudget, currency: c)}', style: AppTypography.helper),
          const SizedBox(height: AppSpacing.sm),
          AppProgressBar(
            pct: eacUsagePct(s.eac, s.revisedBudget),
            color: varianceColor(s.variance),
            semanticsLabel: 'Tahmini nihai maliyetin revize bütçeye oranı',
          ),
          if (banner != null) ...[const SizedBox(height: AppSpacing.md), OverBudgetBanner(text: banner)],
          const SizedBox(height: AppSpacing.sm),
          const Divider(),
          if (showRevenue)
            AppDataRow(
              label: 'Sözleşme Bedeli',
              value: Formatters.money(s.contractValue, currency: c),
            ),
          AppDataRow(
            label: 'Orijinal Bütçe',
            value: Formatters.money(s.originalBudget, currency: c),
          ),
          AppDataRow(
            label: 'Onaylı Revizyonlar',
            value: Formatters.signedMoney(s.approvedAdjustments, currency: c),
          ),
          AppDataRow(
            label: 'Revize Bütçe',
            value: Formatters.money(s.revisedBudget, currency: c),
            emphasize: true,
          ),
          const Divider(height: AppSpacing.lg),
          AppDataRow(
            label: 'Taahhüt',
            value: Formatters.money(s.committedCost, currency: c),
          ),
          AppDataRow(
            label: 'Gerçekleşen',
            value: Formatters.money(s.actualCost, currency: c),
          ),
          AppDataRow(
            label: 'Kalan (ETC)',
            value: Formatters.money(s.etc, currency: c),
          ),
          AppDataRow(
            label: 'Varyans',
            value: Formatters.signedMoney(s.variance, currency: c),
            valueColor: varianceColor(s.variance),
          ),
          if (showRevenue) ...[
            const Divider(height: AppSpacing.lg),
            AppDataRow(
              label: 'Tahmini Kâr',
              value: Formatters.money(s.forecastProfit, currency: c),
              emphasize: true,
              valueColor: profitColor,
            ),
            AppDataRow(
              label: 'Tahmini Marj',
              value: formatBudgetPercent(s.forecastMarginPercent),
              valueColor: profitColor,
            ),
          ],
        ],
      ),
    );
  }
}

/// Bütçesi olmayan projede özet: web'in açıklaması + (varsa) bütçe dışı
/// taahhüt/gerçekleşen + bütçeye geçiş. Revize bütçe/EAC/marj gösterilmez.
/// AppDataRow'un varsayılan değer stiliyle aynı.
final _noBudgetValueStyle = AppTypography.body.copyWith(fontWeight: FontWeight.w600);

class _NoBudgetSummaryCard extends StatelessWidget {
  const _NoBudgetSummaryCard({
    required this.summary,
    required this.showRevenue,
    required this.onOpenBudget,
    required this.onCreate,
    required this.creating,
  });

  final CostControlSummary summary;

  /// Sözleşme bedeli yalnızca `projects.finance.read` ile (bkz.
  /// [_CostSummaryCard.showRevenue]).
  final bool showRevenue;
  final VoidCallback? onOpenBudget;

  /// Yalnızca `projects.budget.manage` + açık projede.
  final VoidCallback? onCreate;
  final bool creating;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final c = s.currency;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(color: AppColors.gold.withValues(alpha: 0.12), shape: BoxShape.circle),
                child: const Icon(Icons.account_balance_wallet_outlined, color: AppColors.gold, size: 18),
              ),
              const SizedBox(width: AppSpacing.md),
              const Expanded(child: Text('Henüz bütçe yok', style: AppTypography.sectionTitle)),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          // İlk cümle kişinin yapabileceğine göre: oluşturabilen düğmeye,
          // yalnızca görüntüleyebilen bütçeyi kimin açabileceğine yönlenir.
          Text(
            '${onCreate != null ? 'Bu proje için henüz bir bütçe oluşturulmadı; aşağıdaki "Bütçe Oluştur" ile '
                'başlayabilirsin.' : 'Bu proje için henüz bir bütçe oluşturulmadı. Bütçeyi '
                '"$kBudgetManagePermissionLabel" izni olan biri oluşturabilir.'} Aşağıdaki kırılım yalnızca doğrudan '
            'maliyet koduna bağlanmış (bütçe dışı) taahhüt/gider varsa satır gösterir.',
            style: AppTypography.metadata,
          ),
          const SizedBox(height: AppSpacing.sm),
          const Divider(),
          if (showRevenue)
            AppDataRow(
              label: 'Sözleşme Bedeli',
              value: Formatters.money(s.contractValue, currency: c),
            ),
          // "Bütçe dışı" niteleyicisi etiketin başında ve etiket kalan tüm
          // genişliği alır (değer sütunu kısa): eski "Taahhüt (bütçe dışı)"
          // 2/5 sütuna sığmayıp 360 dp'de tam da niteleyiciden kesiliyordu.
          AppDataRow(
            label: 'Bütçe dışı taahhüt',
            trailing: Text(Formatters.money(s.committedCost, currency: c), style: _noBudgetValueStyle),
          ),
          AppDataRow(
            label: 'Bütçe dışı gerçekleşen',
            trailing: Text(Formatters.money(s.actualCost, currency: c), style: _noBudgetValueStyle),
          ),
          if (onCreate != null) ...[
            const SizedBox(height: AppSpacing.md),
            PrimaryButton(label: 'Bütçe Oluştur', icon: Icons.add, loading: creating, onPressed: onCreate),
          ] else if (onOpenBudget != null) ...[
            const SizedBox(height: AppSpacing.md),
            SecondaryButton(label: 'Bütçeye Git', onPressed: onOpenBudget),
          ],
        ],
      ),
    );
  }
}
