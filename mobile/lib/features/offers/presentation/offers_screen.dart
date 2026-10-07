import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_shell.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_filter_bar.dart';
import '../../../core/widgets/app_list_card.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/money_text.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/offers_providers.dart';

/// Teklifler listesi. Durum sekmesi ve arama SUNUCUDA uygulanır
/// (`GET /offers/?status=&q=`), liste sayfa sayfa yüklenir. Eskiden yalnızca
/// ilk 50 teklif çekilip cihazda süzülüyordu: 51. ve sonraki teklifler hiçbir
/// filtrede görünmüyor, sayaçlar yalnızca yüklenen satırları sayıyordu.
/// Sekme sayaçları ve "N teklif" artık backend'in gerçek toplamlarıdır.
class OffersScreen extends ConsumerStatefulWidget {
  const OffersScreen({super.key});

  @override
  ConsumerState<OffersScreen> createState() => _OffersScreenState();
}

class _OffersScreenState extends ConsumerState<OffersScreen> {
  bool _passive = false;
  String _statusFilter = '';
  final _searchController = TextEditingController();
  Timer? _debounce;
  String _query = '';

  OfferListQuery get _listQuery => (passive: _passive, status: _statusFilter, q: _query);

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _applySearch(value));
  }

  void _applySearch(String value) {
    _debounce?.cancel();
    final q = value.trim();
    if (q != _query && mounted) setState(() => _query = q);
  }

  Future<void> _refresh() async {
    final query = _listQuery;
    ref.invalidate(offersPagedProvider(query));
    try {
      await ref.read(offersPagedProvider(query).future);
    } catch (_) {
      // Hata ekranda gösterilir.
    }
  }

  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis == Axis.vertical && n.metrics.extentAfter < 400) {
      ref.read(offersPagedProvider(_listQuery).notifier).loadMore(auto: true);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final query = _listQuery;
    final offersAsync = ref.watch(offersPagedProvider(query));
    final counts = offersAsync.valueOrNull;
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canCreateOffer = user == null || user.permissions.isEmpty || user.hasPermission('offers.create');

    String chipLabel(String label, int? count) => count == null ? label : '$label ($count)';

    return Scaffold(
      appBar: buildAppBar('Teklifler'),
      floatingActionButton: canCreateOffer
          ? FloatingActionButton.extended(
              onPressed: () => context.push('/teklifler/yeni'),
              icon: const Icon(Icons.add),
              label: const Text('Yeni Teklif'),
            )
          : null,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 0),
            child: TextField(
              controller: _searchController,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                hintText: 'Teklif no veya müşteri ara',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
              onChanged: _onSearchChanged,
              onSubmitted: _applySearch,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xs),
            child: AppFilterBar(
              chips: [
                AppFilterChipData(
                  label: chipLabel('Tümü', counts?.allCount),
                  selected: _statusFilter.isEmpty,
                  onTap: () => setState(() => _statusFilter = ''),
                ),
                for (final entry in StatusRegistry.offer.entries)
                  AppFilterChipData(
                    label: chipLabel(entry.value.$1, counts == null ? null : (counts.statusCounts[entry.key] ?? 0)),
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
              onRefresh: _refresh,
              child: AsyncStateView(
                value: offersAsync,
                onRetry: _refresh,
                data: (context, page) {
                  if (page.offers.isEmpty) {
                    return ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: const [
                        SizedBox(height: AppSpacing.xxl),
                        EmptyStateView(message: 'Teklif bulunamadı.', icon: Icons.description_outlined),
                      ],
                    );
                  }
                  return NotificationListener<ScrollNotification>(
                    onNotification: _onScroll,
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: kScreenPadding.copyWith(bottom: 88),
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                          child: Text('${page.total} teklif', style: AppTypography.metadata),
                        ),
                        for (final o in page.offers)
                          AppListCard(
                            title: o.offerNo,
                            subtitle: '${o.customerName} · ${Formatters.date(o.offerDate)}',
                            trailing: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                StatusRegistry.build(o.status, StatusRegistry.offer),
                                const SizedBox(height: 4),
                                MoneyText(
                                  o.grandTotal,
                                  currency: o.currency,
                                  style: AppTypography.metadata.copyWith(fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                            onTap: () => context.push('/teklifler/${o.id}'),
                          ),
                        _LoadMoreFooter(
                          page: page,
                          onLoadMore: () => ref.read(offersPagedProvider(query).notifier).loadMore(),
                        ),
                      ],
                    ),
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

/// Liste sonu: yükleniyor / hata + tekrar dene / "daha fazla" düğmesi.
class _LoadMoreFooter extends StatelessWidget {
  const _LoadMoreFooter({required this.page, required this.onLoadMore});

  final OffersPagedState page;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    if (page.loadingMore) {
      return const Padding(padding: EdgeInsets.all(AppSpacing.lg), child: LoadingState());
    }
    final error = page.loadMoreError;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Column(
          children: [
            Text(
              error is ApiException ? error.message : 'Beklenmeyen bir hata oluştu.',
              style: AppTypography.error,
              textAlign: TextAlign.center,
            ),
            TextButton(onPressed: onLoadMore, child: const Text('Tekrar Dene')),
          ],
        ),
      );
    }
    if (page.hasMore) {
      return Center(
        child: TextButton(
          onPressed: onLoadMore,
          child: Text('Daha fazla göster (${page.offers.length} / ${page.total})'),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}
