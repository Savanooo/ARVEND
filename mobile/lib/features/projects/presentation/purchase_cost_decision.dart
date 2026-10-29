import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_status_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_sheet.dart';
import '../domain/procurement.dart';
import 'form_number_input.dart';

/// Satın almanın proje maliyeti kararı (backend migration 0078). Ürün
/// sahibi: satın alma talebi ONAYLANINCA maliyete girsin ve onaylarken
/// "proje maliyetine eklensin mi" diye sorulsun -- depo/stok ya da genel
/// kullanım için alınan malzeme projenin kârını düşürmemeli. Talep ve
/// sipariş onayı ile sonradan değiştirme aynı sayfayı kullanır.

/// Karar: [include] maliyete eklensin mi; [costEstimate] fiyatsız talepte
/// girilen tahmini tutar (null = girilmedi).
typedef PurchaseCostChoice = ({bool include, double? costEstimate});

/// Kararı soran alt sayfa. [amount] "maliyete eklenecek" tutar (talepte
/// tahmini, siparişte sipariş tutarı); [allowEstimate] ise tahmini tutar
/// alanı gösterilir (fiyatsız ya da eksik fiyatlı talep). Vazgeçilirse null.
Future<PurchaseCostChoice?> showPurchaseCostSheet(
  BuildContext context, {
  required String title,
  required double amount,
  required String currency,
  bool initialInclude = true,
  bool allowEstimate = false,
  double? initialEstimate,
  String warning = '',
  String? note,
  String confirmLabel = 'Onayla',
}) {
  return showAppSheet<PurchaseCostChoice>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => PurchaseCostSheet(
      title: title,
      amount: amount,
      currency: currency,
      initialInclude: initialInclude,
      allowEstimate: allowEstimate,
      initialEstimate: initialEstimate,
      warning: warning,
      note: note,
      confirmLabel: confirmLabel,
    ),
  );
}

class PurchaseCostSheet extends StatefulWidget {
  const PurchaseCostSheet({
    super.key,
    required this.title,
    required this.amount,
    required this.currency,
    this.initialInclude = true,
    this.allowEstimate = false,
    this.initialEstimate,
    this.warning = '',
    this.note,
    this.confirmLabel = 'Onayla',
  });

  final String title;
  final double amount;
  final String currency;
  final bool initialInclude;
  final bool allowEstimate;
  final double? initialEstimate;
  final String warning;
  final String? note;
  final String confirmLabel;

  @override
  State<PurchaseCostSheet> createState() => _PurchaseCostSheetState();
}

class _PurchaseCostSheetState extends State<PurchaseCostSheet> {
  late bool _include = widget.initialInclude;
  late final _estimate = TextEditingController(text: formNumberText(widget.initialEstimate));
  String? _estimateError;

  @override
  void initState() {
    super.initState();
    _estimate.addListener(() => setState(() => _estimateError = null));
  }

  @override
  void dispose() {
    _estimate.dispose();
    super.dispose();
  }

  /// Girilen tahmin (boşsa null). Geçersizse hata yazar.
  ({double? value, bool ok}) _parsedEstimate() {
    final raw = _estimate.text.trim();
    if (!widget.allowEstimate || raw.isEmpty) return (value: null, ok: true);
    final error = formNumberError(raw, allowZero: true, positiveMessage: 'Sıfır ya da pozitif olmalı');
    if (error != null) return (value: null, ok: false);
    return (value: parseFormNumber(raw), ok: true);
  }

  void _submit() {
    final est = _parsedEstimate();
    if (!est.ok) {
      setState(() => _estimateError = 'Geçerli bir tutar gir (ör. 2.500 ya da 2.500,50).');
      return;
    }
    Navigator.of(context).pop<PurchaseCostChoice>((include: _include, costEstimate: _include ? est.value : null));
  }

  @override
  Widget build(BuildContext context) {
    final est = _parsedEstimate();
    final shown = est.value ?? widget.amount;
    // Tahmin girilince fiyatsız uyarısı kalkar (maliyete artık o girer).
    final showWarning = widget.warning.isNotEmpty && _include && (est.value == null || est.value == 0);
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.xl,
        right: AppSpacing.xl,
        top: AppSpacing.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.xl,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.title, style: AppTypography.pageTitle.copyWith(fontSize: 17)),
            if (widget.note != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(widget.note!, style: AppTypography.helper),
            ],
            const SizedBox(height: AppSpacing.lg),
            const Text('Proje maliyetine eklensin mi?', style: AppTypography.sectionTitle),
            const SizedBox(height: AppSpacing.sm),
            _ChoiceTile(
              key: const Key('maliyet-evet'),
              selected: _include,
              title: 'Evet, maliyete ekle',
              subtitle: 'Maliyete eklenecek: ${Formatters.money(shown, currency: widget.currency)}',
              onTap: () => setState(() => _include = true),
            ),
            const SizedBox(height: AppSpacing.sm),
            _ChoiceTile(
              key: const Key('maliyet-hayir'),
              selected: !_include,
              title: 'Hayır (depo/stok ya da genel kullanım)',
              subtitle: 'Proje maliyetine ve kârına girmez',
              onTap: () => setState(() => _include = false),
            ),
            if (showWarning) ...[
              const SizedBox(height: AppSpacing.md),
              PurchaseCostWarning(text: widget.warning),
            ],
            if (widget.allowEstimate && _include) ...[
              const SizedBox(height: AppSpacing.md),
              TextField(
                key: const Key('maliyet-tahmin'),
                controller: _estimate,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'Tahmini tutar (KDV dahil, isteğe bağlı)',
                  helperText: 'Boş bırakılırsa kalemlerin toplamı girer.',
                  suffixText: widget.currency == 'TRY' ? 'TL' : widget.currency,
                  errorText: _estimateError,
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.xl),
            Row(
              children: [
                Expanded(
                  child: SecondaryButton(label: 'Vazgeç', onPressed: () => Navigator.of(context).pop()),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: PrimaryButton(
                    key: const Key('maliyet-onayla'),
                    label: widget.confirmLabel,
                    onPressed: _submit,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Seçilebilir karar satırı (radyo düğmesi görünümünde).
class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    super.key,
    required this.selected,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final bool selected;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.gold : AppColors.textMuted;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: selected ? AppColors.gold : AppColors.textMuted.withValues(alpha: 0.3)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked, color: color, size: 20),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: AppTypography.body.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(subtitle, style: AppTypography.metadata),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PurchaseCostWarning extends StatelessWidget {
  const PurchaseCostWarning({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.warning_amber_rounded, size: 18, color: AppStatusColors.warning),
        const SizedBox(width: AppSpacing.sm),
        Expanded(child: Text(text, style: AppTypography.body.copyWith(color: AppStatusColors.warning))),
      ],
    );
  }
}

/// Talep/sipariş detayındaki "Proje Maliyeti" kartı: "Maliyete eklendi: X"
/// ya da "Maliyete eklenmedi", neyin girdiği ve (izin varsa) "Değiştir".
/// [cost] eski sunucuda null: yalnızca karar gösterilir.
class PurchaseCostCard extends StatelessWidget {
  const PurchaseCostCard({
    super.key,
    required this.included,
    required this.cost,
    required this.currency,
    this.onChange,
  });

  final bool included;
  final PurchaseCost? cost;
  final String currency;

  /// null = değiştirilemez (izin yok ya da kayıt kapanmış).
  final VoidCallback? onChange;

  @override
  Widget build(BuildContext context) {
    final c = cost;
    final String headline;
    final Color tone;
    String detail = '';
    if (!included) {
      headline = 'Maliyete eklenmedi';
      tone = AppColors.textMuted;
      final potential = c?.potential ?? 0;
      detail = potential > 0
          ? 'Depo/stok ya da genel kullanım: ${Formatters.money(potential, currency: currency)} proje maliyetinin dışında.'
          : 'Depo/stok ya da genel kullanım: proje maliyetinin dışında.';
    } else if (c == null) {
      // Eski sunucu katkıyı göndermez: yalnızca karar bilinir.
      headline = 'Proje maliyetine eklenir';
      tone = AppStatusColors.success;
    } else if (c.counts) {
      headline = 'Maliyete eklendi: ${Formatters.money(c.amount, currency: currency)}';
      tone = AppStatusColors.success;
      detail = c.sourceLabel;
      if (c.source == kPurchaseCostSourceOrder && (c.invoicedAmount ?? 0) > 0) {
        detail = '$detail · faturalanan ${Formatters.money(c.invoicedAmount!, currency: currency)}';
      }
    } else {
      headline = 'Onaylanınca maliyete eklenecek: ${Formatters.money(c.potential, currency: currency)}';
      tone = AppColors.textMuted;
    }
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(included ? Icons.add_chart_outlined : Icons.block_outlined, size: 18, color: tone),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  headline,
                  key: const Key('maliyet-durum'),
                  style: AppTypography.body.copyWith(fontWeight: FontWeight.w600, color: tone),
                ),
              ),
              if (onChange != null)
                TextButton(key: const Key('maliyet-degistir'), onPressed: onChange, child: const Text('Değiştir')),
            ],
          ),
          if (detail.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(detail, style: AppTypography.helper),
          ],
          if (included && (c?.warning ?? '').isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            PurchaseCostWarning(text: c!.warning),
          ],
        ],
      ),
    );
  }
}
