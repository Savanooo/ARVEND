import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_shell.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_filter_bar.dart';
import '../../../core/widgets/app_list_card.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/money_text.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/offers_providers.dart';

/// Backend `GET /offers/`'te yalnızca `filter=pasif|*` var - durum/arama/
/// müşteri/tarih filtresi YOK (bkz. API_CONTRACT.md). Durum sekmeleri ve
/// arama bu yüzden zaten çekilmiş listenin üzerinde CLIENT-SIDE uygulanır;
/// sahte bir "toplam" izlenimi vermemek için KPI'lar yerine yalnız sekme
/// filtreli liste sayısı gösterilir.
class OffersScreen extends ConsumerStatefulWidget {
  const OffersScreen({super.key});

  @override
  ConsumerState<OffersScreen> createState() => _OffersScreenState();
}

class _OffersScreenState extends ConsumerState<OffersScreen> {
  bool _passive = false;
  String _statusFilter = '';
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final offersAsync = ref.watch(offersListProvider(_passive ? 'pasif' : ''));

    return Scaffold(
      appBar: buildAppBar('Teklifler'),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/teklifler/yeni'),
        icon: const Icon(Icons.add),
        label: const Text('Yeni Teklif'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.md,
              AppSpacing.lg,
              0,
            ),
            child: TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                hintText: 'Teklif no veya müşteri ara',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.sm,
              AppSpacing.lg,
              AppSpacing.xs,
            ),
            child: AppFilterBar(
              chips: [
                AppFilterChipData(
                  label: 'Tümü',
                  selected: _statusFilter.isEmpty,
                  onTap: () => setState(() => _statusFilter = ''),
                ),
                for (final entry in StatusRegistry.offer.entries)
                  AppFilterChipData(
                    label: entry.value.$1,
                    selected: _statusFilter == entry.key,
                    onTap: () => setState(() => _statusFilter = entry.key),
                  ),
                AppFilterChipData(
                  label: 'Pasif',
                  selected: _passive,
                  onTap: () => setState(() => _passive = !_passive),
                ),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async =>
                  ref.invalidate(offersListProvider(_passive ? 'pasif' : '')),
              child: AsyncStateView(
                value: offersAsync,
                onRetry: () async =>
                    ref.invalidate(offersListProvider(_passive ? 'pasif' : '')),
                data: (context, r) {
                  final filtered = r.offers.where((o) {
                    if (_statusFilter.isNotEmpty && o.status != _statusFilter) {
                      return false;
                    }
                    if (_query.isEmpty) return true;
                    return o.offerNo.toLowerCase().contains(_query) ||
                        o.customerName.toLowerCase().contains(_query);
                  }).toList();
                  if (filtered.isEmpty) {
                    return const EmptyStateView(
                      message: 'Teklif bulunamadı.',
                      icon: Icons.description_outlined,
                    );
                  }
                  return ListView(
                    padding: kScreenPadding.copyWith(bottom: 88),
                    children: [
                      for (final o in filtered)
                        AppListCard(
                          title: o.offerNo,
                          subtitle:
                              '${o.customerName} · ${Formatters.date(o.offerDate)}',
                          trailing: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              StatusRegistry.build(
                                o.status,
                                StatusRegistry.offer,
                              ),
                              const SizedBox(height: 4),
                              MoneyText(
                                o.grandTotal,
                                style: AppTypography.metadata.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          onTap: () => context.push('/teklifler/${o.id}'),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
