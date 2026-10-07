import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/utils/form_exit.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_shadows.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/app_section_header.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/money_text.dart';
import '../../calculations/presentation/metraj_screen.dart';
import '../../projects/budget/domain/budget.dart' show formatTrDecimalInput, kMaxBudgetAmount, parseTrDecimal;
import '../../projects/finance_plan/domain/finance_dates.dart' show parsePercentInput;
import '../data/offers_providers.dart';
import '../domain/offer.dart';
import 'customer_picker_sheet.dart';

/// Teklif kalemlerinin sayı alanları -- bütçe/masraf/ek iş formlarıyla AYNI
/// Türkçe kural ([parseTrDecimal]): "12.500" = on iki bin beş yüz,
/// "1.250,50" = bin iki yüz elli virgül elli. Eskiden `double.tryParse(x.
/// replaceAll(',', '.'))` "12.500"ü 12,50 kaydediyor, "1.250,50"yi okuyamayıp
/// satırı sessizce atlıyordu. Sütun sınırları: miktar ve iç maliyet
/// numeric(12,2), birim fiyat numeric(18,2), marj numeric(6,2).
const _kMaxQuantity = 9999999999.99;
const _kMaxMarkup = 9999.99;

double? _num(String raw, {double max = kMaxBudgetAmount, bool allowNegative = false}) =>
    parseTrDecimal(raw, max: max, allowNegative: allowNegative).value;

/// Sayı alanı hatası (null = geçerli). [allowZero]: 0 kabul (birim fiyat).
String? _numError(
  String? raw, {
  double max = kMaxBudgetAmount,
  bool allowZero = false,
  bool allowNegative = false,
  bool required = true,
}) {
  final parsed = parseTrDecimal(raw ?? '', max: max, allowNegative: allowNegative);
  if (parsed.error != null) return parsed.error;
  final v = parsed.value;
  if (v == null) return required ? 'Zorunlu' : null;
  if (!allowNegative && !allowZero && v <= 0) return 'Sıfırdan büyük olmalı';
  return null;
}

double _round2(double v) => (v * 100).roundToDouble() / 100;

class _DraftItem {
  _DraftItem();

  String productName = '';
  String quantity = '';
  String unitPrice = '';
  String unit = '';
  String? productId;
  String? sectionLabel;
  String? calcCategoryId;
  Object? calcSnapshot;
  bool fromCalc = false;

  /// '' | markup | manual
  String pricingMode = '';
  String internalCost = '';
  String markupPercent = '';

  factory _DraftItem.fromOfferItem(OfferItem item) {
    final d = _DraftItem()
      ..productName = item.productName
      ..quantity = formatTrDecimalInput(item.quantity)
      ..unitPrice = formatTrDecimalInput(item.unitPrice)
      ..unit = item.unit
      ..productId = item.productId
      ..sectionLabel = item.sectionLabel
      ..calcCategoryId = item.calcCategoryId
      ..calcSnapshot = item.calcSnapshot
      ..fromCalc = item.calcSnapshot != null || (item.calcCategoryId != null && item.calcCategoryId!.isNotEmpty);
    if (item.hasInternalPricing) {
      d.pricingMode = item.pricingMode ?? '';
      d.internalCost = formatTrDecimalInput(item.internalSubcontractCost);
      d.markupPercent = formatTrDecimalInput(item.markupPercent);
    }
    return d;
  }

  /// Hiç dokunulmamış satır gönderilmez; yarım ya da geçersiz bir satır ise
  /// kendi alanında hata gösterir ve kaydı durdurur (eskiden sessizce
  /// atlanıyordu -- kullanıcı kalemin kaybolduğunu fark etmezdi).
  bool get isBlank =>
      productName.trim().isEmpty &&
      quantity.trim().isEmpty &&
      unitPrice.trim().isEmpty &&
      internalCost.trim().isEmpty &&
      markupPercent.trim().isEmpty;

  double? get previewSellPrice {
    if (pricingMode != OfferItem.pricingModeMarkup) return null;
    final cost = _num(internalCost, max: _kMaxQuantity);
    final markup = _num(markupPercent, max: _kMaxMarkup, allowNegative: true);
    if (cost == null || markup == null) return null;
    return previewMarkupUnitPrice(cost, markup);
  }

  /// Sunucunun kullanacağı birim fiyat: markup modunda maliyet × (1 + marj),
  /// değilse girilen fiyat. [showInternal] yoksa iç fiyatlama yok sayılır
  /// (sunucu da yetkisiz kullanıcıda iç alanları temizler).
  double? effectiveUnitPrice({required bool showInternal}) =>
      showInternal && pricingMode == OfferItem.pricingModeMarkup ? previewSellPrice : _num(unitPrice);

  /// Satır toplamı önizlemesi (sunucu `round(q*p, 2)`); geçersizse `null`.
  double? lineTotal({required bool showInternal}) {
    final q = _num(quantity, max: _kMaxQuantity);
    final p = effectiveUnitPrice(showInternal: showInternal);
    if (q == null || q <= 0 || p == null || p < 0) return null;
    return _round2(q * p);
  }
}

/// Create + Edit aynı ekran. [offerId] doluysa PUT /offers/{id}.
///
/// [initialCustomerId] vb. -- "Müşteri → Yeni Teklif" akışı için (bkz.
/// customer_detail_screen.dart): yalnızca CREATE modunda (offerId == null)
/// uygulanır, mevcut teklif düzenlemesini asla ezmez. Bu, teklif oluşturma
/// mantığını müşteri modülü İÇİNDE TEKRARLAMADAN mevcut ekrana müşteri
/// alanlarını + `customer_id`'yi önceden doldurur.
class OfferCreateScreen extends ConsumerStatefulWidget {
  const OfferCreateScreen({
    super.key,
    this.initialCalcItems,
    this.offerId,
    this.initialCustomerId,
    this.initialCustomerName,
    this.initialCustomerPhone,
    this.initialCustomerEmail,
    this.initialCustomerAddress,
  });

  final List<OfferItem>? initialCalcItems;
  final String? offerId;
  final String? initialCustomerId;
  final String? initialCustomerName;
  final String? initialCustomerPhone;
  final String? initialCustomerEmail;
  final String? initialCustomerAddress;

  bool get isEdit => offerId != null;

  @override
  ConsumerState<OfferCreateScreen> createState() => _OfferCreateScreenState();
}

class _OfferCreateScreenState extends ConsumerState<OfferCreateScreen> {
  final _formKey = GlobalKey<FormState>();
  final _customerNameController = TextEditingController();
  final _customerPhoneController = TextEditingController();
  final _customerEmailController = TextEditingController();
  final _customerAddressController = TextEditingController();
  final _notesController = TextEditingController();
  final _vatRateController = TextEditingController(text: '20');
  final List<_DraftItem> _items = [];
  String? _customerId;

  /// Formda geçerlilik tarihi alanı yok; mevcut teklifin tarihi düzenlemede
  /// KORUNUR (PUT null gönderilirse sunucu tarihi silerdi). Yeni teklifte
  /// null gider ve sunucu firma varsayılan süresini uygular.
  String? _validUntil;

  /// Yeni teklifte firma varsayılanları (GET /offers/defaults). Okunamazsa
  /// null: form %20 ile açık kalır, kayıt engellenmez.
  OfferDefaults? _defaults;

  /// Kullanıcı KDV'yi elle değiştirdiyse geç gelen varsayılan onu ezmez.
  bool _vatEdited = false;

  /// Düzenlemede teklifin kendi para birimi; yenide firma varsayılanı.
  String _currency = 'TRY';
  bool _loading = false;
  bool _submitting = false;
  String? _error;

  bool get _canManageInternal {
    final user = ref.watch(authControllerProvider).valueOrNull;
    return user?.hasPermission(kPermOffersInternalPricingManage) ?? false;
  }

  @override
  void initState() {
    super.initState();
    if (widget.initialCalcItems != null && widget.initialCalcItems!.isNotEmpty) {
      _items.addAll(widget.initialCalcItems!.map(_DraftItem.fromOfferItem));
    }
    if (_items.isEmpty) _items.add(_DraftItem());
    if (widget.isEdit) {
      _loading = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadExisting());
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadDefaults());
      if (widget.initialCustomerId != null) {
        _customerId = widget.initialCustomerId;
        _customerNameController.text = widget.initialCustomerName ?? '';
        _customerPhoneController.text = widget.initialCustomerPhone ?? '';
        _customerEmailController.text = widget.initialCustomerEmail ?? '';
        _customerAddressController.text = widget.initialCustomerAddress ?? '';
      }
    }
  }

  /// Firma KDV'si forma yazılır (eskiden her teklif %20 açılıyordu, firma
  /// %10 kaydetmiş olsa bile); alan düzenlenebilir kalır.
  Future<void> _loadDefaults() async {
    try {
      final d = await ref.read(offersRepositoryProvider).defaults();
      if (!mounted) return;
      setState(() {
        _defaults = d;
        _currency = d.currency;
        if (!_vatEdited) _vatRateController.text = formatTrDecimalInput(d.vatRate);
      });
    } catch (_) {
      // Varsayılan okunamadı (ağ/izin): %20 ile devam, kayıt yine mümkün.
    }
  }

  Future<void> _loadExisting() async {
    try {
      final offer = await ref.read(offersRepositoryProvider).get(widget.offerId!);
      if (!mounted) return;
      if (!offer.isEditable) {
        setState(() {
          _loading = false;
          _error = 'Bu teklif düzenlenemez (yalnızca taslak).';
        });
        return;
      }
      _customerId = offer.customerId;
      _validUntil = offer.validUntil;
      _currency = offer.currency;
      _customerNameController.text = offer.customerName;
      _customerPhoneController.text = offer.customerPhone;
      _customerEmailController.text = offer.customerEmail;
      _customerAddressController.text = offer.customerAddress;
      _notesController.text = offer.notes;
      _vatRateController.text = formatTrDecimalInput(offer.vatRate);
      _items
        ..clear()
        ..addAll(offer.items.map(_DraftItem.fromOfferItem));
      if (_items.isEmpty) _items.add(_DraftItem());
      // Yeni kalem nesneleri yeni ObjectKey'ler demektir: satırlar yüklenen
      // değerlerle yeniden kurulur.
      setState(() => _loading = false);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.message;
        });
      }
    }
  }

  @override
  void dispose() {
    _customerNameController.dispose();
    _customerPhoneController.dispose();
    _customerEmailController.dispose();
    _customerAddressController.dispose();
    _notesController.dispose();
    _vatRateController.dispose();
    super.dispose();
  }

  /// Mevcut bir müşteriyi arayıp seçtirir ve alanları doldurur --
  /// müşteri modülünü İÇİNDE TEKRARLAMAZ, yalnızca zaten var olan
  /// müşteri listesi/arama ucunu kullanır (bkz. customer_picker_sheet.dart).
  Future<void> _pickCustomer() async {
    final customer = await showCustomerPickerSheet(context);
    if (customer == null || !mounted) return;
    setState(() {
      _customerId = customer.id;
      _customerNameController.text = customer.name;
      _customerPhoneController.text = customer.phone;
      _customerEmailController.text = customer.email;
      _customerAddressController.text = customer.address;
    });
  }

  /// Kayıtlı müşteri bağını kaldırır: alanlar düzenlenebilir olur ve
  /// teklif serbest metin müşteriyle kaydedilir. Bağlıyken sunucu ad/
  /// telefon/e-posta/adresi müşteri kartından alır ve formda yazılanı YOK
  /// SAYAR -- bu yüzden bağlıyken alanlar salt okunurdur (web ile aynı).
  void _unlinkCustomer() => setState(() => _customerId = null);

  /// Metraj ekranını "seçici" modda açar ve seçilen kalemleri BU teklif
  /// taslağına ekler -- web'in aynı modalı teklif formunun İÇİNDE tuttuğu
  /// ve birden çok bölüm (Salon/Oda 1/Koridor...) hesaplayıp AYNI teklife
  /// ekleyebildiği akışın mobildeki karşılığı (bkz. web MetrajHesaplaPanel.
  /// tsx handleAddFromMetraj). Yeni bir hesaplama motoru İCAT EDİLMEZ --
  /// var olan MetrajScreen'in `pickMode` parametresiyle çağrılır.
  Future<void> _addFromMetraj() async {
    final items = await Navigator.of(context).push<List<OfferItem>>(
      MaterialPageRoute(builder: (_) => const MetrajScreen(pickMode: true)),
    );
    if (items == null || items.isEmpty) return;
    final newRows = items.map(_DraftItem.fromOfferItem).toList();
    setState(() {
      final isSinglePristineRow = _items.length == 1 && _items.single.productName.trim().isEmpty;
      if (isSinglePristineRow) {
        _items
          ..clear()
          ..addAll(newRows);
      } else {
        _items.addAll(newRows);
      }
    });
  }

  /// Form doğrulandıktan SONRA çağrılır: boş olmayan her satır geçerlidir.
  List<OfferItem> _buildItems() {
    final canManageInternal = _canManageInternal;
    final out = <OfferItem>[];
    for (final i in _items) {
      if (i.isBlank) continue;
      final qty = _num(i.quantity, max: _kMaxQuantity)!;
      final price = i.effectiveUnitPrice(showInternal: canManageInternal)!;

      double? internalCost;
      double? markup;
      String? mode;
      if (canManageInternal && i.pricingMode.isNotEmpty) {
        mode = i.pricingMode;
        internalCost = _num(i.internalCost, max: _kMaxQuantity);
        if (mode == OfferItem.pricingModeMarkup) {
          markup = _num(i.markupPercent, max: _kMaxMarkup, allowNegative: true);
        }
      }

      out.add(OfferItem(
        id: '',
        productId: i.productId,
        productName: i.productName.trim(),
        quantity: qty,
        unitPrice: price,
        lineTotal: 0,
        unit: i.unit.trim(),
        sectionLabel: i.sectionLabel,
        calcCategoryId: i.calcCategoryId,
        calcSnapshot: i.calcSnapshot,
        internalSubcontractCost: internalCost,
        pricingMode: mode,
        markupPercent: markup,
      ));
    }
    return out;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final items = _buildItems();
    if (items.isEmpty) {
      setState(() => _error = 'En az bir geçerli kalem girin (ürün adı, miktar > 0, birim fiyat >= 0).');
      return;
    }
    // 0 fiyatlı kalem geçerlidir (ikram/hediye) ama çoğunlukla fiyatı
    // olmayan ürün ya da metraj satırıdır -- sessizce kaydedilmesin.
    final zeroPriced = items.where((i) => i.unitPrice == 0).length;
    if (zeroPriced > 0 && !await _confirmZeroPrices(zeroPriced)) return;
    if (!mounted) return;
    final vat = parsePercentInput(_vatRateController.text);

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final repo = ref.read(offersRepositoryProvider);
      final Offer offer;
      if (widget.isEdit) {
        offer = await repo.update(
          widget.offerId!,
          customerId: _customerId,
          customerName: _customerNameController.text.trim(),
          customerPhone: _customerPhoneController.text.trim(),
          customerEmail: _customerEmailController.text.trim(),
          customerAddress: _customerAddressController.text.trim(),
          validUntil: _validUntil,
          notes: _notesController.text.trim(),
          vatRate: vat,
          items: items,
          includeInternalPricing: _canManageInternal,
        );
      } else {
        offer = await repo.create(
          customerId: _customerId,
          customerName: _customerNameController.text.trim(),
          customerPhone: _customerPhoneController.text.trim(),
          customerEmail: _customerEmailController.text.trim(),
          customerAddress: _customerAddressController.text.trim(),
          notes: _notesController.text.trim(),
          vatRate: vat,
          items: items,
          includeInternalPricing: _canManageInternal,
        );
      }
      ref.invalidate(offerDetailProvider(offer.id));
      ref.invalidate(offersListProvider(''));
      ref.invalidate(offerRevisionsProvider(offer.id));
      if (mounted) leaveSavedForm(context, '/teklifler/${offer.id}', isEdit: widget.isEdit, result: offer);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<bool> _confirmZeroPrices(int count) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('offer-zero-price-confirm'),
        title: const Text('Fiyatı 0 olan kalem var'),
        content: Text('$count kalemin fiyatı 0 ${currencyLabel(_currency)}. Yine de kaydedilsin mi?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Vazgeç')),
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Yine de Kaydet')),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final canManageInternal = _canManageInternal;
    final linked = _customerId != null;
    return AppPageScaffold(
      title: Text(widget.isEdit ? 'Teklifi Düzenle' : 'Yeni Teklif'),
      body: _loading
          ? const LoadingState()
          : Form(
              key: _formKey,
              child: Column(
                children: [
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      children: [
                        AppSectionHeader(
                          title: 'Müşteri',
                          trailing: TextButton.icon(
                            icon: const Icon(Icons.person_search_outlined, size: 18),
                            label: const Text('Seç'),
                            onPressed: _pickCustomer,
                          ),
                        ),
                        if (linked) ...[
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              const Icon(Icons.link, size: 14, color: AppColors.success),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  'Kayıtlı müşteriye bağlı -- bilgiler müşteri kartından alınır',
                                  style: AppTypography.helper.copyWith(color: AppColors.success),
                                ),
                              ),
                              TextButton(
                                key: const ValueKey('offer-customer-unlink'),
                                onPressed: _unlinkCustomer,
                                child: const Text('Bağlantıyı kaldır'),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: AppSpacing.sm),
                        AppCard(
                          child: Column(
                            children: [
                              TextFormField(
                                controller: _customerNameController,
                                enabled: !linked,
                                decoration: const InputDecoration(labelText: 'Müşteri Adı'),
                                validator: (v) => (v == null || v.trim().isEmpty) ? 'Müşteri adı gerekli' : null,
                              ),
                              const SizedBox(height: AppSpacing.md),
                              TextFormField(
                                controller: _customerPhoneController,
                                enabled: !linked,
                                decoration: const InputDecoration(labelText: 'Telefon (opsiyonel)'),
                                keyboardType: TextInputType.phone,
                              ),
                              const SizedBox(height: AppSpacing.md),
                              TextFormField(
                                controller: _customerEmailController,
                                enabled: !linked,
                                decoration: const InputDecoration(labelText: 'E-posta (opsiyonel)'),
                                keyboardType: TextInputType.emailAddress,
                              ),
                              const SizedBox(height: AppSpacing.md),
                              TextFormField(
                                controller: _customerAddressController,
                                enabled: !linked,
                                decoration: const InputDecoration(labelText: 'Adres (opsiyonel)'),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: AppSpacing.lg),
                        TextFormField(
                          controller: _vatRateController,
                          decoration: const InputDecoration(labelText: 'KDV Oranı (%)'),
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          // Boş bırakılınca sunucu sessizce %20 uygulardı; nokta ve
                          // virgül ikisi de ondalık, binlik gruplama yok ("18.5").
                          validator: (v) {
                            final s = (v ?? '').trim();
                            if (s.isEmpty) return 'KDV oranı zorunludur';
                            final n = parsePercentInput(s);
                            if (n == null) return 'Geçerli bir oran gir (ör. 20 veya 2,5).';
                            if (n > 100) return 'KDV oranı en fazla %100 olabilir';
                            return null;
                          },
                          onChanged: (_) => setState(() => _vatEdited = true),
                        ),
                        if (_defaults != null) _DefaultsInfo(defaults: _defaults!),
                        const SizedBox(height: AppSpacing.xl),
                        const AppSectionHeader(title: 'Kalemler'),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: AppSpacing.xs,
                          runSpacing: 4,
                          children: [
                            TextButton.icon(
                              icon: const Icon(Icons.calculate_outlined, size: 18),
                              label: const Text('Metrajdan Ekle'),
                              onPressed: _addFromMetraj,
                            ),
                            TextButton.icon(
                              icon: const Icon(Icons.add, size: 18),
                              label: const Text('Kalem Ekle'),
                              onPressed: () => setState(() => _items.add(_DraftItem())),
                            ),
                          ],
                        ),
                        ..._items.asMap().entries.map((entry) => _ItemRow(
                              // Nesne anahtarı: ortadaki bir satır silinince yazılan
                              // değerler bir alttaki satıra kaymasın.
                              key: ObjectKey(entry.value),
                              item: entry.value,
                              showInternal: canManageInternal,
                              currency: _currency,
                              onChanged: () => setState(() {}),
                              onRemove: _items.length > 1 ? () => setState(() => _items.removeAt(entry.key)) : null,
                            )),
                        _TotalsPreview(
                          items: _items,
                          vatRateText: _vatRateController.text,
                          showInternal: canManageInternal,
                          currency: _currency,
                        ),
                        const SizedBox(height: AppSpacing.md),
                        TextFormField(
                          controller: _notesController,
                          decoration: const InputDecoration(labelText: 'Notlar (opsiyonel)'),
                          maxLines: 3,
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: AppSpacing.md),
                          Text(_error!, style: AppTypography.error),
                        ],
                        const SizedBox(height: AppSpacing.xl),
                      ],
                    ),
                  ),
                  _StickyActionBar(
                    child: PrimaryButton(
                      label: widget.isEdit ? 'Kaydet' : 'Teklifi Oluştur',
                      loading: _submitting,
                      onPressed: _submit,
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

/// Yeni teklifte formda alanı olmayan firma varsayılanları: geçerlilik sonu
/// (sunucu kayıtta bugün + firma süresi yazar) ve TRY dışı para birimi.
/// Kullanıcı teklifin süresiz ya da TL açılacağını sanmasın.
class _DefaultsInfo extends StatelessWidget {
  const _DefaultsInfo({required this.defaults});
  final OfferDefaults defaults;

  @override
  Widget build(BuildContext context) {
    final lines = <String>[
      if (defaults.validUntil != null)
        'Geçerlilik sonu: ${Formatters.date(defaults.validUntil)}'
            '${defaults.validityDays != null ? ' (firma ayarı: ${defaults.validityDays} gün)' : ''}',
      if (defaults.currency != 'TRY') 'Para birimi: ${defaults.currency} (firma ayarı)',
    ];
    if (lines.isEmpty) return const SizedBox.shrink();
    return Padding(
      key: const ValueKey('offer-defaults-info'),
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 14, color: AppColors.textMuted),
          const SizedBox(width: 4),
          Expanded(child: Text(lines.join('\n'), style: AppTypography.helper)),
        ],
      ),
    );
  }
}

/// Formun altına sabitlenmiş aksiyon çubuğu -- uzun formlarda kaydet
/// butonuna ulaşmak için listenin sonuna kadar kaydırmayı GEREKTİRMEZ
/// (bkz. redesign denetim raporu, Faz 7/10 bulgusu).
class _StickyActionBar extends StatelessWidget {
  const _StickyActionBar({required this.child});
  final Widget child;

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
        child: child,
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({
    super.key,
    required this.item,
    required this.onChanged,
    required this.showInternal,
    this.currency = 'TRY',
    this.onRemove,
  });

  final _DraftItem item;
  final VoidCallback onChanged;
  final bool showInternal;
  final String currency;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final preview = item.previewSellPrice;
    final markupMode = showInternal && item.pricingMode == OfferItem.pricingModeMarkup;
    final lineTotal = item.lineTotal(showInternal: showInternal);
    return AppCard(
      margin: const EdgeInsets.only(top: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  initialValue: item.productName,
                  decoration: InputDecoration(
                    labelText: item.fromCalc ? 'Ürün / Hizmet (metraj)' : 'Ürün / Hizmet Adı',
                    isDense: true,
                  ),
                  validator: (v) => item.isBlank || (v ?? '').trim().isNotEmpty ? null : 'Ürün / hizmet adı gerekli',
                  onChanged: (v) {
                    item.productName = v;
                    onChanged();
                  },
                ),
              ),
              if (onRemove != null) IconButton(icon: const Icon(Icons.close, size: 18), onPressed: onRemove),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          TextFormField(
            initialValue: item.sectionLabel ?? '',
            decoration: const InputDecoration(
                labelText: 'Bölüm / Alan (opsiyonel — Salon, Oda 1, Koridor...)', isDense: true),
            onChanged: (v) {
              item.sectionLabel = v.trim().isEmpty ? null : v.trim();
              onChanged();
            },
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  initialValue: item.quantity,
                  decoration: const InputDecoration(labelText: 'Miktar', isDense: true, errorMaxLines: 3),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  validator: (v) => item.isBlank ? null : _numError(v, max: _kMaxQuantity),
                  onChanged: (v) {
                    item.quantity = v;
                    onChanged();
                  },
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: TextFormField(
                  initialValue: item.unit,
                  decoration: const InputDecoration(labelText: 'Birim', isDense: true),
                  onChanged: (v) {
                    item.unit = v;
                    onChanged();
                  },
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: TextFormField(
                  initialValue: item.unitPrice,
                  decoration: InputDecoration(
                    labelText: item.pricingMode == OfferItem.pricingModeMarkup ? 'Satış (önizleme)' : 'Birim Fiyat',
                    isDense: true,
                    errorMaxLines: 3,
                  ),
                  enabled: item.pricingMode != OfferItem.pricingModeMarkup,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  // Markup modunda fiyatı sunucu maliyet × (1 + marj) olarak
                  // hesaplar; alan kilitli, doğrulama maliyet/marj alanlarında.
                  validator: (v) => item.isBlank || markupMode ? null : _numError(v, allowZero: true),
                  onChanged: (v) {
                    item.unitPrice = v;
                    onChanged();
                  },
                ),
              ),
            ],
          ),
          // Satır toplamı önizlemesi: "12.500" -> 12.500,00 TL mi yoksa
          // 12,50 TL mi, kayıttan önce görünsün.
          if (lineTotal != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Align(
              alignment: Alignment.centerRight,
              child: Text('Satır toplamı: ${Formatters.money(lineTotal, currency: currency)}', style: AppTypography.helper),
            ),
          ],
          if (showInternal) ...[
            const SizedBox(height: AppSpacing.md),
            _InternalPricingBox(item: item, preview: preview, currency: currency, onChanged: onChanged),
          ],
        ],
      ),
    );
  }
}

/// Bu kalemin müşteriye ASLA gösterilmeyen kısmı. Renkle SINIRLI kalmayan
/// bir ayrım için: kilit ikonu + açık başlık + alt metin + FARKLI bir
/// nötr/koyu ton (durum renklerinden -- success/warning/danger/info --
/// KASITLI OLARAK ayrı, çünkü bu bir "durum" değil bir "gizlilik" ekseni).
class _InternalPricingBox extends StatelessWidget {
  const _InternalPricingBox({
    required this.item,
    required this.preview,
    required this.onChanged,
    this.currency = 'TRY',
  });
  final _DraftItem item;
  final double? preview;
  final VoidCallback onChanged;
  final String currency;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.navDark.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(color: AppColors.navDark.withValues(alpha: 0.16)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.lock_outline, size: 16, color: AppColors.navDark),
              const SizedBox(width: 6),
              Text('İç Fiyatlandırma', style: AppTypography.cardTitle.copyWith(color: AppColors.navDark)),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 22, top: 2, bottom: AppSpacing.sm),
            child: Text('Müşteri görmez', style: AppTypography.helper),
          ),
          DropdownButtonFormField<String>(
            initialValue: item.pricingMode.isEmpty ? '' : item.pricingMode,
            decoration: const InputDecoration(labelText: 'Fiyat Modu', isDense: true),
            items: const [
              DropdownMenuItem(value: '', child: Text('Yok')),
              DropdownMenuItem(value: OfferItem.pricingModeMarkup, child: Text('Markup')),
              DropdownMenuItem(value: OfferItem.pricingModeManual, child: Text('Manuel satış')),
            ],
            onChanged: (v) {
              item.pricingMode = v ?? '';
              if (item.pricingMode != OfferItem.pricingModeMarkup) {
                item.markupPercent = '';
              }
              onChanged();
            },
          ),
          if (item.pricingMode.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            TextFormField(
              initialValue: item.internalCost,
              decoration: const InputDecoration(labelText: 'İç taşeron maliyeti', isDense: true, errorMaxLines: 3),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              // Markup modunda satış fiyatı bu maliyetten hesaplanır: zorunlu.
              validator: (v) => item.isBlank
                  ? null
                  : _numError(
                      v,
                      max: _kMaxQuantity,
                      allowZero: true,
                      required: item.pricingMode == OfferItem.pricingModeMarkup,
                    ),
              onChanged: (v) {
                item.internalCost = v;
                onChanged();
              },
            ),
          ],
          if (item.pricingMode == OfferItem.pricingModeMarkup) ...[
            const SizedBox(height: AppSpacing.sm),
            TextFormField(
              initialValue: item.markupPercent,
              decoration: const InputDecoration(labelText: 'Markup %', isDense: true, errorMaxLines: 3),
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              validator: (v) {
                if (item.isBlank) return null;
                final error = _numError(v, max: _kMaxMarkup, allowNegative: true);
                if (error != null) return error;
                // Negatif satış fiyatlı kalemi sunucu sessizce atlardı.
                final sell = item.previewSellPrice;
                return sell != null && sell < 0 ? 'Satış fiyatı negatif olamaz (marj en az -%100).' : null;
              },
              onChanged: (v) {
                item.markupPercent = v;
                onChanged();
              },
            ),
            if (preview != null) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Text('Önizleme satış: ', style: AppTypography.helper),
                  MoneyText(preview!, currency: currency, style: AppTypography.helper.copyWith(fontWeight: FontWeight.w700)),
                  Text(' (sunucu kesinleştirir)', style: AppTypography.helper),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// Kalemlerin altındaki Ara Toplam / KDV / Toplam önizlemesi -- sunucu
/// formülüyle aynı yuvarlama (satır `round(q*p, 2)`, KDV `round(ara*oran/
/// 100, 2)`). Yanlış büyüklük (ör. 12.500 yerine 12,50) kayıttan ÖNCE
/// görünsün diye; kesin toplamı kayıtta sunucu hesaplar. Geçerli satır
/// yoksa çizilmez.
class _TotalsPreview extends StatelessWidget {
  const _TotalsPreview({
    required this.items,
    required this.vatRateText,
    required this.showInternal,
    this.currency = 'TRY',
  });

  final List<_DraftItem> items;
  final String vatRateText;
  final bool showInternal;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final totals = [
      for (final i in items)
        if (!i.isBlank) i.lineTotal(showInternal: showInternal),
    ].whereType<double>().toList();
    if (totals.isEmpty) return const SizedBox.shrink();
    final subtotal = _round2(totals.fold<double>(0, (a, b) => a + b));
    final rate = parsePercentInput(vatRateText) ?? 0;
    final vat = _round2(subtotal * rate / 100);
    Widget row(String label, double value, {bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Expanded(child: Text(label, style: bold ? AppTypography.cardTitle : AppTypography.metadata)),
              MoneyText(value, currency: currency, style: bold ? AppTypography.cardTitle : AppTypography.body),
            ],
          ),
        );
    return AppCard(
      key: const ValueKey('offer-totals-preview'),
      margin: const EdgeInsets.only(top: AppSpacing.sm),
      child: Column(
        children: [
          row('Ara Toplam', subtotal),
          row('KDV (${Formatters.percent(rate)})', vat),
          const Divider(),
          row('Genel Toplam', _round2(subtotal + vat), bold: true),
        ],
      ),
    );
  }
}
