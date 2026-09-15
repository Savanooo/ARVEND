import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/errors/api_exception.dart';
import '../data/offers_providers.dart';
import '../domain/offer.dart';

class _DraftItem {
  String productName = '';
  String quantity = '';
  String unitPrice = '';
  String unit = '';
}

class OfferCreateScreen extends ConsumerStatefulWidget {
  const OfferCreateScreen({super.key, this.initialCalcItems});

  /// Metraj Hesaplama'dan "Teklife Ekle" ile gelen, calc_snapshot dahil
  /// hazır kalemler (bkz. features/calculations/presentation/metraj_screen.dart).
  final List<OfferItem>? initialCalcItems;

  @override
  ConsumerState<OfferCreateScreen> createState() => _OfferCreateScreenState();
}

class _OfferCreateScreenState extends ConsumerState<OfferCreateScreen> {
  final _formKey = GlobalKey<FormState>();
  final _customerNameController = TextEditingController();
  final _customerPhoneController = TextEditingController();
  final _notesController = TextEditingController();
  final List<_DraftItem> _items = [_DraftItem()];
  late final List<OfferItem> _calcItems = List.of(widget.initialCalcItems ?? const []);
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _customerNameController.dispose();
    _customerPhoneController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final validManualItems = _items.where((i) {
      final qty = double.tryParse(i.quantity.replaceAll(',', '.'));
      final price = double.tryParse(i.unitPrice.replaceAll(',', '.'));
      return i.productName.trim().isNotEmpty && qty != null && qty > 0 && price != null && price >= 0;
    }).toList();
    if (validManualItems.isEmpty && _calcItems.isEmpty) {
      setState(() => _error = 'En az bir geçerli kalem girin (ürün adı, miktar > 0, birim fiyat >= 0).');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final offer = await ref.read(offersRepositoryProvider).create(
            customerName: _customerNameController.text.trim(),
            customerPhone: _customerPhoneController.text.trim(),
            notes: _notesController.text.trim(),
            items: [
              ...validManualItems.map((i) => OfferItem(
                    id: '',
                    productId: null,
                    productName: i.productName.trim(),
                    quantity: double.parse(i.quantity.replaceAll(',', '.')),
                    unitPrice: double.parse(i.unitPrice.replaceAll(',', '.')),
                    lineTotal: 0,
                    unit: i.unit.trim(),
                    sectionLabel: null,
                    calcCategoryId: null,
                    calcSnapshot: null,
                  )),
              ..._calcItems,
            ],
          );
      if (mounted) context.go('/teklifler/${offer.id}');
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Yeni Teklif')),
      body: Form(
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
            if (_calcItems.isNotEmpty) ...[
              const SizedBox(height: 20),
              const Text('Metraj Hesaplamadan Eklenen', style: TextStyle(fontWeight: FontWeight.w700)),
              ..._calcItems.map((item) => Card(
                    margin: const EdgeInsets.only(top: 8),
                    child: ListTile(
                      leading: const Icon(Icons.straighten_outlined, color: Colors.grey),
                      title: Text(item.productName, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${item.quantity} ${item.unit}'
                          '${item.sectionLabel != null ? ' · ${item.sectionLabel}' : ''}'),
                      trailing: IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => setState(() => _calcItems.remove(item)),
                      ),
                    ),
                  )),
            ],
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Serbest Kalemler', style: TextStyle(fontWeight: FontWeight.w700)),
                TextButton.icon(
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Kalem Ekle'),
                  onPressed: () => setState(() => _items.add(_DraftItem())),
                ),
              ],
            ),
            ..._items.asMap().entries.map((entry) => _ItemRow(
                  item: entry.value,
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
                      width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                  : const Text('Teklifi Oluştur'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.item, required this.onChanged, this.onRemove});
  final _DraftItem item;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    initialValue: item.productName,
                    decoration: const InputDecoration(labelText: 'Ürün / Hizmet Adı', isDense: true),
                    onChanged: (v) {
                      item.productName = v;
                      onChanged();
                    },
                  ),
                ),
                if (onRemove != null)
                  IconButton(icon: const Icon(Icons.close, size: 18), onPressed: onRemove),
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
                    decoration: const InputDecoration(labelText: 'Birim Fiyat', isDense: true),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (v) {
                      item.unitPrice = v;
                      onChanged();
                    },
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
