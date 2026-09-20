import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/customers_providers.dart';
import 'customer_form_sheet.dart';

class CustomersScreen extends ConsumerStatefulWidget {
  const CustomersScreen({super.key});

  @override
  ConsumerState<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends ConsumerState<CustomersScreen> {
  String _query = '';
  String _filter = '';
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = (q: _query, filter: _filter);
    final customersAsync = ref.watch(customersListProvider(query));
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canManage = user == null || user.permissions.isEmpty || user.hasPermission('customers.manage');

    return Scaffold(
      appBar: AppBar(title: const Text('Müşteriler')),
      floatingActionButton: canManage
          ? FloatingActionButton(
              onPressed: () => _showFormSheet(context),
              child: const Icon(Icons.add),
            )
          : null,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _searchController,
              decoration: const InputDecoration(hintText: 'İsme göre ara', prefixIcon: Icon(Icons.search), isDense: true),
              onChanged: (v) => setState(() => _query = v.trim()),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                _FilterChip(label: 'Tümü', selected: _filter == '', onTap: () => setState(() => _filter = '')),
                const SizedBox(width: 8),
                _FilterChip(label: 'Aktif', selected: _filter == 'aktif', onTap: () => setState(() => _filter = 'aktif')),
                const SizedBox(width: 8),
                _FilterChip(label: 'Pasif', selected: _filter == 'pasif', onTap: () => setState(() => _filter = 'pasif')),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async => ref.invalidate(customersListProvider(query)),
              child: AsyncStateView(
                value: customersAsync,
                onRetry: () async => ref.invalidate(customersListProvider(query)),
                isEmpty: (l) => l.isEmpty,
                data: (context, customers) => ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 88),
                  itemCount: customers.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, i) {
                    final c = customers[i];
                    return Card(
                      child: ListTile(
                        title: Text(c.name),
                        subtitle: Text(c.phone.isEmpty ? (c.email.isEmpty ? '-' : c.email) : c.phone),
                        onTap: () => context.push('/diger/musteriler/${c.id}'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            StatusRegistry.build(c.isActive ? 'aktif' : 'pasif', StatusRegistry.customer),
                            if (c.phone.isNotEmpty)
                              IconButton(
                                icon: const Icon(Icons.call_outlined, size: 20),
                                onPressed: () => launchUrl(Uri(scheme: 'tel', path: c.phone)),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showFormSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => const CustomerFormSheet(),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(label: Text(label), selected: selected, onSelected: (_) => onTap());
  }
}
