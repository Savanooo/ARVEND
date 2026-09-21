import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/app_shell.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/app_filter_bar.dart';
import '../../../core/widgets/app_list_card.dart';
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
    final canManage =
        user == null ||
        user.permissions.isEmpty ||
        user.hasPermission('customers.manage');

    return Scaffold(
      appBar: buildAppBar('Müşteriler'),
      floatingActionButton: canManage
          ? FloatingActionButton(
              onPressed: () => _showFormSheet(context),
              child: const Icon(Icons.add),
            )
          : null,
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
                hintText: 'İsme göre ara',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v.trim()),
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
                  selected: _filter == '',
                  onTap: () => setState(() => _filter = ''),
                ),
                AppFilterChipData(
                  label: 'Aktif',
                  selected: _filter == 'aktif',
                  onTap: () => setState(() => _filter = 'aktif'),
                ),
                AppFilterChipData(
                  label: 'Pasif',
                  selected: _filter == 'pasif',
                  onTap: () => setState(() => _filter = 'pasif'),
                ),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async =>
                  ref.invalidate(customersListProvider(query)),
              child: AsyncStateView(
                value: customersAsync,
                onRetry: () async =>
                    ref.invalidate(customersListProvider(query)),
                isEmpty: (l) => l.isEmpty,
                emptyBuilder: (_) => const EmptyStateView(
                  message: 'Müşteri bulunamadı.',
                  icon: Icons.people_outline,
                ),
                data: (context, customers) => ListView(
                  padding: kScreenPadding.copyWith(bottom: 88),
                  children: [
                    for (final c in customers)
                      AppListCard(
                        title: c.name,
                        subtitle: c.phone.isEmpty
                            ? (c.email.isEmpty ? null : c.email)
                            : c.phone,
                        onTap: () => context.push('/diger/musteriler/${c.id}'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            StatusRegistry.build(
                              c.isActive ? 'aktif' : 'pasif',
                              StatusRegistry.customer,
                            ),
                            if (c.phone.isNotEmpty)
                              IconButton(
                                icon: const Icon(
                                  Icons.call_outlined,
                                  size: 20,
                                  color: AppColors.gold,
                                ),
                                onPressed: () => launchUrl(
                                  Uri(scheme: 'tel', path: c.phone),
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
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
