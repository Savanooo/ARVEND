import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_shell.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/async_state_view.dart';
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
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
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
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: SizedBox(
              height: 36,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  ChoiceChip(
                      label: const Text('Tümü'),
                      selected: _statusFilter.isEmpty,
                      onSelected: (_) => setState(() => _statusFilter = '')),
                  for (final entry in StatusRegistry.offer.entries)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: ChoiceChip(
                        label: Text(entry.value.$1),
                        selected: _statusFilter == entry.key,
                        onSelected: (_) => setState(() => _statusFilter = entry.key),
                      ),
                    ),
                  const SizedBox(width: 8),
                  FilterChip(
                    label: const Text('Pasif'),
                    selected: _passive,
                    onSelected: (v) => setState(() => _passive = v),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async => ref.invalidate(offersListProvider(_passive ? 'pasif' : '')),
              child: AsyncStateView(
                value: offersAsync,
                onRetry: () async => ref.invalidate(offersListProvider(_passive ? 'pasif' : '')),
                data: (context, r) {
                  final filtered = r.offers.where((o) {
                    if (_statusFilter.isNotEmpty && o.status != _statusFilter) return false;
                    if (_query.isEmpty) return true;
                    return o.offerNo.toLowerCase().contains(_query) ||
                        o.customerName.toLowerCase().contains(_query);
                  }).toList();
                  if (filtered.isEmpty) {
                    return const EmptyStateView(message: 'Teklif bulunamadı.');
                  }
                  return ListView.separated(
                    padding: kScreenPadding.copyWith(bottom: 88),
                    itemCount: filtered.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final o = filtered[i];
                      return Card(
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          title: Text(o.offerNo),
                          subtitle: Text(o.customerName, maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              StatusRegistry.build(o.status, StatusRegistry.offer),
                              const SizedBox(height: 4),
                              Text(Formatters.money(o.grandTotal),
                                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                            ],
                          ),
                          onTap: () => context.push('/teklifler/${o.id}'),
                        ),
                      );
                    },
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
