import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_filter_bar.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/async_state_view.dart';
import '../data/dashboard_providers.dart';
import '../domain/dashboard.dart';
import '../domain/dashboard_registry.dart';
import '../domain/mobile_routes.dart';
import 'widgets/attention_row.dart';
import 'widgets/dashboard_nav.dart';
import 'widgets/stale_banner.dart';
import 'widgets/upcoming_row.dart';

enum _Filter { all, mine, watching, upcoming }

/// `/ana-sayfa/dikkat` -- "Dikkat Gerektirenler" tam listesi (spec §6.4).
/// Veri ana sayfayla AYNI anlık görüntüdür (dashboardProvider); yeni
/// istek atmaz. `?kod=` ile gelen grup açık başlar ve görünür kaydırılır.
/// Yenileme başarısız olursa ana sayfadaki gibi eski veri kalır (üstte
/// "Güncellenemedi" bandı); tam sayfa hata yalnızca hiç veri yokken.
class AttentionScreen extends ConsumerStatefulWidget {
  const AttentionScreen({super.key, this.initialCode});

  final String? initialCode;

  @override
  ConsumerState<AttentionScreen> createState() => _AttentionScreenState();
}

class _AttentionScreenState extends ConsumerState<AttentionScreen> {
  _Filter _filter = _Filter.all;
  late final Set<String> _expanded = {?widget.initialCode};
  final _initialKey = GlobalKey();
  bool _scrolled = false;

  void _scrollToInitial() {
    if (_scrolled || widget.initialCode == null) return;
    _scrolled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _initialKey.currentContext;
      if (ctx != null) Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 250));
    });
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(dashboardProvider);
    final data = async.valueOrNull;
    final Widget body;
    if (data != null) {
      _scrollToInitial();
      body = _buildList(context, data, stale: async.hasError);
    } else if (async.hasError && !async.isLoading) {
      // Hiç veri yok: hata, yine aşağı çekilerek yenilenebilir.
      body = RefreshIndicator(
        onRefresh: () => refreshDashboard(ref),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            const SizedBox(height: AppSpacing.xxl),
            ErrorState(error: async.error!, onRetry: () => refreshDashboard(ref)),
          ],
        ),
      );
    } else {
      body = const LoadingState();
    }
    return AppPageScaffold(title: const Text('Dikkat Gerektirenler'), body: body);
  }

  Widget _buildList(BuildContext context, Dashboard data, {required bool stale}) {
    final agenda = data.agenda;
    final mine = [
      for (final g in agenda.groups)
        if (g.lane == 'mine') g,
    ];
    final watching = [
      for (final g in agenda.groups)
        if (g.lane == 'watching') g,
    ];
    final upcoming = agenda.upcoming;
    final total = attentionTotal(agenda);

    AppFilterChipData chip(_Filter f, String label) =>
        AppFilterChipData(label: label, selected: _filter == f, onTap: () => setState(() => _filter = f));

    Widget lane(String label) => Padding(
      padding: const EdgeInsets.only(top: AppSpacing.lg, bottom: AppSpacing.sm),
      child: Text(label, style: AppTypography.overline),
    );

    final showMine = _filter == _Filter.all || _filter == _Filter.mine;
    final showWatching = _filter == _Filter.all || _filter == _Filter.watching;
    final showUpcoming = _filter == _Filter.all || _filter == _Filter.upcoming;

    return RefreshIndicator(
      onRefresh: () => refreshDashboard(ref),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          if (stale) ...[
            StaleBanner(generatedAt: data.generatedAt, onRetry: () => refreshDashboard(ref)),
            const SizedBox(height: AppSpacing.md),
          ],
          AppFilterBar(
            chips: [
              chip(_Filter.all, 'Tümü ($total)'),
              chip(_Filter.mine, 'Senin sıran (${agenda.mineCount})'),
              chip(_Filter.watching, 'Takipte (${agenda.watchingCount})'),
              chip(_Filter.upcoming, 'Yaklaşan (${upcoming.length})'),
            ],
          ),
          if (data.sectionErrors.isNotEmpty)
            const Padding(
              padding: EdgeInsets.only(top: AppSpacing.md),
              child: Text(kCopyDikkatPartial, style: AppTypography.helper),
            ),
          if (total == 0)
            const Padding(
              padding: EdgeInsets.only(top: AppSpacing.xl),
              child: EmptyStateView(message: kCopyDikkatEmpty, icon: Icons.check_circle_outline),
            ),
          if (showMine && mine.isNotEmpty) ...[lane(kLaneMineLabel), for (final g in mine) _groupCard(g)],
          if (showWatching && watching.isNotEmpty) ...[
            lane(kLaneWatchingLabel),
            if (_filter == _Filter.watching)
              const Padding(
                padding: EdgeInsets.only(bottom: AppSpacing.sm),
                child: Text('Bu işler başka birinin onayını ya da müşteriyi bekliyor.', style: AppTypography.helper),
              ),
            for (final g in watching) _groupCard(g),
          ],
          if (showUpcoming && upcoming.isNotEmpty) ...[
            lane(kLaneUpcomingLabel),
            AppCard(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
              child: Column(
                children: [
                  for (var i = 0; i < upcoming.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    UpcomingRow(item: upcoming[i], today: data.today),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _groupCard(AttentionGroup g) {
    final expanded = _expanded.contains(g.code);
    final more = g.count - g.items.length;
    final moduleRoute = moduleRouteFor(g.module);
    return Padding(
      key: g.code == widget.initialCode ? _initialKey : null,
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: AppCard(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AttentionRow(
              group: g,
              onTap: () => setState(() => expanded ? _expanded.remove(g.code) : _expanded.add(g.code)),
              trailing: Align(
                child: Icon(expanded ? Icons.expand_less : Icons.expand_more, color: AppColors.textMuted),
              ),
            ),
            if (expanded) ...[
              const Divider(height: 1),
              for (final r in g.items) _RecordRow(record: r, code: g.code),
              if (more > 0)
                Padding(
                  padding: const EdgeInsets.only(left: AppSpacing.lg, bottom: AppSpacing.xs),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: moduleRoute == null
                        ? Padding(
                            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                            child: Text('+$more daha', style: AppTypography.helper),
                          )
                        : TextButton(
                            onPressed: () => openModuleRoute(context, moduleRoute),
                            child: Text('+$more daha'),
                          ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RecordRow extends StatelessWidget {
  const _RecordRow({required this.record, required this.code});

  final AttentionRecord record;
  final String code;

  @override
  Widget build(BuildContext context) {
    final route = mobileRouteFor(record.ref);
    final amount = record.amount;
    return InkWell(
      onTap: route == null ? null : () => context.push(route),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.xl + AppSpacing.lg,
            AppSpacing.sm,
            AppSpacing.md,
            AppSpacing.sm,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(attentionRecordLine(record, code), style: AppTypography.body),
                    if (amount != null)
                      Text(
                        Formatters.money(amount.amount, currency: amount.currency),
                        style: AppTypography.helper.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                      ),
                  ],
                ),
              ),
              if (route != null) const Icon(Icons.chevron_right, color: AppColors.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}
