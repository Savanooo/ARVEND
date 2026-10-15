import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_sheet.dart';
import '../../../core/widgets/unsaved_changes_scope.dart';
import '../data/inventory_repository.dart';
import '../domain/inventory.dart';
import 'barcode_scanner.dart';
import 'inventory_common.dart';

const _kUnits = ['adet', 'kg', 'm', 'm²', 'm³', 'boy', 'torba', 'kutu', 'paket', 'lt', 'rulo', 'ton'];

/// Malzeme kartı: aç ya da düzenle. Kod boş bırakılırsa sunucu STK-NNNN
/// verir. SKT takibi açılırsa girişte son kullanma tarihi istenir; raf ömrü
/// girilirse üretim tarihinden hesaplanır. "Engelle" SKT'si geçen partinin
/// çıkışını durdurur (yalnızca fire), "Uyar" uyararak izin verir.
Future<InventoryItem?> showInventoryItemFormSheet(BuildContext context, {InventoryItem? existing, String initialBarcode = ''}) {
  return showAppSheet<InventoryItem>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => InventoryItemFormSheet(existing: existing, initialBarcode: initialBarcode),
  );
}

class InventoryItemFormSheet extends ConsumerStatefulWidget {
  const InventoryItemFormSheet({super.key, this.existing, this.initialBarcode = ''});

  final InventoryItem? existing;
  final String initialBarcode;

  @override
  ConsumerState<InventoryItemFormSheet> createState() => _InventoryItemFormSheetState();
}

class _InventoryItemFormSheetState extends ConsumerState<InventoryItemFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _code = TextEditingController(text: widget.existing?.code ?? '');
  late final _barcode = TextEditingController(text: widget.existing?.barcode ?? widget.initialBarcode);
  late final _category = TextEditingController(text: widget.existing?.category ?? '');
  late final _unit = TextEditingController(text: widget.existing?.unit ?? 'adet');
  late final _minStock = TextEditingController(text: qtyInputText(widget.existing?.minStock));
  late final _shelfLife = TextEditingController(text: widget.existing?.shelfLifeMonths?.toString() ?? '');
  late final _alertDays = TextEditingController(text: '${widget.existing?.expiryAlertDays ?? 30}');
  late final _notes = TextEditingController(text: widget.existing?.notes ?? '');
  late bool _trackExpiry = widget.existing?.trackExpiry ?? false;
  late String _policy = widget.existing?.expiryPolicy ?? kExpiryPolicyWarn;
  late bool _active = widget.existing?.isActive ?? true;
  bool _dirty = false;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_name, _code, _barcode, _category, _unit, _minStock, _shelfLife, _alertDays, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  void _touch() {
    if (!_dirty) setState(() => _dirty = true);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final data = <String, dynamic>{
      'name': _name.text.trim(),
      'code': _code.text.trim(),
      'barcode': _barcode.text.trim(),
      'category': _category.text.trim(),
      'unit': _unit.text.trim().isEmpty ? 'adet' : _unit.text.trim(),
      'min_stock': parseQtyInput(_minStock.text),
      'track_expiry': _trackExpiry,
      'shelf_life_months': _trackExpiry ? int.tryParse(_shelfLife.text.trim()) : null,
      'expiry_policy': _policy,
      'expiry_alert_days': int.tryParse(_alertDays.text.trim()) ?? 30,
      'notes': _notes.text.trim(),
      if (widget.existing != null) 'is_active': _active,
    };
    try {
      final saved = await ref.read(inventoryRepositoryProvider).saveItem(id: widget.existing?.id, data: data);
      invalidateInventory(ref.invalidate);
      if (mounted) Navigator.of(context).pop(saved);
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    return UnsavedChangesScope(
      dirty: _dirty,
      busy: _saving,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(editing ? 'Malzeme Kartı' : 'Yeni Malzeme', style: AppTypography.sectionTitle),
                const SizedBox(height: AppSpacing.md),
                TextFormField(
                  key: const ValueKey('stok-kart-ad'),
                  controller: _name,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(labelText: 'Malzeme adı *'),
                  validator: (v) => (v ?? '').trim().isEmpty ? 'Zorunlu' : null,
                  onChanged: (_) => _touch(),
                ),
                const SizedBox(height: AppSpacing.sm),
                TextFormField(
                  key: const ValueKey('stok-kart-birim'),
                  controller: _unit,
                  decoration: const InputDecoration(labelText: 'Birim'),
                  onChanged: (_) => _touch(),
                ),
                const SizedBox(height: AppSpacing.xs),
                Wrap(
                  spacing: AppSpacing.xs,
                  runSpacing: AppSpacing.xs,
                  children: [
                    for (final u in _kUnits)
                      ChoiceChip(
                        label: Text(u),
                        selected: _unit.text.trim() == u,
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) => setState(() {
                          _unit.text = u;
                          _dirty = true;
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        key: const ValueKey('stok-kart-kod'),
                        controller: _code,
                        decoration: InputDecoration(labelText: 'Kod', hintText: editing ? null : 'Boşsa otomatik'),
                        onChanged: (_) => _touch(),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: TextFormField(
                        key: const ValueKey('stok-kart-barkod'),
                        controller: _barcode,
                        decoration: InputDecoration(
                          labelText: 'Barkod',
                          suffixIcon: IconButton(
                            key: const ValueKey('stok-kart-barkod-okut'),
                            tooltip: 'Okut',
                            icon: const Icon(Icons.qr_code_scanner),
                            onPressed: () async {
                              final code = await ref.read(barcodeScannerProvider)(context);
                              if (code != null && mounted) {
                                setState(() {
                                  _barcode.text = code;
                                  _dirty = true;
                                });
                              }
                            },
                          ),
                        ),
                        onChanged: (_) => _touch(),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _category,
                        decoration: const InputDecoration(labelText: 'Kategori'),
                        onChanged: (_) => _touch(),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: TextFormField(
                        key: const ValueKey('stok-kart-min'),
                        controller: _minStock,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: 'Minimum stok'),
                        validator: (v) {
                          if ((v ?? '').trim().isEmpty) return null;
                          final n = parseQtyInput(v!);
                          return n == null || n < 0 ? 'Geçersiz' : null;
                        },
                        onChanged: (_) => _touch(),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                SwitchListTile(
                  key: const ValueKey('stok-kart-skt'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Son kullanma tarihi takibi'),
                  subtitle: const Text('Çimento, yapıştırıcı, silikon, köpük, boya gibi raf ömrü olan malzemeler'),
                  value: _trackExpiry,
                  onChanged: (v) => setState(() {
                    _trackExpiry = v;
                    _dirty = true;
                  }),
                ),
                if (_trackExpiry) ...[
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          key: const ValueKey('stok-kart-raf-omru'),
                          controller: _shelfLife,
                          keyboardType: TextInputType.number,
                          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                          decoration: const InputDecoration(labelText: 'Raf ömrü (ay)', helperText: 'Üretim tarihinden SKT hesaplanır'),
                          validator: (v) {
                            final n = int.tryParse((v ?? '').trim());
                            if ((v ?? '').trim().isEmpty) return null;
                            return n == null || n < 1 || n > 120 ? '1-120' : null;
                          },
                          onChanged: (_) => _touch(),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: TextFormField(
                          key: const ValueKey('stok-kart-uyari-gun'),
                          controller: _alertDays,
                          keyboardType: TextInputType.number,
                          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                          decoration: const InputDecoration(labelText: 'Kaç gün önce uyar'),
                          validator: (v) {
                            final n = int.tryParse((v ?? '').trim());
                            return n == null || n > 365 ? '0-365' : null;
                          },
                          onChanged: (_) => _touch(),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  const Text('SKT geçince', style: AppTypography.helper),
                  const SizedBox(height: AppSpacing.xs),
                  SegmentedButton<String>(
                    key: const ValueKey('stok-kart-davranis'),
                    segments: const [
                      ButtonSegment(value: kExpiryPolicyWarn, label: Text('Uyar'), icon: Icon(Icons.warning_amber)),
                      ButtonSegment(value: kExpiryPolicyBlock, label: Text('Engelle'), icon: Icon(Icons.block)),
                    ],
                    selected: {_policy},
                    onSelectionChanged: (s) => setState(() {
                      _policy = s.first;
                      _dirty = true;
                    }),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    _policy == kExpiryPolicyBlock
                        ? 'SKT\'si geçen parti çıkış ya da aktarımla kullanılamaz; yalnızca fire olarak çıkar (ör. çimento).'
                        : 'SKT\'si geçen parti kullanılabilir ama her seferinde uyarı verilir (ör. silikon, köpük).',
                    style: AppTypography.helper,
                  ),
                ],
                const SizedBox(height: AppSpacing.sm),
                TextFormField(
                  controller: _notes,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: 'Not'),
                  onChanged: (_) => _touch(),
                ),
                if (editing)
                  SwitchListTile(
                    key: const ValueKey('stok-kart-aktif'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Aktif'),
                    subtitle: const Text('Stoğu biten kart arşive alınabilir'),
                    value: _active,
                    onChanged: (v) => setState(() {
                      _active = v;
                      _dirty = true;
                    }),
                  ),
                const SizedBox(height: AppSpacing.md),
                PrimaryButton(
                  key: const ValueKey('stok-kart-kaydet'),
                  label: 'Kaydet',
                  loading: _saving,
                  onPressed: _save,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
