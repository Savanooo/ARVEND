import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/utils/formatters.dart';
import '../../calculations/presentation/metraj_screen.dart';
import '../data/offers_providers.dart';
import '../domain/offer.dart';

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
      ..quantity = _numStr(item.quantity)
      ..unitPrice = _numStr(item.unitPrice)
      ..unit = item.unit
      ..productId = item.productId
      ..sectionLabel = item.sectionLabel
      ..calcCategoryId = item.calcCategoryId
      ..calcSnapshot = item.calcSnapshot
      ..fromCalc = item.calcSnapshot != null || (item.calcCategoryId != null && item.calcCategoryId!.isNotEmpty);
    if (item.hasInternalPricing) {
      d.pricingMode = item.pricingMode ?? '';
      d.internalCost = item.internalSubcontractCost != null ? _numStr(item.internalSubcontractCost!) : '';
      d.markupPercent = item.markupPercent != null ? _numStr(item.markupPercent!) : '';
    }
    return d;
  }

  static String _numStr(double v) {
    if (v == v.truncateToDouble()) return v.toInt().toString();
    return v.toString();
  }

  double? get previewSellPrice {
    if (pricingMode != OfferItem.pricingModeMarkup) return null;
    final cost = double.tryParse(internalCost.replaceAll(',', '.'));
    final markup = double.tryParse(markupPercent.replaceAll(',', '.'));
    if (cost == null || markup == null) return null;
    return previewMarkupUnitPrice(cost, markup);
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
  bool _loading = false;
  bool _submitting = false;
  String? _error;
  bool _prefilled = false;

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
    } else if (widget.initialCustomerId != null) {
      _customerId = widget.initialCustomerId;
      _customerNameController.text = widget.initialCustomerName ?? '';
      _customerPhoneController.text = widget.initialCustomerPhone ?? '';
      _customerEmailController.text = widget.initialCustomerEmail ?? '';
      _customerAddressController.text = widget.initialCustomerAddress ?? '';
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
      _customerNameController.text = offer.customerName;
      _customerPhoneController.text = offer.customerPhone;
      _customerEmailController.text = offer.customerEmail;
      _customerAddressController.text = offer.customerAddress;
      _notesController.text = offer.notes;
      _vatRateController.text = offer.vatRate == offer.vatRate.truncateToDouble()
          ? offer.vatRate.toInt().toString()
          : offer.vatRate.toString();
      _items
        ..clear()
        ..addAll(offer.items.map(_DraftItem.fromOfferItem));
      if (_items.isEmpty) _items.add(_DraftItem());
      setState(() {
        _loading = false;
        _prefilled = true;
      });
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

  List<OfferItem> _buildItems() {
    final out = <OfferItem>[];
    for (final i in _items) {
      final qty = double.tryParse(i.quantity.replaceAll(',', '.'));
      var price = double.tryParse(i.unitPrice.replaceAll(',', '.'));
      if (i.productName.trim().isEmpty || qty == null || qty <= 0) continue;

      double? internalCost;
      double? markup;
      String? mode;
      if (_canManageInternal && i.pricingMode.isNotEmpty) {
        mode = i.pricingMode;
        internalCost = double.tryParse(i.internalCost.replaceAll(',', '.'));
        if (mode == OfferItem.pricingModeMarkup) {
          markup = double.tryParse(i.markupPercent.replaceAll(',', '.'));
          final preview = (internalCost != null && markup != null)
              ? previewMarkupUnitPrice(internalCost, markup)
              : null;
          if (preview != null) price = preview;
        }
      }
      if (price == null || price < 0) continue;

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
    final vat = double.tryParse(_vatRateController.text.replaceAll(',', '.'));

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
      if (mounted) context.go('/teklifler/${offer.id}');
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canManageInternal = _canManageInternal;
    return Scaffold(
      appBar: AppBar(title: Text(widget.isEdit ? 'Teklifi Düzenle' : 'Yeni Teklif')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  TextFormField(
                    controller: _customerNameController,
                    decoration: const InputDecoration(labelText: 'Müşteri Adı'),
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Müşteri adı gerekli' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _customerPhoneController,
                    decoration: const InputDecoration(labelText: 'Telefon (opsiyonel)'),
                    keyboardType: TextInputType.phone,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _customerEmailController,
                    decoration: const InputDecoration(labelText: 'E-posta (opsiyonel)'),
                    keyboardType: TextInputType.emailAddress,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _customerAddressController,
                    decoration: const InputDecoration(labelText: 'Adres (opsiyonel)'),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _vatRateController,
                    decoration: const InputDecoration(labelText: 'KDV Oranı (%)'),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Kalemler', style: TextStyle(fontWeight: FontWeight.w700)),
                      Row(
                        mainAxisSize: MainAxisSize.min,
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
                    ],
                  ),
                  ..._items.asMap().entries.map((entry) => _ItemRow(
                        key: ValueKey('item-${entry.key}-$_prefilled'),
                        item: entry.value,
                        showInternal: canManageInternal,
                        onChanged: () => setState(() {}),
                        onRemove: _items.length > 1 ? () => setState(() => _items.removeAt(entry.key)) : null,
                      )),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _notesController,
                    decoration: const InputDecoration(labelText: 'Notlar (opsiyonel)'),
                    maxLines: 3,
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: const TextStyle(color: Colors.red)),
                  ],
                  const SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: _submitting ? null : _submit,
                    child: _submitting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                          )
                        : Text(widget.isEdit ? 'Kaydet' : 'Teklifi Oluştur'),
                  ),
                ],
              ),
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
    this.onRemove,
  });

  final _DraftItem item;
  final VoidCallback onChanged;
  final bool showInternal;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final preview = item.previewSellPrice;
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
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
                    onChanged: (v) {
                      item.productName = v;
                      onChanged();
                    },
                  ),
                ),
                if (onRemove != null) IconButton(icon: const Icon(Icons.close, size: 18), onPressed: onRemove),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    initialValue: item.quantity,
                    decoration: const InputDecoration(labelText: 'Miktar', isDense: true),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (v) {
                      item.quantity = v;
                      onChanged();
                    },
                  ),
                ),
                const SizedBox(width: 8),
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
                const SizedBox(width: 8),
                Expanded(
                  child: TextFormField(
                    initialValue: item.unitPrice,
                    decoration: InputDecoration(
                      labelText: item.pricingMode == OfferItem.pricingModeMarkup
                          ? 'Satış (önizleme)'
                          : 'Birim Fiyat',
                      isDense: true,
                    ),
                    enabled: item.pricingMode != OfferItem.pricingModeMarkup,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (v) {
                      item.unitPrice = v;
                      onChanged();
                    },
                  ),
                ),
              ],
            ),
            if (showInternal) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.withValues(alpha: 0.35)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('İç Maliyet / Müşteri Görmez',
                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
                    const SizedBox(height: 8),
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
                      const SizedBox(height: 8),
                      TextFormField(
                        initialValue: item.internalCost,
                        decoration: const InputDecoration(labelText: 'İç taşeron maliyeti', isDense: true),
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        onChanged: (v) {
                          item.internalCost = v;
                          onChanged();
                        },
                      ),
                    ],
                    if (item.pricingMode == OfferItem.pricingModeMarkup) ...[
                      const SizedBox(height: 8),
                      TextFormField(
                        initialValue: item.markupPercent,
                        decoration: const InputDecoration(labelText: 'Markup %', isDense: true),
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        onChanged: (v) {
                          item.markupPercent = v;
                          onChanged();
                        },
                      ),
                      if (preview != null) ...[
                        const SizedBox(height: 6),
                        Text('Önizleme satış: ${Formatters.money(preview)} (sunucu kesinleştirir)',
                            style: const TextStyle(fontSize: 12, color: Colors.black54)),
                      ],
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
