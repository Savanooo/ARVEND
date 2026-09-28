import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/access_notices.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_form_section.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/unsaved_changes_scope.dart';
import '../data/calc_admin_providers.dart';
import '../domain/calc_admin.dart';
import 'calc_admin_common.dart';

/// Silme isteği süren kalemler: aynı kalem (kart menüsü + düzenleme ekranı)
/// ikinci kez silinmeye çalışılmasın -- ikinci istek 404 dönüp başarılı
/// silmenin ardından hata gösterirdi.
final Set<String> _deletingRecipeItems = {};

/// Reçete kalemi silme onayı + çağrısı -- hem kalem kartının menüsünden hem
/// düzenleme ekranının üst çubuğundan kullanılır. Silindiyse `true`. Kalem
/// listesi burada, ekran kapansa bile tazelenir.
Future<bool> confirmAndDeleteRecipeItem(BuildContext context, WidgetRef ref, CalcRecipeItem item) async {
  if (_deletingRecipeItems.contains(item.id)) return false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Reçete Kalemini Sil'),
      content: Text(
        '"${item.materialName}" kalemini silmek istediğine emin misin? Bu, geçmiş tekliflerdeki hesap '
        'sonuçlarını ETKİLEMEZ (o kalemler dondurulmuş bir kopya taşır).',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Vazgeç')),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          style: TextButton.styleFrom(foregroundColor: AppColors.danger),
          child: const Text('Sil'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted || _deletingRecipeItems.contains(item.id)) return false;
  final container = ProviderScope.containerOf(context, listen: false);
  _deletingRecipeItems.add(item.id);
  try {
    await container.read(calcAdminRepositoryProvider).deleteRecipeItem(item.id);
    container.invalidate(calcAdminRecipeItemsProvider(item.categoryId));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Reçete kalemi silindi.')));
    }
    return true;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(calcAdminErrorMessage(e, write: true))));
    }
    return false;
  } finally {
    _deletingRecipeItems.remove(item.id);
  }
}

/// Reçete kalemi oluştur / düzenle / görüntüle (web `RecipeItemsEditor`
/// modalı). `calculations.manage` yoksa aynı form salt okunur açılır.
/// Kaydedildi/silindiyse `Navigator.pop(true)`.
class RecipeItemFormScreen extends ConsumerStatefulWidget {
  const RecipeItemFormScreen({super.key, required this.categoryId, this.existing});

  final String categoryId;
  final CalcRecipeItem? existing;

  bool get isNew => existing == null;

  @override
  ConsumerState<RecipeItemFormScreen> createState() => _RecipeItemFormScreenState();
}

class _RecipeItemFormScreenState extends ConsumerState<RecipeItemFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _materialName;
  late final TextEditingController _unit;
  late final TextEditingController _perM2;
  late final TextEditingController _perMeter;
  late final TextEditingController _fixed;
  late final TextEditingController _waste;
  late final TextEditingController _minQuantity;
  late final TextEditingController _packageSize;
  late final TextEditingController _referencePrice;
  late final TextEditingController _groupName;
  late final TextEditingController _sortOrder;
  late final TextEditingController _notes;
  late String _calcType;
  late String _rounding;
  String? _productId;
  late bool _isActive;
  bool _saving = false;
  bool _deleting = false;
  String? _error;

  bool get _busy => _saving || _deleting;

  @override
  void initState() {
    super.initState();
    final i = widget.existing;
    _materialName = TextEditingController(text: i?.materialName ?? '');
    _unit = TextEditingController(text: i?.unit ?? '');
    // Backend 6 haneli noktalı string döner ("1.050000"); form Türkçe
    // yazımla (virgül, gruplamasız, gereksiz sıfırsız: "1,05") açılır --
    // kaydederken yine noktalı string gider.
    String input(String? v, String fallback) => formatCalcInput(v, fallback: fallback);
    _perM2 = TextEditingController(text: input(i?.quantityPerM2, '0'));
    _perMeter = TextEditingController(text: input(i?.quantityPerMeter, '0'));
    _fixed = TextEditingController(text: input(i?.fixedQuantity, '0'));
    _waste = TextEditingController(text: input(i?.wastePercent, '0'));
    _minQuantity = TextEditingController(text: input(i?.minQuantity, ''));
    _packageSize = TextEditingController(text: input(i?.packageSize, ''));
    _referencePrice = TextEditingController(text: formatCalcPriceInput(i?.referenceUnitPrice ?? '0'));
    _groupName = TextEditingController(text: i?.groupName ?? '');
    _sortOrder = TextEditingController(text: '${i?.sortOrder ?? 0}');
    _notes = TextEditingController(text: i?.notes ?? '');
    _calcType = CalcType.labels.containsKey(i?.calculationType) ? i!.calculationType : CalcType.areaBased;
    _rounding = CalcRounding.labels.containsKey(i?.roundingType) ? i!.roundingType : CalcRounding.none;
    _productId = i?.productId;
    _isActive = i?.isActive ?? true;
  }

  @override
  void dispose() {
    for (final c in [
      _materialName,
      _unit,
      _perM2,
      _perMeter,
      _fixed,
      _waste,
      _minQuantity,
      _packageSize,
      _referencePrice,
      _groupName,
      _sortOrder,
      _notes,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final input = CalcRecipeItemInput(
      categoryId: widget.categoryId,
      // products.read yoksa seçici yoktur; mevcut bağlantı AYNEN korunur.
      productId: _productId,
      materialName: _materialName.text,
      unit: _unit.text,
      calculationType: _calcType,
      quantityPerM2: _perM2.text,
      quantityPerMeter: _perMeter.text,
      fixedQuantity: _fixed.text,
      wastePercent: _waste.text,
      roundingType: _rounding,
      minQuantity: _minQuantity.text,
      packageSize: _packageSize.text,
      referenceUnitPrice: _referencePrice.text,
      groupName: _groupName.text,
      sortOrder: int.tryParse(_sortOrder.text.trim()) ?? 0,
      isActive: _isActive,
      notes: _notes.text,
    );
    // Kayıt sürerken ekran kapanamaz (UnsavedChangesScope); yine de liste
    // tazelemesi ekrana bağlı kalmasın diye kapsayıcı önceden alınır.
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      final repo = container.read(calcAdminRepositoryProvider);
      if (widget.isNew) {
        await repo.createRecipeItem(input);
      } else {
        await repo.updateRecipeItem(widget.existing!.id, input);
      }
      container.invalidate(calcAdminRecipeItemsProvider(widget.categoryId));
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(widget.isNew ? 'Reçete kalemi eklendi.' : 'Kaydedildi.')));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = calcAdminErrorMessage(e, write: true));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    setState(() => _deleting = true);
    try {
      final deleted = await confirmAndDeleteRecipeItem(context, ref, widget.existing!);
      if (deleted && mounted) Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  String get _formulaText => switch (_calcType) {
    CalcType.perimeterBased => 'çevre (m) × Katsayı/m',
    CalcType.fixed => 'her zaman Sabit Miktar',
    _ => 'etkin alan (m²) × Katsayı/m²',
  };

  @override
  Widget build(BuildContext context) {
    final access = watchCalcAdminAccess(ref);
    final readOnly = !access.canManage;
    final title = widget.isNew
        ? 'Yeni Reçete Kalemi'
        : readOnly
        ? 'Reçete Kalemi'
        : 'Reçete Kalemini Düzenle';

    if (!access.canRead || (widget.isNew && readOnly)) {
      return AppPageScaffold(title: Text(title), body: const CalcNoAccessView());
    }

    const numberKeyboard = TextInputType.numberWithOptions(decimal: true);

    return AppPageScaffold(
      title: Text(title),
      actions: [
        if (!widget.isNew && !readOnly)
          IconButton(
            tooltip: 'Sil',
            icon: const Icon(Icons.delete_outline, color: AppColors.danger),
            onPressed: _busy ? null : _delete,
          ),
      ],
      body: UnsavedChangesScope(
        busy: _busy,
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
            children: [
              if (readOnly) ...[const ReadOnlyNotice(kCalcReadOnlyMessage), const SizedBox(height: AppSpacing.lg)],
              AppFormSection(
                title: 'Malzeme',
                children: [
                  TextFormField(
                    controller: _materialName,
                    enabled: !readOnly,
                    inputFormatters: [LengthLimitingTextInputFormatter(CalcLimits.materialName)],
                    decoration: const InputDecoration(labelText: 'Malzeme Adı *'),
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Malzeme adı zorunludur' : null,
                  ),
                  TextFormField(
                    controller: _unit,
                    enabled: !readOnly,
                    inputFormatters: [LengthLimitingTextInputFormatter(CalcLimits.unit)],
                    decoration: const InputDecoration(labelText: 'Birim *', hintText: 'ör. adet, m², paket'),
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Birim zorunludur' : null,
                  ),
                ],
              ),
              AppFormSection(
                title: 'Hesaplama',
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: _calcType,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Hesaplama Türü'),
                    items: [
                      for (final e in CalcType.labels.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
                    ],
                    onChanged: readOnly ? null : (v) => setState(() => _calcType = v ?? CalcType.areaBased),
                  ),
                  // Yalnızca seçili türün katsayısı gösterilir; diğerlerinin
                  // değeri korunur ve web'deki gibi aynen geri gönderilir.
                  if (_calcType == CalcType.areaBased)
                    _decimalField(
                      _perM2,
                      'Katsayı / m²',
                      readOnly,
                      numberKeyboard,
                      max: CalcLimits.perUnitFactor,
                      maxDecimals: 6,
                    )
                  else if (_calcType == CalcType.perimeterBased)
                    _decimalField(
                      _perMeter,
                      'Katsayı / m (çevre)',
                      readOnly,
                      numberKeyboard,
                      max: CalcLimits.perUnitFactor,
                      maxDecimals: 6,
                    )
                  else
                    _decimalField(
                      _fixed,
                      'Sabit Miktar',
                      readOnly,
                      numberKeyboard,
                      max: CalcLimits.quantity,
                      maxDecimals: 4,
                    ),
                  Text(
                    'Yalnızca seçili hesaplama türüne uyan katsayı kullanılır; miktar = $_formulaText '
                    '→ fire → minimum → paket/yuvarlama.',
                    style: AppTypography.helper,
                  ),
                ],
              ),
              AppFormSection(
                title: 'Fire ve Yuvarlama',
                children: [
                  _decimalField(
                    _waste,
                    'Fire (%)',
                    readOnly,
                    numberKeyboard,
                    max: CalcLimits.wastePercent,
                    maxDecimals: 2,
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: _rounding,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Yuvarlama'),
                    items: [
                      for (final e in CalcRounding.labels.entries)
                        DropdownMenuItem(
                          value: e.key,
                          child: Text(e.value, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: readOnly ? null : (v) => setState(() => _rounding = v ?? CalcRounding.none),
                  ),
                  _decimalField(
                    _minQuantity,
                    'Minimum Miktar (opsiyonel)',
                    readOnly,
                    numberKeyboard,
                    hint: 'boş bırakılabilir',
                    max: CalcLimits.quantity,
                    maxDecimals: 4,
                  ),
                  _decimalField(
                    _packageSize,
                    'Paket Büyüklüğü (opsiyonel)',
                    readOnly,
                    numberKeyboard,
                    hint: 'ör. 3,6 — 1 paket kaç birim kaplar',
                    positive: true,
                    max: CalcLimits.quantity,
                    maxDecimals: 4,
                  ),
                  const Text(
                    'Paket büyüklüğü verilirse yuvarlama kuralının YERİNE geçer: sonuç, ham miktarı karşılamak için '
                    'gereken PAKET SAYISIDIR (birim genelde “paket/rulo/torba” olmalı).',
                    style: AppTypography.helper,
                  ),
                ],
              ),
              AppFormSection(
                title: 'Fiyat ve Ürün',
                children: [
                  _decimalField(
                    _referencePrice,
                    'Referans Fiyat (TL)',
                    readOnly,
                    numberKeyboard,
                    hint: 'ör. 1250,50',
                    max: CalcLimits.referencePrice,
                    maxDecimals: 2,
                  ),
                  if (access.canReadProducts)
                    _ProductField(
                      selectedId: _productId,
                      enabled: !readOnly,
                      onChanged: (id) => setState(() => _productId = id),
                    )
                  else
                    Text(
                      'Ürün bağlantısı: ${_productId != null ? 'bağlı' : 'bağlı değil'}'
                      '${readOnly ? '.' : ' (değiştirmek için rolünde "Ürün kataloğunu görüntüleme" izni olmalı; kaydederken mevcut bağlantı korunur).'}',
                      style: AppTypography.helper,
                    ),
                ],
              ),
              AppFormSection(
                title: 'Diğer',
                children: [
                  TextFormField(
                    controller: _groupName,
                    enabled: !readOnly,
                    inputFormatters: [LengthLimitingTextInputFormatter(CalcLimits.groupName)],
                    decoration: const InputDecoration(labelText: 'Alt Başlık', hintText: 'ör. Ana Malzemeler'),
                  ),
                  TextFormField(
                    controller: _sortOrder,
                    enabled: !readOnly,
                    decoration: const InputDecoration(labelText: 'Sıra'),
                    keyboardType: const TextInputType.numberWithOptions(signed: true),
                    validator: (v) =>
                        (v != null && v.trim().isNotEmpty && int.tryParse(v.trim()) == null) ? 'Tam sayı gir' : null,
                  ),
                  if (!widget.isNew)
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      value: _isActive,
                      onChanged: readOnly ? null : (v) => setState(() => _isActive = v),
                      title: const Text('Aktif', style: AppTypography.body),
                    ),
                  TextFormField(
                    controller: _notes,
                    enabled: !readOnly,
                    decoration: const InputDecoration(labelText: 'Not'),
                    maxLines: 2,
                    minLines: 1,
                  ),
                ],
              ),
              if (_error != null) ...[Text(_error!, style: AppTypography.error), const SizedBox(height: AppSpacing.md)],
              if (!readOnly) PrimaryButton(label: 'Kaydet', loading: _saving, onPressed: _deleting ? null : _submit),
            ],
          ),
        ),
      ),
    );
  }

  Widget _decimalField(
    TextEditingController controller,
    String label,
    bool readOnly,
    TextInputType keyboard, {
    String? hint,
    bool positive = false,
    double? max,
    int? maxDecimals,
  }) {
    return TextFormField(
      controller: controller,
      enabled: !readOnly,
      decoration: InputDecoration(labelText: label, hintText: hint, errorMaxLines: 3),
      keyboardType: keyboard,
      validator: (v) =>
          validateDecimalField(v ?? '', label: label, positive: positive, max: max, maxDecimals: maxDecimals),
    );
  }
}

/// Ürün seçici alanı -- ~3.000+ ürünlük katalogda açılır liste yerine
/// aranabilir alt sayfa. Yalnızca `products.read` ile gösterilir.
class _ProductField extends ConsumerWidget {
  const _ProductField({required this.selectedId, required this.enabled, required this.onChanged});

  final String? selectedId;
  final bool enabled;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final productsAsync = ref.watch(calcAdminProductsProvider);
    final products = productsAsync.valueOrNull;

    String display;
    if (selectedId == null) {
      display = 'Bağlı değil';
    } else if (products == null) {
      display = productsAsync.hasError ? 'Bağlı ürün' : 'Yükleniyor…';
    } else {
      display = 'Bağlı ürün (listede yok)';
      for (final p in products) {
        if (p.id == selectedId) {
          display = _productText(p);
          break;
        }
      }
    }

    final canOpen = enabled && products != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(AppRadius.control),
          onTap: canOpen
              ? () async {
                  final picked = await showModalBottomSheet<({String? id})>(
                    context: context,
                    isScrollControlled: true,
                    useSafeArea: true,
                    builder: (_) => _ProductPickerSheet(products: products, selectedId: selectedId),
                  );
                  if (picked != null) onChanged(picked.id);
                }
              : null,
          child: InputDecorator(
            isEmpty: false,
            decoration: InputDecoration(
              labelText: 'Ürün (fiyat buradan okunur; boş bırakılabilir)',
              enabled: enabled,
              suffixIcon: enabled && selectedId != null
                  ? IconButton(
                      tooltip: 'Bağlantıyı kaldır',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => onChanged(null),
                    )
                  : const Icon(Icons.search, size: 18),
            ),
            child: Text(
              display,
              style: AppTypography.body.copyWith(color: enabled ? null : AppColors.textMuted),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        if (productsAsync.hasError && products == null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Row(
              children: [
                const Expanded(
                  child: Text('Ürün listesi alınamadı; mevcut bağlantı korunur.', style: AppTypography.helper),
                ),
                TextButton(
                  onPressed: () => ref.invalidate(calcAdminProductsProvider),
                  child: const Text('Tekrar Dene'),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

String _productText(CalcProductOption p) => '${p.name} (${p.unit}, ${Formatters.money(p.unitPrice)})';

class _ProductPickerSheet extends StatefulWidget {
  const _ProductPickerSheet({required this.products, required this.selectedId});

  final List<CalcProductOption> products;
  final String? selectedId;

  @override
  State<_ProductPickerSheet> createState() => _ProductPickerSheetState();
}

class _ProductPickerSheetState extends State<_ProductPickerSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = searchFold(_query);
    final filtered = q.isEmpty
        ? widget.products
        : widget.products.where((p) => searchFold(p.name).contains(q)).toList(growable: false);

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.85,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Ürün Seç', style: AppTypography.pageTitle.copyWith(fontSize: 17)),
                  const SizedBox(height: AppSpacing.md),
                  TextField(
                    autofocus: false,
                    decoration: const InputDecoration(
                      hintText: 'Ürün adına göre ara',
                      prefixIcon: Icon(Icons.search),
                      isDense: true,
                    ),
                    onChanged: (v) => setState(() => _query = v.trim()),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: filtered.length + 1,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return ListTile(
                      leading: const Icon(Icons.link_off),
                      title: const Text('Bağlı değil'),
                      selected: widget.selectedId == null,
                      onTap: () => Navigator.of(context).pop((id: null)),
                    );
                  }
                  final p = filtered[index - 1];
                  return ListTile(
                    title: Text(p.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${p.unit} · ${Formatters.money(p.unitPrice)}'),
                    selected: p.id == widget.selectedId,
                    onTap: () => Navigator.of(context).pop((id: p.id)),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
