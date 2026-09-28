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
import '../data/suppliers_providers.dart';
import '../domain/supplier.dart';
import '../suppliers_paths.dart';
import 'supplier_form_sheet.dart';
import 'widgets/supplier_ui.dart';

/// Tedarikçiler listesi -- web `/admin/tedarikciler` (SuppliersManager.tsx)
/// karşılığı. Okuma `organization.suppliers.read`, ekleme `.manage` ister
/// (KATI `canAccess`: izin kümesi yoksa erişim YOK). Arama ve aktif/arşiv
/// süzmesi istemcidedir (backend tüm kataloğu tek seferde döner).
class SuppliersScreen extends ConsumerStatefulWidget {
  const SuppliersScreen({super.key});

  @override
  ConsumerState<SuppliersScreen> createState() => _SuppliersScreenState();
}

class _SuppliersScreenState extends ConsumerState<SuppliersScreen> {
  final _searchController = TextEditingController();
  String _query = '';
  SupplierStatusFilter _status = SupplierStatusFilter.active;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    ref.invalidate(suppliersListProvider);
    try {
      await ref.read(suppliersListProvider.future);
    } catch (_) {
      // Hata, liste gövdesinde gösterilir.
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final user = auth.valueOrNull;
    const title = Text('Tedarikçiler');

    if (user == null && auth.isLoading) {
      return const AppPageScaffold(title: title, body: LoadingState());
    }
    // İzin yoksa API HİÇ çağrılmaz (derin bağlantıyla gelinse bile).
    if (!user.canAccess(kSuppliersReadPermission)) {
      return AppPageScaffold(title: title, body: const SupplierNoAccessView());
    }
    final canManage = user.canAccess(kSuppliersManagePermission);
    final listAsync = ref.watch(suppliersListProvider);
    final all = listAsync.valueOrNull;

    return AppPageScaffold(
      title: title,
      floatingActionButton: canManage
          ? FloatingActionButton.extended(
              onPressed: _openCreate,
              icon: const Icon(Icons.add),
              label: const Text('Yeni Tedarikçi'),
            )
          : null,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 0),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Kod, unvan veya ticari ad ara',
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
                _chip('Aktif', SupplierStatusFilter.active, all?.where((s) => s.isActive).length),
                _chip('Arşiv', SupplierStatusFilter.archived, all?.where((s) => !s.isActive).length),
                _chip('Tümü', SupplierStatusFilter.all, all?.length),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: listAsync.when(
                loading: () => const SupplierListSkeleton(),
                error: (e, _) => isForbiddenError(e)
                    ? const SupplierNoAccessView()
                    : ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [ErrorState(error: e, onRetry: _refresh)],
                      ),
                data: (suppliers) => _buildList(suppliers, canManage),
              ),
            ),
          ),
        ],
      ),
    );
  }

  AppFilterChipData _chip(String label, SupplierStatusFilter value, int? count) => AppFilterChipData(
        label: count == null ? label : '$label ($count)',
        selected: _status == value,
        onTap: () => setState(() => _status = value),
      );

  Widget _buildList(List<OrganizationSupplier> all, bool canManage) {
    final filtered = filterSuppliers(all, query: _query, status: _status);
    final header = <Widget>[
      if (!canManage) ...[const SupplierReadOnlyNotice(), const SizedBox(height: AppSpacing.md)],
      if (filtered.isNotEmpty) ...[
        Text(
          _query.trim().isEmpty ? '${filtered.length} tedarikçi' : '${filtered.length} sonuç',
          style: AppTypography.metadata,
        ),
        const SizedBox(height: AppSpacing.sm),
      ],
    ];

    if (filtered.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          ...header,
          const SizedBox(height: AppSpacing.xl),
          EmptyStateView(
            icon: Icons.local_shipping_outlined,
            message: all.isEmpty
                ? 'Henüz hiç tedarikçi oluşturulmamış. Satın alma talepleri/RFQ/siparişler bu kataloktan seçilir.'
                : 'Arama kriterlerine uyan tedarikçi yok.',
          ),
        ],
      );
    }

    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 96),
      itemCount: header.length + filtered.length,
      itemBuilder: (context, i) {
        if (i < header.length) return header[i];
        final s = filtered[i - header.length];
        return SupplierListCard(supplier: s, onTap: () => context.push(supplierDetailPath(s.id)));
      },
    );
  }

  Future<void> _openCreate() async {
    final saved = await showSupplierFormSheet(context);
    if (saved != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('"${saved.legalName}" eklendi.')));
    }
  }
}

/// Liste satırı: kod + (arşivse) rozet, tam unvan (2 satıra kadar -- Türk
/// unvanları uzundur), ticari ad / iletişim / şehir özeti. Arşivlenmiş
/// satırlar web'deki gibi soluk (opacity) gösterilir.
class SupplierListCard extends StatelessWidget {
  const SupplierListCard({super.key, required this.supplier, this.onTap});

  final OrganizationSupplier supplier;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final s = supplier;
    final meta = [
      s.tradeName,
      s.contactSummary,
      s.city,
    ].where((v) => v.isNotEmpty).join(' · ');
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
                        s.code,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.helper.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    if (!s.isActive) ...[
                      const SizedBox(width: AppSpacing.sm),
                      const StatusBadge(label: 'Arşivlendi', tone: StatusTone.muted),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(s.legalName, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppTypography.cardTitle),
                if (meta.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppTypography.metadata),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          const Icon(Icons.chevron_right, color: AppColors.textMuted),
        ],
      ),
    );
    return s.isActive ? card : Opacity(opacity: 0.6, child: card);
  }
}
