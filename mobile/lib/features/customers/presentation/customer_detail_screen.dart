import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_list_card.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/app_section_header.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/money_text.dart';
import '../../../core/widgets/quick_action_button.dart';
import '../../../core/widgets/status_badge.dart';
import '../../offers/data/offers_providers.dart';
import '../../projects/data/projects_providers.dart';
import '../data/customers_providers.dart';
import '../domain/customer.dart';
import 'customer_form_sheet.dart';
import '../../../core/widgets/app_sheet.dart';

/// Müşteri detay -- "Teklifler"/"Projeler" bölümleri backend'in ZATEN var
/// olan uçlarını (bkz. bu modülün backend değişikliği: `GET /offers?
/// customer_id=`; ve zaten var olan `GET /projects?customer_id=`) kullanır.
/// Backend'de müşteri seviyesinde bir cari/bakiye/ledger YOKTUR (bkz.
/// Phase 1 doğrulaması) -- "Finansal Özet" yeni bir hesap İCAT ETMEZ,
/// yalnızca projelerin ZATEN backend-hesaplı alanlarını para birimine göre
/// toplar (bkz. `summarizeProjectReceivables`).
class CustomerDetailScreen extends ConsumerStatefulWidget {
  const CustomerDetailScreen({super.key, required this.customerId});
  final String customerId;

  @override
  ConsumerState<CustomerDetailScreen> createState() =>
      _CustomerDetailScreenState();
}

class _CustomerDetailScreenState extends ConsumerState<CustomerDetailScreen> {
  bool _archiving = false;

  @override
  Widget build(BuildContext context) {
    final customerAsync = ref.watch(customerDetailProvider(widget.customerId));
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canManage =
        user == null ||
        user.permissions.isEmpty ||
        user.hasPermission('customers.manage');
    final canSeeProjects =
        user == null ||
        user.permissions.isEmpty ||
        user.hasPermission('projects.read');
    final canSeeOffers =
        user == null ||
        user.permissions.isEmpty ||
        user.hasPermission('offers.read');
    final canCreateOffer =
        user == null ||
        user.permissions.isEmpty ||
        user.hasPermission('offers.create');

    return AppPageScaffold(
      title: customerAsync.maybeWhen(
        data: (c) => Text(c.name),
        orElse: () => const Text('Müşteri'),
      ),
      actions: [
        if (canManage)
          customerAsync.maybeWhen(
            data: (c) => IconButton(
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => _showFormSheet(c),
            ),
            orElse: () => const SizedBox.shrink(),
          ),
        if (canManage)
          customerAsync.maybeWhen(
            data: (c) => c.isActive
                ? IconButton(
                    icon: const Icon(Icons.archive_outlined),
                    tooltip: 'Pasifleştir',
                    onPressed: _archiving ? null : () => _archive(c),
                  )
                // Pasif müşteri eskiden mobilden geri alınamıyordu (web
                // "Aktif" kutusuyla alabiliyor).
                : IconButton(
                    key: const ValueKey('customer-reactivate'),
                    icon: const Icon(Icons.unarchive_outlined),
                    tooltip: 'Aktifleştir',
                    onPressed: _archiving ? null : () => _reactivate(c),
                  ),
            orElse: () => const SizedBox.shrink(),
          ),
      ],
      body: AsyncStateView(
        value: customerAsync,
        onRetry: () async =>
            ref.invalidate(customerDetailProvider(widget.customerId)),
        data: (context, c) => RefreshIndicator(
          onRefresh: () async =>
              ref.invalidate(customerDetailProvider(widget.customerId)),
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              Row(
                children: [
                  Expanded(child: Text(c.name, style: AppTypography.pageTitle)),
                  const SizedBox(width: AppSpacing.sm),
                  StatusRegistry.build(
                    c.isActive ? 'aktif' : 'pasif',
                    StatusRegistry.customer,
                  ),
                ],
              ),
              if (c.phone.isNotEmpty ||
                  c.email.isNotEmpty ||
                  canCreateOffer) ...[
                const SizedBox(height: AppSpacing.md),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    if (c.phone.isNotEmpty)
                      QuickActionButton(
                        icon: Icons.call_outlined,
                        label: 'Ara',
                        onPressed: () =>
                            launchUrl(Uri(scheme: 'tel', path: c.phone)),
                      ),
                    if (c.email.isNotEmpty)
                      QuickActionButton(
                        icon: Icons.email_outlined,
                        label: 'E-posta',
                        onPressed: () =>
                            launchUrl(Uri(scheme: 'mailto', path: c.email)),
                      ),
                    if (canCreateOffer)
                      QuickActionButton(
                        icon: Icons.add_circle_outline,
                        label: 'Yeni Teklif',
                        onPressed: () => context.push(
                          Uri(
                            path: '/teklifler/yeni',
                            queryParameters: {
                              'customerId': c.id,
                              'customerName': c.name,
                              if (c.phone.isNotEmpty) 'customerPhone': c.phone,
                              if (c.email.isNotEmpty) 'customerEmail': c.email,
                              if (c.address.isNotEmpty)
                                'customerAddress': c.address,
                            },
                          ).toString(),
                        ),
                      ),
                  ],
                ),
              ],
              if (c.phone.isNotEmpty ||
                  c.email.isNotEmpty ||
                  c.address.isNotEmpty ||
                  c.taxOffice.isNotEmpty ||
                  c.taxNumber.isNotEmpty ||
                  c.notes.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.xl),
                const AppSectionHeader(title: 'İletişim'),
                const SizedBox(height: AppSpacing.sm),
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (c.phone.isNotEmpty)
                        _ContactRow(icon: Icons.call_outlined, value: c.phone),
                      if (c.email.isNotEmpty)
                        _ContactRow(icon: Icons.email_outlined, value: c.email),
                      if (c.address.isNotEmpty)
                        _ContactRow(
                          icon: Icons.location_on_outlined,
                          value: c.address,
                        ),
                      if (c.taxOffice.isNotEmpty || c.taxNumber.isNotEmpty)
                        _ContactRow(
                          icon: Icons.receipt_long_outlined,
                          value: '${c.taxOffice}  ${c.taxNumber}'.trim(),
                        ),
                      if (c.notes.isNotEmpty)
                        _ContactRow(icon: Icons.notes_outlined, value: c.notes),
                    ],
                  ),
                ),
              ],
              if (canSeeOffers) ...[
                const SizedBox(height: AppSpacing.xl),
                const AppSectionHeader(title: 'Teklifler'),
                const SizedBox(height: AppSpacing.sm),
                _OffersSection(customerId: c.id),
              ],
              if (canSeeProjects) ...[
                const SizedBox(height: AppSpacing.xl),
                const AppSectionHeader(title: 'Projeler'),
                const SizedBox(height: AppSpacing.sm),
                _ProjectsSection(customerId: c.id),
                const SizedBox(height: AppSpacing.xl),
                const AppSectionHeader(title: 'Finansal Özet'),
                const SizedBox(height: AppSpacing.sm),
                _FinancialSummarySection(customerId: c.id),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _showFormSheet(Customer existing) {
    showAppSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => CustomerFormSheet(existing: existing),
    );
  }

  Future<void> _reactivate(Customer c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Müşteriyi Aktifleştir'),
        content: Text('${c.name} yeniden aktifleştirilsin mi? Yeni teklif ve projelerde seçilebilir olur.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Vazgeç')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Aktifleştir')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _sendReactivate(c);
  }

  /// Aktifleştirme de bir PUT: sunucu 409 duplicate_customer dönerse
  /// oluştur/düzenle formundaki çakışma diyaloğu açılır (ham sunucu mesajı
  /// yerine çakışan müşteri + "Mevcut müşteriyi aç / Yine de kaydet").
  Future<void> _sendReactivate(Customer c, {bool allowDuplicate = false}) async {
    setState(() => _archiving = true);
    DuplicateCustomer? dup;
    try {
      await ref.read(customersRepositoryProvider).reactivate(c, allowDuplicate: allowDuplicate);
      ref.invalidate(customerDetailProvider(c.id));
      ref.invalidate(customersListProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Müşteri aktifleştirildi.')));
      }
    } on ApiException catch (e) {
      dup = allowDuplicate ? null : DuplicateCustomer.fromError(e);
      if (dup == null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _archiving = false);
    }
    if (dup == null || !mounted) return;
    final choice = await showDuplicateCustomerDialog(context, dup);
    if (!mounted) return;
    switch (choice) {
      case DuplicateCustomerChoice.saveAnyway:
        await _sendReactivate(c, allowDuplicate: true);
      case DuplicateCustomerChoice.open:
        context.push('/diger/musteriler/${Uri.encodeComponent(dup.id)}');
      case DuplicateCustomerChoice.cancel:
      case null:
        break;
    }
  }

  Future<void> _archive(Customer c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Müşteriyi Pasifleştir'),
        content: Text(
          '${c.name} pasifleştirilsin mi? Geçmiş teklif/proje kayıtları etkilenmez.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Vazgeç'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Pasifleştir'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _archiving = true);
    try {
      await ref.read(customersRepositoryProvider).archive(c.id);
      ref.invalidate(customerDetailProvider(c.id));
      ref.invalidate(customersListProvider);
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _archiving = false);
    }
  }
}

class _ContactRow extends StatelessWidget {
  const _ContactRow({required this.icon, required this.value});
  final IconData icon;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: AppColors.textMuted),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(value, style: AppTypography.body)),
        ],
      ),
    );
  }
}

class _ProjectsSection extends ConsumerWidget {
  const _ProjectsSection({required this.customerId});
  final String customerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectsAsync = ref.watch(customerProjectsProvider(customerId));
    return projectsAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
      ),
      error: (e, st) =>
          const Text('Projeler alınamadı', style: AppTypography.metadata),
      data: (result) {
        if (result.projects.isEmpty) {
          return const AppCard(
            child: Text(
              'Bu müşteriye bağlı proje yok.',
              style: AppTypography.metadata,
            ),
          );
        }
        return Column(
          children: [
            for (final p in result.projects)
              AppListCard(
                title: p.name,
                subtitle: p.projectNo,
                onTap: () => context.push('/projeler/${p.id}'),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    StatusRegistry.build(p.status, StatusRegistry.project),
                    const SizedBox(height: AppSpacing.xs),
                    MoneyText(
                      p.currentContractValue ?? p.contractAmount,
                      currency: p.currency,
                      style: AppTypography.metadata,
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _FinancialSummarySection extends ConsumerWidget {
  const _FinancialSummarySection({required this.customerId});
  final String customerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectsAsync = ref.watch(customerProjectsProvider(customerId));
    return projectsAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
      ),
      error: (e, st) =>
          const Text('Finansal özet alınamadı', style: AppTypography.metadata),
      data: (result) {
        final summaries = summarizeProjectReceivables(result.projects);
        if (summaries.isEmpty) {
          return const AppCard(
            child: Text(
              'Gösterilecek finansal veri yok.',
              style: AppTypography.metadata,
            ),
          );
        }
        return AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final s in summaries) ...[
                if (summaries.length > 1)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                    child: Text(s.currency, style: AppTypography.cardTitle),
                  ),
                _ReceivablesRow(
                  label: 'Sözleşme Değeri',
                  amount: s.contractValue,
                  currency: s.currency,
                ),
                _ReceivablesRow(
                  label: 'Tahsil Edilen',
                  amount: s.collected,
                  currency: s.currency,
                ),
                _ReceivablesRow(
                  label: 'Kalan Alacak',
                  amount: s.remaining,
                  currency: s.currency,
                  emphasize: true,
                ),
                if (s != summaries.last) const Divider(height: AppSpacing.lg),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _ReceivablesRow extends StatelessWidget {
  const _ReceivablesRow({
    required this.label,
    required this.amount,
    required this.currency,
    this.emphasize = false,
  });
  final String label;
  final double amount;
  final String currency;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: AppTypography.metadata),
          MoneyText(
            amount,
            currency: currency,
            style: AppTypography.body.copyWith(
              fontWeight: emphasize ? FontWeight.w800 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _OffersSection extends ConsumerWidget {
  const _OffersSection({required this.customerId});
  final String customerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offersAsync = ref.watch(customerOffersProvider(customerId));
    return offersAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
      ),
      error: (e, st) =>
          const Text('Teklifler alınamadı', style: AppTypography.metadata),
      data: (result) {
        if (result.offers.isEmpty) {
          return const AppCard(
            child: Text(
              'Bu müşteriye bağlı teklif yok.',
              style: AppTypography.metadata,
            ),
          );
        }
        return Column(
          children: [
            for (final o in result.offers)
              AppListCard(
                title: o.offerNo,
                subtitle: Formatters.date(o.offerDate),
                onTap: () => context.push('/teklifler/${o.id}'),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    StatusRegistry.build(o.status, StatusRegistry.offer),
                    const SizedBox(height: 4),
                    MoneyText(o.grandTotal, currency: o.currency, style: AppTypography.metadata),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
