import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/quick_action_button.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/suppliers_providers.dart';
import '../domain/supplier.dart';
import 'supplier_form_sheet.dart';
import 'widgets/supplier_ui.dart';

/// Tedarikçi detayı -- web'de bu alanlar yalnızca modalda (görüntüleme
/// izniyle kilitli) görülebiliyordu; mobilde ayrı bir ekran. TÜM alanlar
/// gösterilir (boşlar "—"); IBAN'ın kendisi API'den hiç gelmez, yalnızca
/// kayıtlı olup olmadığı. Düzenle/Arşivle/Etkinleştir yalnızca
/// `organization.suppliers.manage` ile görünür.
class SupplierDetailScreen extends ConsumerStatefulWidget {
  const SupplierDetailScreen({super.key, required this.supplierId});

  final String supplierId;

  @override
  ConsumerState<SupplierDetailScreen> createState() => _SupplierDetailScreenState();
}

class _SupplierDetailScreenState extends ConsumerState<SupplierDetailScreen> {
  bool _busy = false;

  Future<void> _refresh() async {
    ref.invalidate(supplierDetailProvider(widget.supplierId));
    try {
      await ref.read(supplierDetailProvider(widget.supplierId).future);
    } catch (_) {
      // Hata gövdede gösterilir.
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final user = auth.valueOrNull;
    if (user == null && auth.isLoading) {
      return const AppPageScaffold(title: Text('Tedarikçi'), body: LoadingState());
    }
    if (!user.canAccess(kSuppliersReadPermission)) {
      return const AppPageScaffold(title: Text('Tedarikçi'), body: SupplierNoAccessView());
    }
    final canManage = user.canAccess(kSuppliersManagePermission);
    final detailAsync = ref.watch(supplierDetailProvider(widget.supplierId));
    final supplier = detailAsync.valueOrNull;

    return AppPageScaffold(
      title: Text(supplier?.legalName ?? 'Tedarikçi', maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: [
        if (canManage && supplier != null)
          IconButton(
            tooltip: 'Düzenle',
            icon: const Icon(Icons.edit_outlined),
            onPressed: _busy ? null : () => _edit(supplier),
          ),
      ],
      body: detailAsync.when(
        loading: () => const LoadingState(),
        error: (e, _) => isForbiddenError(e)
            ? const SupplierNoAccessView()
            : ErrorState(error: e, onRetry: _refresh),
        data: (s) => RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
            children: [
              _Header(supplier: s),
              if (!canManage) ...[const SizedBox(height: AppSpacing.md), const SupplierReadOnlyNotice()],
              // İletişim kısayolları başlığın altında -- müşteri ve personel
              // detayındaki "Ara" / "E-posta" kutucuklarıyla aynı.
              if (s.phone.isNotEmpty || s.email.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.md),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    if (s.phone.isNotEmpty)
                      QuickActionButton(
                        icon: Icons.call_outlined,
                        label: 'Ara',
                        onPressed: () => launchUrl(Uri(scheme: 'tel', path: s.phone)),
                      ),
                    if (s.email.isNotEmpty)
                      QuickActionButton(
                        icon: Icons.mail_outline,
                        label: 'E-posta',
                        onPressed: () => launchUrl(Uri(scheme: 'mailto', path: s.email)),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: AppSpacing.xl),
              SupplierInfoCard(
                title: 'Firma Bilgileri',
                children: [
                  SupplierInfoRow(label: 'Kod', value: s.code),
                  SupplierInfoRow(label: 'Unvan', value: s.legalName),
                  SupplierInfoRow(label: 'Ticari Ad', value: s.tradeName),
                  SupplierInfoRow(label: 'Uzmanlık', value: s.specialty),
                  SupplierInfoRow(label: 'Vergi No', value: s.taxNumber),
                  SupplierInfoRow(label: 'Vergi Dairesi', value: s.taxOffice),
                ],
              ),
              const SizedBox(height: AppSpacing.xl),
              SupplierInfoCard(
                title: 'İletişim',
                children: [
                  SupplierInfoRow(label: 'Yetkili Kişi', value: s.contactName),
                  SupplierInfoRow(label: 'Telefon', value: s.phone),
                  SupplierInfoRow(label: 'E-posta', value: s.email),
                  SupplierInfoRow(label: 'Şehir', value: s.city),
                  SupplierInfoRow(label: 'Ülke', value: s.country),
                  SupplierInfoRow(label: 'Adres', value: s.address),
                ],
              ),
              const SizedBox(height: AppSpacing.xl),
              SupplierInfoCard(
                title: 'Banka',
                children: [
                  SupplierInfoRow(
                    label: 'IBAN',
                    trailing: s.ibanSet
                        ? const StatusBadge(label: 'IBAN kayıtlı', tone: StatusTone.success)
                        : const StatusBadge(label: 'IBAN kayıtlı değil', tone: StatusTone.muted),
                  ),
                  const Padding(
                    padding: EdgeInsets.only(bottom: AppSpacing.xs),
                    child: Text(
                      'Güvenlik için IBAN\'ın kendisi hiçbir ekranda gösterilmez.',
                      style: AppTypography.helper,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xl),
              const Text('Notlar', style: AppTypography.sectionTitle),
              const SizedBox(height: AppSpacing.sm),
              AppCard(
                child: Text(
                  s.notes.isEmpty ? 'Not yok.' : s.notes,
                  style: s.notes.isEmpty ? AppTypography.metadata : AppTypography.body,
                ),
              ),
              if (s.createdAt.isNotEmpty || s.updatedAt.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.md),
                Text(
                  [
                    if (s.createdAt.isNotEmpty) 'Oluşturulma: ${istanbulDate(s.createdAt)}',
                    if (s.updatedAt.isNotEmpty) 'Son güncelleme: ${istanbulDate(s.updatedAt)}',
                  ].join(' · '),
                  style: AppTypography.helper,
                ),
              ],
              if (canManage) ...[
                const SizedBox(height: AppSpacing.xl),
                PrimaryButton(
                  label: 'Düzenle',
                  icon: Icons.edit_outlined,
                  onPressed: _busy ? null : () => _edit(s),
                ),
                const SizedBox(height: AppSpacing.sm),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: s.isActive ? AppColors.danger : AppColors.success,
                  ),
                  onPressed: _busy ? null : () => _toggleActive(s),
                  icon: _busy
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(s.isActive ? Icons.archive_outlined : Icons.unarchive_outlined, size: 18),
                  label: Text(s.isActive ? 'Arşivle' : 'Etkinleştir'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _edit(OrganizationSupplier s) async {
    final saved = await showSupplierFormSheet(context, existing: s);
    if (saved != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Tedarikçi kaydedildi.')));
    }
  }

  Future<void> _toggleActive(OrganizationSupplier s) async {
    final archiving = s.isActive;
    final ok = await confirmSupplierAction(
      context,
      title: archiving ? 'Tedarikçiyi Arşivle' : 'Tedarikçiyi Etkinleştir',
      message: archiving
          ? '"${s.legalName}" (${s.code}) arşivlenecek — yeni PR/RFQ/PO\'larda seçilemeyecek, ama mevcut '
              'kayıtlarda görünmeye devam edecek.'
          : '"${s.legalName}" (${s.code}) yeniden etkinleştirilecek.',
      confirmLabel: archiving ? 'Arşivle' : 'Etkinleştir',
      danger: archiving,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      final repo = ref.read(suppliersRepositoryProvider);
      if (archiving) {
        await repo.archive(s.id);
      } else {
        await repo.reactivate(s.id);
      }
      ref.invalidate(supplierDetailProvider(s.id));
      ref.invalidate(suppliersListProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(archiving ? 'Tedarikçi arşivlendi.' : 'Tedarikçi yeniden etkinleştirildi.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(supplierErrorText(e))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.supplier});

  final OrganizationSupplier supplier;

  @override
  Widget build(BuildContext context) {
    final s = supplier;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                s.code,
                style: AppTypography.metadata.copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.3),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            s.isActive
                ? const StatusBadge(label: 'Aktif', tone: StatusTone.success)
                : const StatusBadge(label: 'Arşivlendi', tone: StatusTone.muted),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(s.legalName, style: AppTypography.pageTitle),
        if (s.tradeName.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(s.tradeName, style: AppTypography.metadata),
        ],
      ],
    );
  }
}

/// RFC3339 -> İstanbul günü "dd.MM.yyyy". Türkiye 2016'dan beri sabit
/// UTC+3; cihazın saat diliminden bağımsız (ana sayfadaki `Formatters.hm`
/// ile aynı kural).
String istanbulDate(String rfc3339) {
  final parsed = DateTime.tryParse(rfc3339);
  if (parsed == null) return rfc3339;
  final t = parsed.toUtc().add(const Duration(hours: 3));
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.day)}.${two(t.month)}.${t.year}';
}
