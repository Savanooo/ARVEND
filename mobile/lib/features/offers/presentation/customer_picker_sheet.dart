import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../customers/data/customers_providers.dart';
import '../../customers/domain/customer.dart';

/// Teklif formunda "mevcut müşteriden seç" akışı -- müşteri modülünü teklif
/// içinde TEKRARLAMAZ, yalnızca zaten var olan `customersListProvider`
/// (arama destekli) üzerinden bir `Customer` seçtirip geri döner.
Future<Customer?> showCustomerPickerSheet(BuildContext context) {
  return showModalBottomSheet<Customer>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => const _CustomerPickerSheet(),
  );
}

class _CustomerPickerSheet extends ConsumerStatefulWidget {
  const _CustomerPickerSheet();

  @override
  ConsumerState<_CustomerPickerSheet> createState() => _CustomerPickerSheetState();
}

class _CustomerPickerSheetState extends ConsumerState<_CustomerPickerSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    // Yalnızca AKTİF müşteriler: arşivlenmiş bir müşteri listede hiçbir
    // işaret olmadan çıkıyor ve yeni teklife bağlanabiliyordu (web formu da
    // yalnızca aktifleri önerir). Arama ad, telefon, vergi no ve e-postada
    // sunucuda yapılır.
    final query = (q: _query, filter: 'aktif');
    final customersAsync = ref.watch(customersListProvider(query));

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.75,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Text('Müşteri Seç', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
            const SizedBox(height: 12),
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'İsim, telefon, vergi no veya e-posta ara',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v.trim()),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: AsyncStateView(
                value: customersAsync,
                isEmpty: (list) => list.isEmpty,
                emptyBuilder: (_) => const EmptyStateView(message: 'Müşteri bulunamadı.'),
                data: (context, customers) => ListView.separated(
                  itemCount: customers.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final c = customers[i];
                    return ListTile(
                      title: Text(c.name),
                      subtitle: Text(
                        [if (c.phone.isNotEmpty) c.phone, if (c.email.isNotEmpty) c.email].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.chevron_right, color: AppColors.textMuted),
                      onTap: () => Navigator.of(context).pop(c),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
