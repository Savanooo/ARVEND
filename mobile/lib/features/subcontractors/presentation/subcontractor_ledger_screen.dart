import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/access_notices.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_form_section.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/app_section_header.dart';
import '../../../core/widgets/app_sheet.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/unsaved_changes_scope.dart';
import '../../projects/finance_ledger/data/finance_ledger_providers.dart';
import '../../projects/finance_plan/domain/finance_dates.dart' show parseAmountInput;
import '../data/subcontractors_repository.dart';
import '../domain/subcontractor.dart';

const _kFinanceRead = 'projects.finance.read';
const _kFinanceManage = 'projects.finance.manage';

/// Taşeronun sayfası (backend GET /subcontractors/{id}/ledger): kart
/// bilgisi, ödenen toplam, projelerdeki işleri (sözleşme / ödenen / kalan)
/// ve bütün ödemeleri -- projeli ve proje dışı, iptaller dahil. "Ödeme Yap"
/// (projects.finance.manage) proje dışı ödemeyi ya da projedeki işine
/// ödemeyi aynı yerden girer.
class SubcontractorLedgerScreen extends ConsumerWidget {
  const SubcontractorLedgerScreen({super.key, required this.subcontractorId});

  final String subcontractorId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final user = auth.valueOrNull;
    if (auth.isLoading && user == null) {
      return const AppPageScaffold(title: Text('Taşeron'), body: LoadingState());
    }
    if (!user.canAccess(_kFinanceRead)) {
      return const AppPageScaffold(
        title: Text('Taşeron'),
        body: Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: ReadOnlyNotice('Taşeronun ödemelerini görmek için finans yetkisi gerekir.'),
        ),
      );
    }
    final async = ref.watch(subcontractorLedgerProvider(subcontractorId));
    final canPay = user.canAccess(_kFinanceManage);
    final ledger = async.valueOrNull;

    Future<void> refresh() async {
      ref.invalidate(subcontractorLedgerProvider(subcontractorId));
      ref.invalidate(subcontractorCardsProvider);
      try {
        await ref.read(subcontractorLedgerProvider(subcontractorId).future);
      } catch (_) {
        // Hata ekranda gösterilir (AsyncStateView); ilk yükleme de başarısız
        // olduysa önceki kopya yoktur.
      }
    }

    return AppPageScaffold(
      title: Text(ledger?.card.legalName ?? 'Taşeron'),
      floatingActionButton: canPay && ledger != null && ledger.card.isActive
          ? FloatingActionButton.extended(
              key: const ValueKey('taseron-odeme-yap'),
              onPressed: () async {
                final paid = await showSubcontractorPaymentSheet(context, ledger: ledger);
                if (paid == true) await refresh();
              },
              icon: const Icon(Icons.payments_outlined),
              label: const Text('Ödeme Yap'),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: refresh,
        child: AsyncStateView<SubcontractorLedger>(
          value: async,
          onRetry: refresh,
          data: (context, l) => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 96),
            children: [
              _HeaderCard(ledger: l),
              const SizedBox(height: AppSpacing.lg),
              const AppSectionHeader(title: 'Projelerdeki İşleri'),
              if (l.engagements.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
                  child: Text('Henüz bir projede çalışmadı.', style: AppTypography.helper),
                )
              else
                for (final e in l.engagements) _EngagementRow(engagement: e),
              const SizedBox(height: AppSpacing.lg),
              const AppSectionHeader(title: 'Ödemeler'),
              if (l.payments.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
                  child: Text('Henüz ödeme yok.', style: AppTypography.helper),
                )
              else
                for (final p in l.payments)
                  _PaymentRow(
                    key: ValueKey('taseron-odeme-${p.id}'),
                    payment: p,
                    onVoid: canPay && p.isDirect && !p.isVoided
                        ? () async {
                            if (await _confirmVoid(context, ref, subcontractorId, p)) await refresh();
                          }
                        : null,
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<bool> _confirmVoid(BuildContext context, WidgetRef ref, String subcontractorId, SubcontractorLedgerPayment p) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Ödemeyi İptal Et'),
      content: Text(
        '${Formatters.date(p.paidDate)} tarihli ${Formatters.money(p.amount, currency: p.currency)} proje dışı ödeme '
        'iptal edilsin mi? Kayıt silinmez, toplamdan düşer.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Vazgeç')),
        TextButton(
          key: const ValueKey('taseron-odeme-iptal-onay'),
          onPressed: () => Navigator.of(context).pop(true),
          style: TextButton.styleFrom(foregroundColor: AppColors.danger),
          child: const Text('İptal Et'),
        ),
      ],
    ),
  );
  if (ok != true) return false;
  try {
    await ref.read(subcontractorsRepositoryProvider).voidDirectPayment(subcontractorId, p.id);
    return true;
  } on ApiException catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    return false;
  }
}

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({required this.ledger});

  final SubcontractorLedger ledger;

  @override
  Widget build(BuildContext context) {
    final c = ledger.card;
    final info = [c.specialty, c.phone, c.tradeName, if (c.ibanSet) 'IBAN kayıtlı'].where((v) => v.isNotEmpty).join(' · ');
    final paid = ledger.paidTotals.map((t) => Formatters.money(t.amount, currency: t.currency)).join(' + ');
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (info.isNotEmpty) Text(info, style: AppTypography.metadata),
          if (!c.isActive) ...[
            const SizedBox(height: AppSpacing.xs),
            const Text('Arşivde -- yeni ödeme girilemez.', style: AppTypography.helper),
          ],
          const SizedBox(height: AppSpacing.sm),
          const Text('Toplam ödenen', style: AppTypography.helper),
          Text(
            paid.isEmpty ? Formatters.money(0) : paid,
            key: const ValueKey('taseron-toplam-odenen'),
            style: AppTypography.pageTitle,
          ),
        ],
      ),
    );
  }
}

class _EngagementRow extends StatelessWidget {
  const _EngagementRow({required this.engagement});

  final SubcontractorEngagement engagement;

  @override
  Widget build(BuildContext context) {
    final e = engagement;
    final route = e.isSimple
        ? '/projeler/${Uri.encodeComponent(e.projectId)}?grup=finans&alt=taseron-odemeleri'
        : '/projeler/${Uri.encodeComponent(e.projectId)}/taseronlar/${Uri.encodeComponent(e.id)}';
    return AppCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      onTap: () => context.push(route),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(e.projectLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppTypography.cardTitle),
          if (e.title.isNotEmpty)
            Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppTypography.metadata),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Sözleşme ${Formatters.money(e.contractAmount, currency: e.currency)} · '
            'Ödenen ${Formatters.money(e.paidAmount, currency: e.currency)} · '
            'Kalan ${Formatters.money(e.remainingAmount, currency: e.currency)}',
            style: AppTypography.metadata,
          ),
        ],
      ),
    );
  }
}

class _PaymentRow extends StatelessWidget {
  const _PaymentRow({super.key, required this.payment, this.onVoid});

  final SubcontractorLedgerPayment payment;
  final VoidCallback? onVoid;

  @override
  Widget build(BuildContext context) {
    final p = payment;
    final details = [
      p.projectLabel,
      Formatters.date(p.paidDate),
      if (p.description.isNotEmpty) p.description,
      if (p.isVoided) 'İptal edildi${p.voidReason.isEmpty ? '' : ': ${p.voidReason}'}',
    ].join(' · ');
    return Opacity(
      opacity: p.isVoided ? 0.6 : 1,
      child: AppCard(
        margin: const EdgeInsets.only(bottom: AppSpacing.sm),
        padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.xs, AppSpacing.sm),
        child: Row(
          children: [
            Expanded(child: Text(details, maxLines: 3, overflow: TextOverflow.ellipsis, style: AppTypography.metadata)),
            Text(
              Formatters.money(p.amount, currency: p.currency),
              style: AppTypography.body.copyWith(
                fontWeight: FontWeight.w700,
                decoration: p.isVoided ? TextDecoration.lineThrough : null,
              ),
            ),
            if (onVoid != null)
              IconButton(
                key: ValueKey('taseron-odeme-iptal-${p.id}'),
                tooltip: 'İptal et',
                icon: const Icon(Icons.more_vert, size: 18),
                onPressed: onVoid,
              )
            else
              const SizedBox(width: AppSpacing.sm),
          ],
        ),
      ),
    );
  }
}

/// "Ödeme Yap": nereye (proje dışı ya da projedeki basit taşeron işi),
/// tutar, tarih, açıklama. Sözleşmeli taşeronluğun ödemesi kendi
/// sözleşme sayfasından (hakedişe bağlı) girilir. true = ödeme girildi.
Future<bool?> showSubcontractorPaymentSheet(BuildContext context, {required SubcontractorLedger ledger}) {
  return showAppSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _PaymentSheet(ledger: ledger),
  );
}

class _PaymentSheet extends ConsumerStatefulWidget {
  const _PaymentSheet({required this.ledger});

  final SubcontractorLedger ledger;

  @override
  ConsumerState<_PaymentSheet> createState() => _PaymentSheetState();
}

class _PaymentSheetState extends ConsumerState<_PaymentSheet> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _description = TextEditingController();
  DateTime _date = DateTime.now();

  /// null = proje dışı; dolu = projedeki basit taşeron işi.
  SubcontractorEngagement? _target;
  bool _busy = false;
  String? _error;
  final _idempotencyKey = 'tsr-${DateTime.now().microsecondsSinceEpoch}';

  List<SubcontractorEngagement> get _targets => widget.ledger.engagements
      .where((e) => e.isSimple && e.projectStatus != 'completed' && e.projectStatus != 'cancelled')
      .toList();

  String get _currency => _target?.currency ?? 'TRY';

  @override
  void dispose() {
    _amount.dispose();
    _description.dispose();
    super.dispose();
  }

  String get _isoDate =>
      '${_date.year.toString().padLeft(4, '0')}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}';

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final amount = parseAmountInput(_amount.text)!;
    try {
      final target = _target;
      if (target == null) {
        await ref.read(subcontractorsRepositoryProvider).createDirectPayment(
              widget.ledger.card.id,
              amount: amount,
              paidDate: _isoDate,
              description: _description.text.trim(),
              idempotencyKey: _idempotencyKey,
            );
      } else {
        await ref.read(financeLedgerRepositoryProvider).createSubcontractorPayment(
              target.projectId,
              target.id,
              amount: amount,
              currency: target.currency,
              paidDate: _isoDate,
              description: _description.text.trim(),
              idempotencyKey: _idempotencyKey,
            );
        invalidateProjectLedger(ref.invalidate, target.projectId);
      }
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      Navigator.of(context).pop(true);
      messenger?.showSnackBar(const SnackBar(content: Text('Ödeme kaydedildi.')));
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.isForbidden ? 'Ödeme girmek için yetkin yok.' : e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final target = _target;
    return UnsavedChangesScope(
      busy: _busy,
      child: Padding(
        padding: EdgeInsets.only(
          left: AppSpacing.xl,
          right: AppSpacing.xl,
          top: AppSpacing.xl,
          bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.xl,
        ),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${widget.ledger.card.legalName} · Ödeme',
                  style: AppTypography.pageTitle.copyWith(fontSize: 17),
                ),
                const SizedBox(height: AppSpacing.lg),
                AppFormSection(
                  title: 'Ödeme',
                  children: [
                    DropdownButtonFormField<String>(
                      key: const ValueKey('taseron-odeme-hedef'),
                      initialValue: target?.id ?? '',
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Nereye'),
                      items: [
                        const DropdownMenuItem(value: '', child: Text('Proje dışı iş')),
                        for (final e in _targets)
                          DropdownMenuItem(
                            value: e.id,
                            child: Text(
                              '${e.projectLabel}${e.title.isEmpty ? '' : ' · ${e.title}'}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (v) => setState(() => _target = (v == null || v.isEmpty)
                          ? null
                          : _targets.firstWhere((e) => e.id == v)),
                    ),
                    if (target != null)
                      Text(
                        'Kalan: ${Formatters.money(target.remainingAmount, currency: target.currency)}',
                        style: AppTypography.helper,
                      ),
                    TextFormField(
                      key: const ValueKey('taseron-odeme-tutar'),
                      controller: _amount,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(labelText: 'Tutar ($_currency)'),
                      validator: (v) {
                        final parsed = parseAmountInput(v ?? '');
                        if (parsed == null || parsed <= 0) return 'Geçerli bir tutar gir';
                        return null;
                      },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Ödeme tarihi'),
                      subtitle: Text(Formatters.date(_isoDate)),
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
                      key: const ValueKey('taseron-odeme-aciklama'),
                      controller: _description,
                      maxLength: 500,
                      decoration: const InputDecoration(labelText: 'Açıklama (opsiyonel)', counterText: ''),
                    ),
                  ],
                ),
                if (widget.ledger.engagements.any((e) => !e.isSimple))
                  const Padding(
                    padding: EdgeInsets.only(bottom: AppSpacing.md),
                    child: Text(
                      'Sözleşmeli taşeronluk ödemeleri hakedişle, projenin Taşeronlar sayfasından girilir.',
                      style: AppTypography.helper,
                    ),
                  ),
                if (_error != null) ...[
                  Text(_error!, style: AppTypography.error),
                  const SizedBox(height: AppSpacing.md),
                ],
                PrimaryButton(
                  key: const ValueKey('taseron-odeme-kaydet'),
                  label: 'Ödemeyi Kaydet',
                  loading: _busy,
                  onPressed: _submit,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
