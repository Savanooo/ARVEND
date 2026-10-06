import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/auth/auth_controller.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/errors/api_exception.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/widgets/access_notices.dart';
import '../../../../core/widgets/app_buttons.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_form_section.dart';
import '../../../../core/widgets/app_section_header.dart';
import '../../../../core/widgets/unsaved_changes_scope.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../../../../core/widgets/status_badge.dart';
import '../../../../core/widgets/viz/progress_bar.dart';
import '../../budget/domain/budget.dart' show formatTrDecimalInput;
import '../../domain/project.dart';
import '../../finance_plan/domain/finance_dates.dart' show parseAmountInput;
import '../data/finance_ledger_providers.dart';
import '../domain/legacy_subcontractor.dart';
import 'ledger_entry_sheet.dart';
import 'ledger_ui.dart';

/// Finans > "Taşeron Ödemeleri" (`?grup=finans&alt=taseron-odemeleri`) --
/// web proje Finans sekmesindeki "Taşeronlar" bölümünün (`Subcontractors
/// Section`) karşılığı: legacy taşeron kaydı (tek sözleşme bedeli) + ona
/// yapılan GERÇEK ödemeler. Operasyon > Taşeronlar'daki taşeron
/// SÖZLEŞMELERİ (SOV/hakediş) ayrı bir sistemdir (docs/subcontracts.md §0);
/// ikisi birleştirilmez.
///
/// Görmek `projects.finance.read`; "Taşeron Ekle" / "Ödeme Ekle" / taşeron
/// düzenleme / ödeme iptali `projects.finance.manage` + açık proje (web
/// `locked`). İzin yoksa API hiç çağrılmaz; 403 gelirse "yetkin yok"
/// görünümü, çökme yok. Ödeme satırına dokununca ayrıntı açılır (iptal
/// yalnızca yetkiliye).
class SubcontractorPaymentsTab extends ConsumerWidget {
  const SubcontractorPaymentsTab({super.key, required this.projectId, required this.project});

  final String projectId;
  final Project project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final user = auth.valueOrNull;
    if (user == null && auth.isLoading) return const LoadingState();
    if (!user.can(kLedgerReadPermission)) {
      return const NoAccessView(message: kLedgerNoAccessText, scrollable: true);
    }
    final locked = isLedgerLocked(project.status);
    final canManage = user.can(kLedgerManagePermission) && !locked;
    final subsAsync = ref.watch(legacySubcontractorsProvider(projectId));
    final paymentsAsync = ref.watch(legacySubcontractorPaymentsProvider(projectId));

    Future<void> refresh() async {
      ref.invalidate(legacySubcontractorsProvider(projectId));
      ref.invalidate(legacySubcontractorPaymentsProvider(projectId));
      try {
        await ref.read(legacySubcontractorsProvider(projectId).future);
      } catch (_) {
        // Hata gövdede gösterilir.
      }
    }

    if (subsAsync.hasError && isForbiddenError(subsAsync.error)) {
      return RefreshIndicator(
        onRefresh: refresh,
        child: const NoAccessView(message: kLedgerNoAccessText, scrollable: true),
      );
    }

    Future<void> addSubcontractor() async {
      // Kapsayıcı sayfa açılmadan ÖNCE: sekme bu arada ağaçtan kalksa da
      // liste tazelenir.
      final container = ProviderScope.containerOf(context, listen: false);
      final created = await showLegacySubcontractorFormSheet(context, projectId: projectId, currency: project.currency);
      if (created != null) {
        invalidateProjectLedger(container.invalidate, projectId);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Taşeron eklendi.')));
        }
      }
    }

    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xxl),
        children: [
          AppSectionHeader(
            // "Taşeron Ödemeleri" zaten seçili çipte yazılı; başlık listeyi anlatır.
            title: 'Taşeron Kayıtları',
            trailing: canManage
                ? TextButton.icon(
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Taşeron Ekle'),
                    onPressed: addSubcontractor,
                  )
                : null,
          ),
          const SizedBox(height: AppSpacing.xs),
          const Text(
            'Taşerona yapılan gerçek ödemeler buradan kaydedilir ve gerçekleşen maliyete girer; masraflara ayrıca '
            'girilmez. Taşeron sözleşmeleri ve hakedişler Operasyon > Taşeronlar bölümündedir.',
            style: AppTypography.helper,
          ),
          if (locked) ...[const SizedBox(height: AppSpacing.sm), ReadOnlyNotice(ledgerLockedText(project.status))],
          const SizedBox(height: AppSpacing.md),
          subsAsync.when(
            loading: () => const Padding(padding: EdgeInsets.all(AppSpacing.xl), child: LoadingState()),
            error: (e, _) => ErrorState(error: e, onRetry: refresh),
            data: (subs) {
              if (subs.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
                  child: EmptyStateView(message: 'Henüz taşeron kaydı yok.', icon: Icons.handyman_outlined),
                );
              }
              final payments = paymentsAsync.valueOrNull ?? const <LegacySubcontractorPayment>[];
              return Column(
                children: [
                  for (final s in subs)
                    LegacySubcontractorCard(
                      subcontractor: s,
                      payments: payments.where((p) => p.subcontractorId == s.id && !p.isVoided).toList(),
                      // Yanlış girilmiş bir taşeron (ad, bedel) eskiden hiçbir
                      // yerden düzeltilemiyordu.
                      onEdit: canManage
                          ? () async {
                              final container = ProviderScope.containerOf(context, listen: false);
                              final updated = await showLegacySubcontractorFormSheet(
                                context,
                                projectId: projectId,
                                currency: s.currency,
                                existing: s,
                              );
                              if (updated != null) {
                                invalidateProjectLedger(container.invalidate, projectId);
                                if (context.mounted) {
                                  ScaffoldMessenger.of(
                                    context,
                                  ).showSnackBar(const SnackBar(content: Text('Taşeron güncellendi.')));
                                }
                              }
                            }
                          : null,
                      onPaymentTap: (p) => showLegacySubcontractorPaymentDetailSheet(
                        context,
                        projectId: projectId,
                        subcontractor: s,
                        payment: p,
                        canVoid: canManage,
                      ),
                      onAddPayment: canManage
                          ? () async {
                              final container = ProviderScope.containerOf(context, listen: false);
                              final created = await showLegacySubcontractorPaymentSheet(
                                context,
                                projectId: projectId,
                                subcontractor: s,
                              );
                              if (created != null) {
                                invalidateProjectLedger(container.invalidate, projectId);
                                if (context.mounted) {
                                  ScaffoldMessenger.of(
                                    context,
                                  ).showSnackBar(const SnackBar(content: Text('Ödeme kaydedildi.')));
                                }
                              }
                            }
                          : null,
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Tek legacy taşeron kartı: ad/firma/iş, durum, Sözleşme/Ödenen/Kalan
/// (sunucu değerleri), ödeme çubuğu ve iptal edilmemiş ödemeler.
class LegacySubcontractorCard extends StatelessWidget {
  const LegacySubcontractorCard({
    super.key,
    required this.subcontractor,
    required this.payments,
    this.onAddPayment,
    this.onEdit,
    this.onPaymentTap,
  });

  final LegacySubcontractor subcontractor;
  final List<LegacySubcontractorPayment> payments;
  final VoidCallback? onAddPayment;

  /// Yalnızca yönetme yetkisi + açık projede verilir.
  final VoidCallback? onEdit;
  final ValueChanged<LegacySubcontractorPayment>? onPaymentTap;

  @override
  Widget build(BuildContext context) {
    final s = subcontractor;
    final paidPct = s.contractAmount <= 0 ? 0.0 : (s.paidAmount / s.contractAmount * 100);
    return AppCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.name, style: AppTypography.cardTitle, maxLines: 2, overflow: TextOverflow.ellipsis),
                    if (s.companyName.isNotEmpty)
                      Text(s.companyName, style: AppTypography.metadata, maxLines: 1, overflow: TextOverflow.ellipsis),
                    if (s.workDescription.isNotEmpty)
                      Text(
                        s.workDescription,
                        style: AppTypography.helper,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              StatusRegistry.build(s.status, kLegacySubcontractorStatus),
              if (onEdit != null)
                IconButton(
                  key: ValueKey('legacy-subcontractor-edit-${s.id}'),
                  tooltip: 'Taşeronu Düzenle',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.edit_outlined, size: 18, color: AppColors.textMuted),
                  onPressed: onEdit,
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: _Figure(
                  label: 'Sözleşme',
                  value: Formatters.money(s.contractAmount, currency: s.currency),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: _Figure(
                  label: 'Ödenen',
                  value: Formatters.money(s.paidAmount, currency: s.currency),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: _Figure(
                  label: 'Kalan',
                  value: Formatters.money(s.remainingAmount, currency: s.currency),
                  emphasize: true,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          AppProgressBar(
            pct: paidPct,
            color: paidPct >= 100 ? AppColors.success : AppColors.info,
            semanticsLabel: 'Ödenen oran',
          ),
          if (payments.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            const Divider(),
            const SizedBox(height: AppSpacing.xs),
            for (final p in payments)
              InkWell(
                key: ValueKey('legacy-payment-${p.id}'),
                onTap: onPaymentTap == null ? null : () => onPaymentTap!(p),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    [
                      Formatters.date(p.paidDate),
                      Formatters.money(p.amount, currency: p.currency),
                      if (p.description.isNotEmpty) p.description,
                    ].join(' · '),
                    style: AppTypography.metadata,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
          ],
          if (onAddPayment != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Ödeme Ekle'),
                onPressed: onAddPayment,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({required this.label, required this.value, this.emphasize = false});

  final String label;
  final String value;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label.toUpperCase(), style: AppTypography.overline),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            style: AppTypography.body.copyWith(fontWeight: emphasize ? FontWeight.w700 : FontWeight.w500),
          ),
        ),
      ],
    );
  }
}

String _isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// "1.250,50", "1250,5", "1250.5" -- finans planıyla aynı ayrıştırıcı.
double? _parseAmount(String? v) => parseAmountInput(v ?? '');

/// "Taşeron Ekle" (web formu: ad*, firma, yapılan iş, sözleşme bedeli*);
/// [existing] verilirse aynı alanlarla düzenleme (`PUT /subcontractors/{id}`).
Future<LegacySubcontractor?> showLegacySubcontractorFormSheet(
  BuildContext context, {
  required String projectId,
  required String currency,
  LegacySubcontractor? existing,
}) {
  return showModalBottomSheet<LegacySubcontractor>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    // Kayıt sürerken sayfa kapanamaz (UnsavedChangesScope + sürükleme kapalı):
    // aksi halde kayıt oluşur ama liste tazelenmez ve kullanıcı tekrar
    // eklerdi (taşeron oluşturma ucunda idempotency anahtarı yok).
    enableDrag: false,
    builder: (_) => _SubcontractorFormSheet(projectId: projectId, currency: currency, existing: existing),
  );
}

class _SubcontractorFormSheet extends ConsumerStatefulWidget {
  const _SubcontractorFormSheet({required this.projectId, required this.currency, this.existing});

  final String projectId;
  final String currency;
  final LegacySubcontractor? existing;

  @override
  ConsumerState<_SubcontractorFormSheet> createState() => _SubcontractorFormSheetState();
}

class _SubcontractorFormSheetState extends ConsumerState<_SubcontractorFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _company = TextEditingController(text: widget.existing?.companyName ?? '');
  late final _work = TextEditingController(text: widget.existing?.workDescription ?? '');
  late final _amount = TextEditingController(text: formatTrDecimalInput(widget.existing?.contractAmount));
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _company.dispose();
    _work.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = ref.read(financeLedgerRepositoryProvider);
      final existing = widget.existing;
      final saved = existing == null
          ? await repo.createSubcontractor(
              widget.projectId,
              name: _name.text.trim(),
              companyName: _company.text.trim(),
              workDescription: _work.text.trim(),
              contractAmount: _parseAmount(_amount.text)!,
              currency: widget.currency,
            )
          : await repo.updateSubcontractor(
              widget.projectId,
              existing,
              name: _name.text.trim(),
              companyName: _company.text.trim(),
              workDescription: _work.text.trim(),
              contractAmount: _parseAmount(_amount.text)!,
            );
      if (mounted) Navigator.of(context).pop(saved);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.isForbidden ? 'Bu işlem için yetkin yok.' : e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.existing;
    return _SheetFrame(
      title: existing == null ? 'Taşeron Ekle' : 'Taşeronu Düzenle',
      formKey: _formKey,
      error: _error,
      busy: _busy,
      submitLabel: existing == null ? 'Taşeron Ekle' : 'Kaydet',
      onSubmit: _submit,
      children: [
        AppFormSection(
          title: 'Taşeron Bilgileri',
          children: [
            TextFormField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Taşeron adı'),
              validator: (v) => (v ?? '').trim().isEmpty ? 'Taşeron adı gerekli' : null,
            ),
            TextFormField(
              controller: _company,
              decoration: const InputDecoration(labelText: 'Firma (opsiyonel)'),
            ),
            TextFormField(
              controller: _work,
              decoration: const InputDecoration(labelText: 'Yapılan iş (opsiyonel)'),
            ),
            TextFormField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Sözleşme bedeli (${widget.currency})',
                helperText: existing == null || existing.paidAmount <= 0
                    ? null
                    : 'Ödenen ${Formatters.money(existing.paidAmount, currency: existing.currency)}',
              ),
              validator: (v) {
                final parsed = _parseAmount(v);
                if (parsed == null || parsed <= 0) return 'Geçerli bir tutar gir';
                // Bedel, yapılmış ödemelerin altına inerse "Kalan" eksiye
                // düşerdi; fazla ödeme önce iptal edilmeli. Kuruş payı 0,005.
                if (existing != null && parsed < existing.paidAmount - 0.005) {
                  return 'Sözleşme bedeli ödenen tutarın '
                      '(${Formatters.money(existing.paidAmount, currency: existing.currency)}) altına indirilemez.';
                }
                return null;
              },
            ),
          ],
        ),
      ],
    );
  }
}

/// "Ödeme Ekle" -- tutar*, tarih*, açıklama. İdempotency anahtarı TAŞERON
/// ve form örneği başına sabittir (web: yanıtı kaybolan A ödemesinin
/// anahtarı B'ye gitmesin).
Future<LegacySubcontractorPayment?> showLegacySubcontractorPaymentSheet(
  BuildContext context, {
  required String projectId,
  required LegacySubcontractor subcontractor,
}) {
  return showModalBottomSheet<LegacySubcontractorPayment>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    // Kayıt sürerken sayfa kapanamaz (UnsavedChangesScope + sürükleme kapalı):
    // aksi halde kayıt oluşur ama liste tazelenmez ve kullanıcı tekrar
    // eklerdi (taşeron oluşturma ucunda idempotency anahtarı yok).
    enableDrag: false,
    builder: (_) => _PaymentSheet(projectId: projectId, subcontractor: subcontractor),
  );
}

class _PaymentSheet extends ConsumerStatefulWidget {
  const _PaymentSheet({required this.projectId, required this.subcontractor});

  final String projectId;
  final LegacySubcontractor subcontractor;

  @override
  ConsumerState<_PaymentSheet> createState() => _PaymentSheetState();
}

class _PaymentSheetState extends ConsumerState<_PaymentSheet> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _description = TextEditingController();
  DateTime _date = clock.now();
  bool _busy = false;
  String? _error;
  late final _idempotencyKey = 'subpay-${widget.subcontractor.id}-${DateTime.now().microsecondsSinceEpoch}';

  @override
  void dispose() {
    _amount.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final created = await ref
          .read(financeLedgerRepositoryProvider)
          .createSubcontractorPayment(
            widget.projectId,
            widget.subcontractor.id,
            amount: _parseAmount(_amount.text)!,
            currency: widget.subcontractor.currency,
            paidDate: _isoDate(_date),
            description: _description.text.trim(),
            idempotencyKey: _idempotencyKey,
          );
      if (mounted) Navigator.of(context).pop(created);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.isForbidden ? 'Bu işlem için yetkin yok.' : e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.subcontractor;
    return _SheetFrame(
      title: 'Ödeme Ekle',
      subtitle: '${s.name} · kalan ${Formatters.money(s.remainingAmount, currency: s.currency)}',
      formKey: _formKey,
      error: _error,
      busy: _busy,
      submitLabel: 'Ödeme Kaydet',
      onSubmit: _submit,
      children: [
        AppFormSection(
          title: 'Ödeme Bilgileri',
          children: [
            TextFormField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Tutar (${s.currency})',
                // Sunucu da zorlar (toplam ödeme sözleşme bedelini aşamaz);
                // burada girmeden önce görünsün.
                helperText: 'Sözleşme ${Formatters.money(s.contractAmount, currency: s.currency)} · '
                    'ödenen ${Formatters.money(s.paidAmount, currency: s.currency)} · '
                    'en fazla ${Formatters.money(s.remainingAmount > 0 ? s.remainingAmount : 0, currency: s.currency)}',
                helperMaxLines: 2,
              ),
              validator: (v) {
                final parsed = _parseAmount(v);
                if (parsed == null || parsed <= 0) return 'Geçerli bir tutar gir';
                // Kuruş yuvarlamasıyla sınırda yanlış ret olmasın diye 0,005 pay.
                if (parsed > s.remainingAmount + 0.005) {
                  return 'Sözleşme bedeli aşılamaz: en fazla '
                      '${Formatters.money(s.remainingAmount > 0 ? s.remainingAmount : 0, currency: s.currency)} ödenebilir.';
                }
                return null;
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Tarih'),
              subtitle: Text(Formatters.date(_isoDate(_date))),
              trailing: const Icon(Icons.calendar_today_outlined, size: 18),
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _date,
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2100),
                );
                if (picked != null) setState(() => _date = picked);
              },
            ),
            TextFormField(
              controller: _description,
              decoration: const InputDecoration(labelText: 'Açıklama (opsiyonel)'),
            ),
          ],
        ),
      ],
    );
  }
}

class _SheetFrame extends StatelessWidget {
  const _SheetFrame({
    required this.title,
    required this.formKey,
    required this.error,
    required this.busy,
    required this.submitLabel,
    required this.onSubmit,
    required this.children,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final GlobalKey<FormState> formKey;
  final String? error;
  final bool busy;
  final String submitLabel;
  final VoidCallback onSubmit;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return UnsavedChangesScope(
      busy: busy,
      child: Padding(
        padding: EdgeInsets.only(
          left: AppSpacing.xl,
          right: AppSpacing.xl,
          top: AppSpacing.xl,
          bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.xl,
        ),
        child: Form(
          key: formKey,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: AppTypography.pageTitle.copyWith(fontSize: 17)),
                if (subtitle != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(subtitle!, style: AppTypography.metadata),
                ],
                const SizedBox(height: AppSpacing.lg),
                ...children,
                if (error != null) ...[Text(error!, style: AppTypography.error), const SizedBox(height: AppSpacing.md)],
                PrimaryButton(label: submitLabel, loading: busy, onPressed: onSubmit),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
