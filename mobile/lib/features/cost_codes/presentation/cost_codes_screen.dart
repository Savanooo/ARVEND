import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_filter_bar.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_badge.dart';
import '../cost_codes_paths.dart';
import '../data/cost_codes_providers.dart';
import '../domain/cost_code.dart';
import 'cost_code_form_sheet.dart';
import 'widgets/cost_code_ui.dart';

/// Maliyet Kodları -- web `/admin/maliyet-kodlari` (CostCodesManager.tsx)
/// karşılığı; mobilde kategoriye göre gruplu. Okuma
/// `organization.cost_codes.read`, yazma `.manage` ister (KATI `canAccess`).
/// Arama/süzme/gruplama istemcidedir (backend tüm kataloğu tek seferde
/// döner).
class CostCodesScreen extends ConsumerStatefulWidget {
  const CostCodesScreen({super.key});

  @override
  ConsumerState<CostCodesScreen> createState() => _CostCodesScreenState();
}

class _CostCodesScreenState extends ConsumerState<CostCodesScreen> {
  final _searchController = TextEditingController();
  String _query = '';
  CostCodeStatusFilter _status = CostCodeStatusFilter.active;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    ref.invalidate(costCodesListProvider);
    try {
      await ref.read(costCodesListProvider.future);
    } catch (_) {
      // Hata, liste gövdesinde gösterilir.
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final user = auth.valueOrNull;
    const title = Text('Maliyet Kodları');

    if (user == null && auth.isLoading) {
      return const AppPageScaffold(title: title, body: LoadingState());
    }
    // İzin yoksa API HİÇ çağrılmaz (derin bağlantıyla gelinse bile).
    if (!user.canAccess(kCostCodesReadPermission)) {
      return const AppPageScaffold(title: title, body: CostCodeNoAccessView());
    }
    final canManage = user.canAccess(kCostCodesManagePermission);
    final listAsync = ref.watch(costCodesListProvider);
    final all = listAsync.valueOrNull;

    return AppPageScaffold(
      title: title,
      floatingActionButton: canManage
          ? FloatingActionButton.extended(
              onPressed: () => _openCreate(all ?? const []),
              icon: const Icon(Icons.add),
              label: const Text('Yeni Maliyet Kodu'),
            )
          : null,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 0),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Kod, ad veya kategori ara',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Aramayı temizle',
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                      ),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xs),
            child: AppFilterBar(
              chips: [
                _chip('Aktif', CostCodeStatusFilter.active, all?.where((c) => c.isActive).length),
                _chip('Arşiv', CostCodeStatusFilter.archived, all?.where((c) => !c.isActive).length),
                _chip('Tümü', CostCodeStatusFilter.all, all?.length),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: listAsync.when(
                loading: () => const CostCodeListSkeleton(),
                error: (e, _) => isCostCodeForbidden(e)
                    ? const CostCodeNoAccessView()
                    : ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [ErrorState(error: e, onRetry: _refresh)],
                      ),
                data: (codes) => _buildList(codes, canManage),
              ),
            ),
          ),
        ],
      ),
    );
  }

  AppFilterChipData _chip(String label, CostCodeStatusFilter value, int? count) => AppFilterChipData(
        label: count == null ? label : '$label ($count)',
        selected: _status == value,
        onTap: () => setState(() => _status = value),
      );

  Widget _buildList(List<OrganizationCostCode> all, bool canManage) {
    final filtered = filterCostCodes(all, query: _query, status: _status);
    final groups = groupCostCodesByCategory(filtered);
    final items = <Widget>[
      if (!canManage) ...[const CostCodeReadOnlyNotice(), const SizedBox(height: AppSpacing.md)],
      if (filtered.isNotEmpty)
        Text(
          _query.trim().isEmpty
              ? '${filtered.length} kod · ${groups.length} kategori'
              : '${filtered.length} sonuç',
          style: AppTypography.metadata,
        ),
      for (final g in groups) ...[
        const SizedBox(height: AppSpacing.md),
        _GroupHeader(group: g),
        const SizedBox(height: AppSpacing.sm),
        for (final c in g.codes)
          CostCodeListCard(costCode: c, onTap: () => context.push(costCodeDetailPath(c.id))),
      ],
    ];

    if (filtered.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          ...items,
          const SizedBox(height: AppSpacing.xl),
          EmptyStateView(
            icon: Icons.sell_outlined,
            message: all.isEmpty
                ? 'Henüz hiç maliyet kodu oluşturulmamış. Bütçe kalemleri ve taahhütler bu kodlarla sınıflandırılır.'
                : 'Arama kriterlerine uyan kod yok.',
          ),
        ],
      );
    }

    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 96),
      itemCount: items.length,
      itemBuilder: (context, i) => items[i],
    );
  }

  Future<void> _openCreate(List<OrganizationCostCode> all) async {
    final saved = await showCostCodeFormSheet(context, categories: distinctCategories(all));
    if (saved != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('"${saved.code}" eklendi.')));
    }
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.group});

  final CostCodeGroup group;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            group.category,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.sectionTitle.copyWith(
              color: group.isUncategorized ? AppColors.textMuted : AppColors.textPrimary,
            ),
          ),
        ),
        Text('${group.codes.length}', style: AppTypography.metadata),
      ],
    );
  }
}

/// Liste satırı: kod (+ arşivse rozet), ad (2 satıra kadar), açıklama.
/// Arşivlenmiş satırlar web'deki gibi soluk.
class CostCodeListCard extends StatelessWidget {
  const CostCodeListCard({super.key, required this.costCode, this.onTap});

  final OrganizationCostCode costCode;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = costCode;
    final card = AppCard(
      onTap: onTap,
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.md),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        c.code,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.helper.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    if (!c.isActive) ...[
                      const SizedBox(width: AppSpacing.sm),
                      const StatusBadge(label: 'Arşivlendi', tone: StatusTone.muted),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(c.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppTypography.cardTitle),
                if (c.description.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(c.description, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppTypography.metadata),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          const Icon(Icons.chevron_right, color: AppColors.textMuted),
        ],
      ),
    );
    return c.isActive ? card : Opacity(opacity: 0.6, child: card);
  }
}
