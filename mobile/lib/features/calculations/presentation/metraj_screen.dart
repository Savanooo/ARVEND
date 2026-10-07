import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_shadows.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_data_row.dart';
import '../../../core/widgets/app_financial_summary.dart';
import '../../../core/widgets/app_form_section.dart';
import '../../../core/widgets/app_list_card.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/app_section_header.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/metric_card.dart';
import '../../../core/widgets/money_text.dart';
import '../data/calc_providers.dart';
import '../domain/calc.dart';

/// Metraj Hesaplama: Grup seç -> Kategori seç -> Ölçü gir -> Hesapla ->
/// Malzeme sonucu -> Teklife ekle. Motor mobilde YOK - yalnızca
/// POST /calculations/run çağrılır, backend'in döndürdüğü sonuç aynen
/// gösterilir (bkz. mobile/API_CONTRACT.md#calculations).
///
/// [pickMode]: "Diğer > Metraj Hesaplama" üzerinden bağımsız açıldığında
/// (varsayılan, false) "Teklife Ekle" her zaman YENİ bir teklif taslağına
/// gider (mevcut davranış, DEĞİŞMEDİ). `OfferCreateScreen` içinden
/// "Metrajdan Ekle" ile açıldığında (true) ekran, seçilen kalemleri
/// AÇIK olan teklif taslağına eklemek üzere `Navigator.pop` ile geri
/// döner -- bu, web'in aynı modalı teklif formunun İÇİNDE tuttuğu ve
/// birden çok bölüm (Salon/Oda 1/...) hesaplayıp AYNI teklife
/// ekleyebildiği akışın mobildeki karşılığıdır (bkz. web
/// MetrajHesaplaPanel.tsx handleAddFromMetraj).
class MetrajScreen extends ConsumerStatefulWidget {
  const MetrajScreen({super.key, this.pickMode = false});

  final bool pickMode;

  @override
  ConsumerState<MetrajScreen> createState() => _MetrajScreenState();
}

class _MetrajScreenState extends ConsumerState<MetrajScreen> {
  CalcGroupWithCategories? _group;
  CalcCategory? _category;
  bool _useAreaDirectly = true;
  final _areaController = TextEditingController();
  final _widthController = TextEditingController();
  final _heightController = TextEditingController();
  final _perimeterController = TextEditingController();
  final _pitchController = TextEditingController();

  CalcRunResult? _result;
  bool _calculating = false;
  String? _error;
  final Set<String> _selectedForOffer = {};

  @override
  void dispose() {
    _areaController.dispose();
    _widthController.dispose();
    _heightController.dispose();
    _perimeterController.dispose();
    _pitchController.dispose();
    super.dispose();
  }

  /// Yalnızca daha hızlı geri bildirim için -- gerçek sınır her zaman
  /// backend'de (bkz. calc.dart validatePositiveIfPresent yorumu).
  String? _validateInputs() {
    if (_useAreaDirectly) {
      final err = validatePositiveIfPresent(_areaController.text, 'Alan');
      if (err != null) return err;
    } else {
      final w = validatePositiveIfPresent(_widthController.text, 'En');
      if (w != null) return w;
      final h = validatePositiveIfPresent(_heightController.text, 'Boy');
      if (h != null) return h;
    }
    final p = validatePositiveIfPresent(_perimeterController.text, 'Çevre');
    if (p != null) return p;
    final pitch = validatePositiveIfPresent(_pitchController.text, 'Çatı Eğimi');
    if (pitch != null) return pitch;
    return null;
  }

  Future<void> _calculate() async {
    if (_category == null) return;
    final validationError = _validateInputs();
    if (validationError != null) {
      setState(() => _error = validationError);
      return;
    }
    setState(() {
      _calculating = true;
      _error = null;
    });
    try {
      final result = await ref.read(calcRepositoryProvider).run(
            categoryId: _category!.id,
            area: _useAreaDirectly ? _nonEmpty(_areaController.text) : null,
            width: _useAreaDirectly ? null : _nonEmpty(_widthController.text),
            height: _useAreaDirectly ? null : _nonEmpty(_heightController.text),
            perimeter: _nonEmpty(_perimeterController.text),
            pitchDeg: _nonEmpty(_pitchController.text),
          );
      setState(() {
        _result = result;
        _selectedForOffer
          ..clear()
          ..addAll(result.items.map((e) => e.recipeItemId));
      });
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _calculating = false);
    }
  }

  String? _nonEmpty(String v) => v.trim().isEmpty ? null : v.trim().replaceAll(',', '.');

  void _addToOffer() {
    final result = _result;
    if (result == null) return;
    final items = buildOfferItemsFromCalcResult(result, _selectedForOffer);
    if (items.isEmpty) return;
    if (widget.pickMode) {
      Navigator.of(context).pop(items);
    } else {
      context.push('/teklifler/yeni', extra: items);
    }
  }

  @override
  Widget build(BuildContext context) {
    final catalogAsync = ref.watch(calcCatalogProvider);
    // `pickMode`de "Teklife Ekle" YENİ bir teklif OLUŞTURMAZ -- yalnızca
    // seçili kalemleri çağıran ekrana (ör. zaten var olan bir teklifi
    // düzenleyen OfferCreateScreen) geri döndürür, bu yüzden `offers.create`
    // GEREKMEZ (çağıranın kendi izni -- update/create -- zaten geçerlidir).
    // Yalnızca bağımsız açıldığında (`/teklifler/yeni`'ye YENİ taslak
    // oluşturarak gittiğinde) bu izin gerçekten gerekir.
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canCreateOffer = user == null || user.permissions.isEmpty || user.hasPermission('offers.create');
    final canAddToOffer = widget.pickMode || canCreateOffer;

    return AppPageScaffold(
      title: const Text('Metraj Hesaplama'),
      body: Column(
        children: [
          Expanded(
            child: AsyncStateView(
              value: catalogAsync,
              onRetry: () async => ref.invalidate(calcCatalogProvider),
              data: (context, groups) => ListView(
                padding: const EdgeInsets.all(AppSpacing.lg),
                children: [
                  AppFormSection(
                    title: 'Hesaplama Türü',
                    subtitle: 'Grup ve kategori seçin',
                    children: [
                      DropdownButtonFormField<CalcGroupWithCategories>(
                        initialValue: _group,
                        decoration: const InputDecoration(labelText: 'Grup'),
                        items: groups.map((g) => DropdownMenuItem(value: g, child: Text(g.name))).toList(),
                        onChanged: (g) => setState(() {
                          _group = g;
                          _category = null;
                          _result = null;
                        }),
                      ),
                      if (_group != null) ...[
                        Text('Kategori', style: AppTypography.metadata),
                        for (final c in _group!.categories)
                          _CategoryTile(
                            category: c,
                            selected: _category?.id == c.id,
                            onTap: () => setState(() {
                              _category = c;
                              _result = null;
                            }),
                          ),
                      ],
                    ],
                  ),
                  if (_category != null)
                    AppFormSection(
                      title: 'Ölçüler',
                      subtitle: _category!.name,
                      children: [
                        SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment(value: true, label: Text('Doğrudan Alan')),
                            ButtonSegment(value: false, label: Text('En × Boy')),
                          ],
                          selected: {_useAreaDirectly},
                          onSelectionChanged: (s) => setState(() => _useAreaDirectly = s.first),
                        ),
                        if (_useAreaDirectly)
                          TextField(
                            controller: _areaController,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: const InputDecoration(labelText: 'Alan (m²)'),
                          )
                        else
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _widthController,
                                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                  decoration: const InputDecoration(labelText: 'En (m)'),
                                ),
                              ),
                              const SizedBox(width: AppSpacing.md),
                              Expanded(
                                child: TextField(
                                  controller: _heightController,
                                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                  decoration: const InputDecoration(labelText: 'Boy (m)'),
                                ),
                              ),
                            ],
                          ),
                        TextField(
                          controller: _perimeterController,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(
                            labelText: 'Çevre (m) — opsiyonel',
                            helperText: 'Boş bırakılırsa En×Boy\'dan hesaplanır (yalnızca En×Boy modunda)',
                          ),
                        ),
                        if (_group?.looksLikeRoof ?? false)
                          TextField(
                            controller: _pitchController,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: const InputDecoration(labelText: 'Çatı Eğimi (derece) — opsiyonel'),
                          ),
                        PrimaryButton(
                          label: 'Hesapla',
                          icon: Icons.calculate_outlined,
                          loading: _calculating,
                          onPressed: _calculate,
                        ),
                        if (_error != null) Text(_error!, style: AppTypography.error),
                      ],
                    ),
                  if (_result != null)
                    _ResultSection(
                      result: _result!,
                      selected: _selectedForOffer,
                      onToggle: (id, v) => setState(() {
                        if (v) {
                          _selectedForOffer.add(id);
                        } else {
                          _selectedForOffer.remove(id);
                        }
                      }),
                    ),
                ],
              ),
            ),
          ),
          if (_result != null && canAddToOffer)
            _StickyAddToOfferBar(count: _selectedForOffer.length, onAdd: _addToOffer),
        ],
      ),
    );
  }
}

/// Bir hesaplama kategorisi seçim kartı -- ad + (varsa) açıklama tek
/// bakışta görünür (bkz. ürün brifingi "Category selection — use clear
/// names and descriptions"). Seçili durum marka rengiyle (gold) vurgulanır
/// -- bkz. AppColors "Gold yalnızca vurgu/CTA/seçili durumda kullanılır".
class _CategoryTile extends StatelessWidget {
  const _CategoryTile({required this.category, required this.selected, required this.onTap});

  final CalcCategory category;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onTap,
      color: selected ? AppColors.gold.withValues(alpha: 0.06) : null,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  category.name,
                  style: AppTypography.cardTitle.copyWith(color: selected ? AppColors.gold : null),
                ),
                if (category.description.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    category.description,
                    style: AppTypography.metadata,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Icon(
            selected ? Icons.check_circle : Icons.radio_button_unchecked,
            color: selected ? AppColors.gold : AppColors.border,
            size: 22,
          ),
        ],
      ),
    );
  }
}

class _ResultSection extends StatelessWidget {
  const _ResultSection({
    required this.result,
    required this.selected,
    required this.onToggle,
  });

  final CalcRunResult result;
  final Set<String> selected;
  final void Function(String id, bool value) onToggle;

  @override
  Widget build(BuildContext context) {
    final warnings = nonPriceWarnings(result);
    final priceSummary = calcPriceSummary(result.items);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.xl),
        const AppSectionHeader(title: 'Sonuç'),
        const SizedBox(height: 2),
        Text(result.categoryName, style: AppTypography.metadata),
        const SizedBox(height: AppSpacing.sm),
        AppFinancialSummary(
          headline: Row(
            children: [
              Expanded(
                child: MetricCard(
                  icon: Icons.square_foot_outlined,
                  label: 'Etkin Alan',
                  value: '${Formatters.quantityFromString(result.effectiveArea)} m²',
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: MetricCard(
                  icon: Icons.payments_outlined,
                  label: 'Toplam Maliyet',
                  value: Formatters.moneyFromString(result.totalCost),
                ),
              ),
            ],
          ),
          rows: [
            // footprint_area (eğim uygulanmadan önceki taban alan) yalnızca
            // eğim (pitch) etkin alanı DEĞİŞTİRDİĞİNDE ayrıca gösterilir --
            // aksi halde ikisi zaten aynı, tekrar gürültü olur (bkz. backend
            // ComputeGeometry: pitch yoksa effective_area == footprint_area).
            if (result.footprintArea != result.effectiveArea)
              AppDataRow(
                label: 'Taban Alan (eğim öncesi)',
                value: '${Formatters.quantityFromString(result.footprintArea)} m²',
              ),
            if (result.perimeter != null)
              AppDataRow(label: 'Çevre', value: '${Formatters.quantityFromString(result.perimeter!)} m'),
          ],
        ),
        if (priceSummary != null || warnings.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          // Fiyat uyarıları tek notta özetlenir, satırlar ayrıca işaretlenir
          // (yeni firmada her satır için ayrı kutu listeyi boğuyordu).
          if (priceSummary != null)
            _WarningBox(key: const ValueKey('metraj-price-summary'), message: priceSummary),
          for (final w in warnings) _WarningBox(message: w.message),
        ],
        const SizedBox(height: AppSpacing.lg),
        const AppSectionHeader(title: 'Malzeme Listesi'),
        const SizedBox(height: AppSpacing.sm),
        ..._buildItemRows(),
      ],
    );
  }

  /// Malzeme grubu (`group_name`, ör. "Ana Malzemeler"/"Aksesuar") başlığı,
  /// yalnızca bir önceki kalemden FARKLI ve boş olmayan bir grup adına
  /// geçildiğinde eklenir -- backend'in döndürdüğü sırayı yeniden
  /// SIRALAMAZ, yalnızca zaten ardışık gelen aynı gruptaki kalemleri
  /// görsel olarak ayırır.
  List<Widget> _buildItemRows() {
    final widgets = <Widget>[];
    String? lastGroup;
    for (final item in result.items) {
      final group = item.groupName;
      if (group != null && group.isNotEmpty && group != lastGroup) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.xs),
          child: AppSectionHeader(title: group),
        ));
      }
      lastGroup = group;
      final isSelected = selected.contains(item.recipeItemId);
      widgets.add(AppListCard(
        margin: const EdgeInsets.only(bottom: AppSpacing.sm),
        onTap: () => onToggle(item.recipeItemId, !isSelected),
        leading: Checkbox(
          value: isSelected,
          onChanged: (v) => onToggle(item.recipeItemId, v ?? false),
        ),
        title: item.materialName,
        subtitle: '${Formatters.quantityFromString(item.quantity)} ${item.unit} × '
            '${Formatters.moneyFromString(item.unitPrice)}',
        trailing: _lineTotalText(item.lineTotal),
        footer: item.hasPriceWarning ? _PriceWarningLine(item: item) : null,
      ));
    }
    return widgets;
  }
}

class _WarningBox extends StatelessWidget {
  const _WarningBox({super.key, required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, color: AppColors.warning, size: 18),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(message, style: AppTypography.body.copyWith(fontSize: 12.5))),
        ],
      ),
    );
  }
}

/// Satırın fiyatı üründen gelmediyse sunucunun kısa sebebi: referans fiyat
/// (uyarı rengi) ya da hiç fiyat yok (tehlike rengi, satır 0 TL).
class _PriceWarningLine extends StatelessWidget {
  const _PriceWarningLine({required this.item});
  final CalcResultItem item;

  @override
  Widget build(BuildContext context) {
    final color = item.priceSource == CalcResultItem.priceSourceNone ? AppColors.danger : AppColors.warning;
    final text = item.priceWarning!;
    return Row(
      key: ValueKey('metraj-price-warning-${item.recipeItemId}'),
      children: [
        Icon(Icons.warning_amber_rounded, size: 13, color: color),
        const SizedBox(width: 3),
        Flexible(
          child: Text(
            text[0].toUpperCase() + text.substring(1),
            style: AppTypography.helper.copyWith(color: color, fontWeight: FontWeight.w600),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// `line_total` (backend'den STRING) yalnızca görüntüleme için parse edilir
/// -- `Formatters.moneyFromString` ile AYNI kural (`double.tryParse`,
/// parse edilemezse ham değeri göster), yalnızca sonuç `MoneyText` ile
/// (hizalı rakamlar için) biçimlenir.
Widget _lineTotalText(String raw) {
  final style = AppTypography.body.copyWith(fontWeight: FontWeight.w700);
  final parsed = double.tryParse(raw);
  return parsed == null ? Text(raw, style: style) : MoneyText(parsed, style: style);
}

/// Formun altına sabitlenmiş "Teklife Ekle" çubuğu -- uzun bir sonuç
/// listesinde aksiyona ulaşmak için sona kadar kaydırmayı GEREKTİRMEZ
/// (bkz. offer_create_screen.dart _StickyActionBar, aynı kalıp).
class _StickyAddToOfferBar extends StatelessWidget {
  const _StickyAddToOfferBar({required this.count, required this.onAdd});

  final int count;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
        boxShadow: AppShadows.subtle,
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.md,
          AppSpacing.lg,
          AppSpacing.md + MediaQuery.of(context).padding.bottom,
        ),
        child: PrimaryButton(
          label: 'Teklife Ekle ($count)',
          icon: Icons.add_shopping_cart_outlined,
          onPressed: count == 0 ? null : onAdd,
        ),
      ),
    );
  }
}
