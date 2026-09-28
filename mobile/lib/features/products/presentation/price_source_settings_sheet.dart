import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_buttons.dart';
import '../data/products_providers.dart';
import '../domain/price_format.dart';
import '../domain/price_source.dart';
import 'widgets/products_common.dart';

/// Kâr oranı ayarları (web PriceSourceCard modalı): varsayılan oran,
/// gece otomatik güncelleme ve kategoriye özel oranlar. PUT tam durumdur.
/// Kayıt sürerken sayfa kapatılamaz (sürükleme kapalı, geri tuşu engelli).
Future<PriceSourceUpdateResult?> showPriceSourceSettingsSheet(BuildContext context, PriceSource ps) {
  return showModalBottomSheet<PriceSourceUpdateResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    enableDrag: false,
    builder: (_) => PriceSourceSettingsSheet(priceSource: ps),
  );
}

class PriceSourceSettingsSheet extends ConsumerStatefulWidget {
  const PriceSourceSettingsSheet({super.key, required this.priceSource});
  final PriceSource priceSource;

  @override
  ConsumerState<PriceSourceSettingsSheet> createState() => _PriceSourceSettingsSheetState();
}

class _PriceSourceSettingsSheetState extends ConsumerState<PriceSourceSettingsSheet> {
  late final TextEditingController _markup;
  late bool _autoSync;
  late final List<CategoryMarkupRow> _baseRows;
  late final Map<String, TextEditingController> _rowControllers;
  bool _saving = false;
  String? _formError;
  String? _markupError;
  Map<String, String> _rowErrors = const {};

  PriceSource get ps => widget.priceSource;
  SourceLabels get labels => sourceLabels(ps.source, ps.name);

  @override
  void initState() {
    super.initState();
    _markup = TextEditingController(text: ps.markupPercent == null ? '' : formatMarkupInput(ps.markupPercent!));
    _markup.addListener(() => setState(() {}));
    _autoSync = ps.autoSync;
    _baseRows = categoryMarkupRows(ps);
    _rowControllers = {for (final r in _baseRows) r.category: TextEditingController(text: r.markup)};
  }

  @override
  void dispose() {
    _markup.dispose();
    for (final c in _rowControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final built = buildSettingsBody(
      markup: _markup.text,
      autoSync: _autoSync,
      rows: [
        for (final r in _baseRows)
          CategoryMarkupRow(category: r.category, productCount: r.productCount, markup: _rowControllers[r.category]!.text),
      ],
    );
    if (!built.ok) {
      setState(() {
        _markupError = built.markupError;
        _rowErrors = built.rowErrors;
        _formError = 'Lütfen işaretli alanları düzelt.';
      });
      return;
    }
    setState(() {
      _markupError = null;
      _rowErrors = const {};
      _formError = null;
      _saving = true;
    });
    try {
      final res = await ref.read(productsRepositoryProvider).updatePriceSource(ps.source, built.body!);
      if (mounted) Navigator.of(context).pop(res);
    } catch (e) {
      if (mounted) setState(() => _formError = productsActionError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = labels.short;
    final parsedDefault = parseMarkupInput(_markup.text);
    final example = parsedDefault.ok
        ? '${Formatters.money(kExampleSourcePrice)} $name fiyatı → '
              '${Formatters.money(applyMarkup(kExampleSourcePrice, parsedDefault.value!))} satış'
        : '—';
    final rowHint = parsedDefault.ok ? 'Varsayılan (${formatPricePercent(parsedDefault.value!)})' : 'Varsayılan';

    return PopScope(
      canPop: !_saving,
      child: Padding(
        padding: EdgeInsets.only(
          left: AppSpacing.xl,
          right: AppSpacing.xl,
          top: AppSpacing.xl,
          bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.xl,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('$name kâr oranı ayarları', style: AppTypography.pageTitle.copyWith(fontSize: 17)),
              const SizedBox(height: AppSpacing.lg),
              TextField(
                controller: _markup,
                enabled: !_saving,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'Varsayılan kâr oranı (%)',
                  hintText: 'ör. 15 veya 12,5',
                  errorText: _markupError,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text('ÖRNEK', style: AppTypography.overline),
              const SizedBox(height: 2),
              Text(example, style: AppTypography.body),
              const SizedBox(height: AppSpacing.sm),
              Text(
                '0 ile $kMaxMarkupPercent arasında, en fazla iki ondalık. Satış fiyatı = $name fiyatı × (1 + oran).',
                style: AppTypography.helper,
              ),
              if (ps.lastSyncedAt == null) ...[
                const SizedBox(height: AppSpacing.sm),
                ProductsNotice(
                  tone: NoticeTone.info,
                  text:
                      'Henüz başarılı bir $name güncellemesi yok, bu yüzden hiçbir ürünün $name fiyatı bilinmiyor. '
                      'Kaydettiğin oranlar şimdi hiçbir fiyatı değiştirmez; ilk "${labels.ablative} Güncelle" ile uygulanır.',
                ),
              ],
              const SizedBox(height: AppSpacing.sm),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _autoSync,
                onChanged: _saving ? null : (v) => setState(() => _autoSync = v),
                title: const Text("Her gece 00:05'te otomatik güncelle", style: AppTypography.body),
              ),
              const SizedBox(height: AppSpacing.sm),
              const Text('KATEGORİYE ÖZEL KÂR ORANLARI', style: AppTypography.overline),
              const SizedBox(height: 2),
              const Text('Boş bırakılan kategorilerde varsayılan oran kullanılır.', style: AppTypography.helper),
              const SizedBox(height: AppSpacing.sm),
              if (_baseRows.isEmpty)
                Text(
                  'Henüz $name kategorisi yok; kategoriler ilk güncellemeden sonra burada listelenir.',
                  style: AppTypography.metadata,
                )
              else
                for (final row in _baseRows)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(top: AppSpacing.sm),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(row.category, style: AppTypography.body),
                                Text(
                                  row.productCount == 0 ? 'Bu kategoride artık ürün yok' : '${row.productCount} ürün',
                                  style: AppTypography.helper,
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        SizedBox(
                          // "Varsayılan (%12,5)" ipucu kesilmeden sığsın.
                          width: 168,
                          // Ekran okuyucu için alanın hangi kategoriye ait olduğu.
                          child: Semantics(
                            label: '${row.category} kâr oranı',
                            child: TextField(
                              controller: _rowControllers[row.category],
                              enabled: !_saving,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              decoration: InputDecoration(
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                                hintText: rowHint,
                                hintStyle: AppTypography.helper,
                                errorText: _rowErrors[row.category],
                                errorMaxLines: 3,
                                suffixText: '%',
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              if (_formError != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(_formError!, style: AppTypography.error),
              ],
              const SizedBox(height: AppSpacing.lg),
              Row(
                children: [
                  Expanded(
                    child: SecondaryButton(
                      label: 'Vazgeç',
                      onPressed: _saving ? null : () => Navigator.of(context).pop(),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(child: PrimaryButton(label: 'Kaydet', loading: _saving, onPressed: _save)),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Oranlar yalnızca "Ürün kataloğunu düzenleme" izni olanlara görünür.',
                style: AppTypography.helper.copyWith(color: AppColors.textMuted),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
