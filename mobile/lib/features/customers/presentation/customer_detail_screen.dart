import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_badge.dart';
import '../../offers/data/offers_providers.dart';
import '../../offers/domain/offer.dart';
import '../../projects/data/projects_providers.dart';
import '../../projects/domain/project.dart';
import '../data/customers_providers.dart';
import '../domain/customer.dart';
import 'customer_form_sheet.dart';

/// Müşteri detay -- "Teklifler"/"Projeler" bölümleri backend'in ZATEN var
/// olan uçlarını (bkz. bu modülün backend değişikliği: `GET /offers?
/// customer_id=`; ve zaten var olan `GET /projects?customer_id=`) kullanır.
/// Backend'de müşteri seviyesinde bir cari/bakiye/ledger YOKTUR (bkz.
/// Phase 1 doğrulaması) -- "Alacaklar" bölümü yeni bir hesap İCAT ETMEZ,
/// yalnızca projelerin ZATEN backend-hesaplı alanlarını para birimine göre
/// toplar (bkz. `summarizeProjectReceivables`).
class CustomerDetailScreen extends ConsumerStatefulWidget {
  const CustomerDetailScreen({super.key, required this.customerId});
  final String customerId;

  @override
  ConsumerState<CustomerDetailScreen> createState() => _CustomerDetailScreenState();
}

class _CustomerDetailScreenState extends ConsumerState<CustomerDetailScreen> {
  bool _archiving = false;

  @override
  Widget build(BuildContext context) {
    final customerAsync = ref.watch(customerDetailProvider(widget.customerId));
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canManage = user == null || user.permissions.isEmpty || user.hasPermission('customers.manage');
    final canSeeProjects = user == null || user.permissions.isEmpty || user.hasPermission('projects.read');
    final canSeeOffers = user == null || user.permissions.isEmpty || user.hasPermission('offers.read');
    final canCreateOffer = user == null || user.permissions.isEmpty || user.hasPermission('offers.create');

    return Scaffold(
      appBar: AppBar(
        title: customerAsync.maybeWhen(data: (c) => Text(c.name), orElse: () => const Text('Müşteri')),
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
                      onPressed: _archiving ? null : () => _archive(c),
                    )
                  : const SizedBox.shrink(),
              orElse: () => const SizedBox.shrink(),
            ),
        ],
      ),
      body: AsyncStateView(
        value: customerAsync,
        onRetry: () async => ref.invalidate(customerDetailProvider(widget.customerId)),
        data: (context, c) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(c.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                        ),
                        StatusRegistry.build(c.isActive ? 'aktif' : 'pasif', StatusRegistry.customer),
                      ],
                    ),
                    if (c.address.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      const Text('Adres', style: TextStyle(color: Colors.grey, fontSize: 12)),
                      Text(c.address),
                    ],
                    if (c.taxOffice.isNotEmpty || c.taxNumber.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text('${c.taxOffice}  ${c.taxNumber}'.trim()),
                    ],
                    if (c.notes.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(c.notes),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (c.phone.isNotEmpty)
              _ActionTile(
                icon: Icons.call_outlined,
                label: c.phone,
                onTap: () => launchUrl(Uri(scheme: 'tel', path: c.phone)),
              ),
            if (c.email.isNotEmpty)
              _ActionTile(
                icon: Icons.email_outlined,
                label: c.email,
                onTap: () => launchUrl(Uri(scheme: 'mailto', path: c.email)),
              ),
            if (canCreateOffer)
              _ActionTile(
                icon: Icons.add_circle_outline,
                label: 'Yeni Teklif',
                onTap: () => context.push(Uri(path: '/teklifler/yeni', queryParameters: {
                  'customerId': c.id,
                  'customerName': c.name,
                  if (c.phone.isNotEmpty) 'customerPhone': c.phone,
                  if (c.email.isNotEmpty) 'customerEmail': c.email,
                  if (c.address.isNotEmpty) 'customerAddress': c.address,
                }).toString()),
              ),
            if (canSeeProjects) ...[
              const SizedBox(height: 8),
              _ProjectsSection(customerId: c.id),
            ],
            if (canSeeOffers) ...[
              const SizedBox(height: 8),
              _OffersSection(customerId: c.id),
            ],
          ],
        ),
      ),
    );
  }

  void _showFormSheet(Customer existing) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => CustomerFormSheet(existing: existing),
    );
  }

  Future<void> _archive(Customer c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Müşteriyi Pasifleştir'),
        content: Text('${c.name} pasifleştirilsin mi? Geçmiş teklif/proje kayıtları etkilenmez.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Vazgeç')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Pasifleştir')),
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
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _archiving = false);
    }
  }
}

class _ProjectsSection extends ConsumerWidget {
  const _ProjectsSection({required this.customerId});
  final String customerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectsAsync = ref.watch(customerProjectsProvider(customerId));
    return _Section(
      title: 'Projeler',
      child: projectsAsync.when(
        loading: () => const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
        ),
        error: (e, st) => const Text('Projeler alınamadı', style: TextStyle(color: AppColors.textMuted)),
        data: (result) {
          if (result.projects.isEmpty) {
            return const Text('Bu müşteriye bağlı proje yok.', style: TextStyle(color: AppColors.textMuted, fontSize: 13));
          }
          final receivables = summarizeProjectReceivables(result.projects);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (receivables.isNotEmpty) _ReceivablesSummaryCard(summaries: receivables),
              if (receivables.isNotEmpty) const SizedBox(height: 8),
              ...result.projects.map((p) => _ProjectRow(project: p)),
            ],
          );
        },
      ),
    );
  }
}

class _ReceivablesSummaryCard extends StatelessWidget {
  const _ReceivablesSummaryCard({required this.summaries});
  final List<CustomerReceivablesSummary> summaries;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppColors.background,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final s in summaries) ...[
              if (summaries.length > 1) Text(s.currency, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
              _ReceivablesRow(label: 'Sözleşme Değeri', amount: s.contractValue, currency: s.currency),
              _ReceivablesRow(label: 'Tahsil Edilen', amount: s.collected, currency: s.currency),
              _ReceivablesRow(label: 'Kalan Alacak', amount: s.remaining, currency: s.currency, emphasize: true),
              if (s != summaries.last) const Divider(height: 16),
            ],
          ],
        ),
      ),
    );
  }
}

class _ReceivablesRow extends StatelessWidget {
  const _ReceivablesRow({required this.label, required this.amount, required this.currency, this.emphasize = false});
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
          Text(label, style: const TextStyle(fontSize: 13, color: AppColors.textMuted)),
          Text(
            Formatters.money(amount, currency: currency),
            style: TextStyle(fontSize: 13, fontWeight: emphasize ? FontWeight.w800 : FontWeight.w500),
          ),
        ],
      ),
    );
  }
}

class _ProjectRow extends StatelessWidget {
  const _ProjectRow({required this.project});
  final Project project;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        onTap: () => context.push('/projeler/${project.id}'),
        title: Text(project.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(project.projectNo),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            StatusRegistry.build(project.status, StatusRegistry.project),
            const SizedBox(height: 4),
            Text(
              Formatters.money(project.currentContractValue ?? project.contractAmount, currency: project.currency),
              style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted),
            ),
          ],
        ),
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
    return _Section(
      title: 'Teklifler',
      child: offersAsync.when(
        loading: () => const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
        ),
        error: (e, st) => const Text('Teklifler alınamadı', style: TextStyle(color: AppColors.textMuted)),
        data: (result) {
          if (result.offers.isEmpty) {
            return const Text('Bu müşteriye bağlı teklif yok.', style: TextStyle(color: AppColors.textMuted, fontSize: 13));
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: result.offers.map((o) => _OfferRow(offer: o)).toList(),
          );
        },
      ),
    );
  }
}

class _OfferRow extends StatelessWidget {
  const _OfferRow({required this.offer});
  final Offer offer;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        onTap: () => context.push('/teklifler/${offer.id}'),
        title: Text(offer.offerNo),
        subtitle: Text(Formatters.date(offer.offerDate)),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            StatusRegistry.build(offer.status, StatusRegistry.offer),
            const SizedBox(height: 4),
            Text(Formatters.money(offer.grandTotal), style: const TextStyle(fontSize: 11.5, color: AppColors.textMuted)),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        const SizedBox(height: 8),
        child,
        const SizedBox(height: 8),
      ],
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(leading: Icon(icon), title: Text(label), onTap: onTap),
    );
  }
}
