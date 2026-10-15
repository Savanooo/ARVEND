import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/files/device_picker.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/access_notices.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_form_section.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/app_sheet.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/unsaved_changes_scope.dart';
import '../../dashboard/presentation/widgets/project_picker_sheet.dart';
import '../../projects/ops_team/domain/ops_dates.dart' show formatDay, istanbulToday, parseDay;
import '../data/inventory_repository.dart';
import '../domain/inventory.dart';
import '../inventory_paths.dart';
import 'inventory_common.dart';

/// Yeni stok fişi: giriş, çıkış, aktarım (inventory.manage), fire ve sayım
/// (inventory.adjust). Satırlar malzeme seçiciyle eklenir; çıkışta parti
/// seçilmezse sunucu önce bozulacak partiden düşer. Sayımda depodaki
/// bütün satırlar sistem miktarıyla gelir; yalnızca sayılanlar gönderilir.
/// Girişte irsaliye fotoğrafı eklenebilir (fiş kaydedildikten sonra yüklenir).
class InventoryDocumentFormScreen extends ConsumerStatefulWidget {
  const InventoryDocumentFormScreen({
    super.key,
    required this.docType,
    this.initialWarehouseId = '',
    this.initialItemId = '',
  });

  final String docType;
  final String initialWarehouseId;
  final String initialItemId;

  @override
  ConsumerState<InventoryDocumentFormScreen> createState() => _InventoryDocumentFormScreenState();
}

class _InventoryDocumentFormScreenState extends ConsumerState<InventoryDocumentFormScreen> {
  final _idempotencyKey = 'stk-${DateTime.now().microsecondsSinceEpoch}';
  final _counterparty = TextEditingController();
  final _referenceNo = TextEditingController();
  final _note = TextEditingController();
  String _date = inventoryToday();
  String _warehouseId = '';
  String _targetId = '';
  String _reason = '';
  String? _projectId;
  String _projectLabel = '';
  PickedDeviceFile? _photo;
  final List<InventoryLineDraft> _lines = [];
  bool _countLoaded = false;
  bool _countLoading = false;
  bool _saving = false;
  bool _dirty = false;

  String get _type => widget.docType;
  String get _title => switch (_type) {
        kDocReceipt => 'Stok Girişi',
        kDocIssue => 'Stok Çıkışı',
        kDocTransfer => 'Depolar Arası Aktarım',
        kDocWaste => 'Fire',
        kDocCount => 'Sayım',
        _ => 'Stok Fişi',
      };

  @override
  void initState() {
    super.initState();
    _warehouseId = widget.initialWarehouseId;
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    final repo = ref.read(inventoryRepositoryProvider);
    try {
      if (_warehouseId.isEmpty) {
        final whs = await ref.read(inventoryWarehousesProvider.future);
        final first = whs.where((w) => w.isActive).firstOrNull;
        if (first != null && mounted) setState(() => _warehouseId = first.id);
      }
      if (_type == kDocCount && _warehouseId.isNotEmpty) await _loadCount();
      if (widget.initialItemId.isNotEmpty && _type != kDocCount) {
        final detail = await repo.item(widget.initialItemId);
        if (mounted) setState(() => _lines.add(InventoryLineDraft(item: detail.item)));
      }
    } on ApiException catch (e) {
      _toast(e.message);
    }
  }

  @override
  void dispose() {
    _counterparty.dispose();
    _referenceNo.dispose();
    _note.dispose();
    super.dispose();
  }

  void _toast(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _touch() {
    if (!_dirty) setState(() => _dirty = true);
  }

  /// Sayım: deponun bütün bakiye satırları, sayılan boş.
  Future<void> _loadCount() async {
    setState(() => _countLoading = true);
    try {
      final rows = await ref.read(inventoryRepositoryProvider).warehouseBalances(_warehouseId);
      final page = await ref.read(inventoryItemsProvider('').future);
      final byId = {for (final i in page.items) i.id: i};
      if (!mounted) return;
      setState(() {
        _lines
          ..clear()
          ..addAll([
            for (final r in rows)
              if (byId[r.itemId] != null)
                InventoryLineDraft(
                  item: byId[r.itemId]!,
                  lotId: r.lotId,
                  lotLabel: _lotText(r.lotNo, r.expiryDate),
                  systemQuantity: r.quantity,
                ),
          ]);
        _countLoaded = true;
      });
    } on ApiException catch (e) {
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _countLoading = false);
    }
  }

  String _lotText(String lotNo, String? expiry) => [
        if (lotNo.isNotEmpty) 'Parti $lotNo',
        if (expiry != null) 'SKT ${Formatters.date(expiry)}',
      ].join(' · ');

  Future<void> _addLine() async {
    final item = await showInventoryItemPicker(context, warehouseId: _type == kDocReceipt ? '' : _warehouseId);
    if (item == null || !mounted) return;
    setState(() {
      _lines.add(InventoryLineDraft(item: item, systemQuantity: _type == kDocCount ? 0 : null));
      _dirty = true;
    });
  }

  Future<void> _pickLot(InventoryLineDraft line) async {
    final detail = await ref.read(inventoryRepositoryProvider).item(line.item.id);
    if (!mounted) return;
    final lots = detail.balances.where((b) => b.warehouseId == _warehouseId).toList();
    final picked = await showAppSheet<InventoryBalance?>(
      context: context,
      useSafeArea: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: Text('Parti Seç', style: AppTypography.sectionTitle),
            ),
            ListTile(
              key: const ValueKey('stok-parti-otomatik'),
              leading: const Icon(Icons.auto_mode),
              title: const Text('Otomatik'),
              subtitle: const Text('Önce SKT\'si yakın parti çıkar'),
              onTap: () => Navigator.of(context).pop(),
            ),
            for (final b in lots)
              ListTile(
                key: ValueKey('stok-parti-${b.lotId}'),
                title: Text(_lotText(b.lotNo, b.expiryDate).isEmpty ? 'Partisiz' : _lotText(b.lotNo, b.expiryDate)),
                trailing: Text(formatQty(b.quantity, line.item.unit)),
                onTap: () => Navigator.of(context).pop(b),
              ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    );
    if (!mounted) return;
    setState(() {
      line.lotId = picked?.lotId;
      line.lotLabel = picked == null ? '' : _lotText(picked.lotNo, picked.expiryDate);
      _dirty = true;
    });
  }

  Future<String?> _pickDate(String? current, {bool allowFuture = false}) async {
    final today = istanbulToday();
    final initial = parseDay(current) ?? today;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: allowFuture ? DateTime(2100) : today,
    );
    return picked == null ? null : formatDay(DateTime.utc(picked.year, picked.month, picked.day));
  }

  Future<void> _pickPhoto() async {
    final source = await showAppSheet<ImageSource>(
      context: context,
      useSafeArea: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Fotoğraf çek'),
              onTap: () => Navigator.of(context).pop(ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Galeriden seç'),
              onTap: () => Navigator.of(context).pop(ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    try {
      final file = await ref.read(devicePickerProvider).pickImage(source);
      if (file != null && mounted) {
        setState(() {
          _photo = file;
          _dirty = true;
        });
      }
    } on Exception {
      _toast('Fotoğraf alınamadı. Kamera ya da galeri iznini kontrol et.');
    }
  }

  String? _validate() {
    if (_warehouseId.isEmpty) return 'Depo seçin.';
    if (_type == kDocTransfer && _targetId.isEmpty) return 'Hedef depoyu seçin.';
    if (_type == kDocWaste && _reason.isEmpty) return 'Fire nedenini seçin.';
    if (_type == kDocCount) {
      if (!_lines.any((l) => l.countedQuantity != null)) return 'En az bir satırın sayılan miktarını girin.';
      return null;
    }
    if (_lines.isEmpty) return 'En az bir malzeme ekleyin.';
    for (final l in _lines) {
      if (l.quantity <= 0) return '${l.item.name}: miktar girin.';
      if (_type == kDocReceipt && l.item.trackExpiry && l.expiryDate == null && l.productionDate == null) {
        return '${l.item.name}: son kullanma tarihini girin.';
      }
    }
    return null;
  }

  Future<void> _save() async {
    final error = _validate();
    if (error != null) {
      _toast(error);
      return;
    }
    setState(() => _saving = true);
    final lines = _type == kDocCount ? _lines.where((l) => l.countedQuantity != null).toList() : _lines;
    final data = <String, dynamic>{
      'date': _date,
      'warehouse_id': _warehouseId,
      if (_type == kDocTransfer) 'target_warehouse_id': _targetId,
      if (_type == kDocIssue && _projectId != null) 'project_id': _projectId,
      'counterparty': _counterparty.text.trim(),
      'reference_no': _referenceNo.text.trim(),
      if (_type == kDocWaste) 'reason': _reason,
      'note': _note.text.trim(),
      'idempotency_key': _idempotencyKey,
      'lines': [for (final l in lines) l.toJson(_type)],
    };
    final repo = ref.read(inventoryRepositoryProvider);
    try {
      var doc = await repo.postDocument(_type, data);
      if (_photo != null) {
        try {
          doc = await repo.uploadAttachment(doc.id, _photo!.path, _photo!.name);
        } on ApiException catch (e) {
          _toast('Fiş kaydedildi ama fotoğraf yüklenemedi: ${e.message}');
        }
      }
      invalidateInventory(ref.invalidate);
      if (!mounted) return;
      setState(() => _dirty = false);
      if (doc.warnings.isNotEmpty) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Kaydedildi, dikkat'),
            content: Text(doc.warnings.join('\n')),
            actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Tamam'))],
          ),
        );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${doc.summary.docNo} kaydedildi.')));
      context.pushReplacement(inventoryDocumentPath(doc.id));
    } on ApiException catch (e) {
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    final needed = (_type == kDocWaste || _type == kDocCount) ? kInventoryAdjust : kInventoryManage;
    if (!user.canAccess(needed)) {
      return AppPageScaffold(
        title: Text(_title),
        body: const Padding(
          padding: EdgeInsets.all(AppSpacing.lg),
          child: ReadOnlyNotice('Bu stok işlemi için yetkin yok.'),
        ),
      );
    }
    return UnsavedChangesScope(
      dirty: _dirty,
      busy: _saving,
      child: AppPageScaffold(
        title: Text(_title),
        body: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(AppSpacing.lg),
                children: [
                  AppFormSection(
                    title: 'Fiş',
                    children: [
                      WarehouseDropdown(
                        value: _warehouseId,
                        label: _type == kDocTransfer ? 'Kaynak depo' : 'Depo',
                        onChanged: (v) async {
                          setState(() {
                            _warehouseId = v ?? '';
                            _dirty = true;
                            if (_type != kDocReceipt) {
                              for (final l in _lines) {
                                l.lotId = null;
                                l.lotLabel = '';
                              }
                            }
                          });
                          if (_type == kDocCount && _warehouseId.isNotEmpty) await _loadCount();
                        },
                      ),
                      if (_type == kDocTransfer)
                        WarehouseDropdown(
                          value: _targetId,
                          label: 'Hedef depo',
                          exclude: _warehouseId,
                          onChanged: (v) => setState(() {
                            _targetId = v ?? '';
                            _dirty = true;
                          }),
                        ),
                      _DateField(
                        label: 'Tarih',
                        value: _date,
                        onTap: () async {
                          final d = await _pickDate(_date);
                          if (d != null) setState(() => _date = d);
                        },
                      ),
                      if (_type == kDocReceipt) ...[
                        TextField(
                          key: const ValueKey('stok-fis-kimden'),
                          controller: _counterparty,
                          decoration: const InputDecoration(labelText: 'Tedarikçi / kimden'),
                          onChanged: (_) => _touch(),
                        ),
                        TextField(
                          key: const ValueKey('stok-fis-irsaliye'),
                          controller: _referenceNo,
                          decoration: const InputDecoration(labelText: 'İrsaliye no'),
                          onChanged: (_) => _touch(),
                        ),
                        _PhotoField(photo: _photo, onPick: _pickPhoto, onClear: () => setState(() => _photo = null)),
                      ],
                      if (_type == kDocIssue) ...[
                        TextField(
                          key: const ValueKey('stok-fis-kime'),
                          controller: _counterparty,
                          decoration: const InputDecoration(labelText: 'Kime verildi'),
                          onChanged: (_) => _touch(),
                        ),
                        if (user.canAccess('projects.read'))
                          _ProjectField(
                            label: _projectLabel,
                            onPick: () async {
                              final p = await showProjectPickerSheet(context);
                              if (p != null && mounted) {
                                setState(() {
                                  _projectId = p.id;
                                  _projectLabel = [p.projectNo, p.name].where((v) => v.isNotEmpty).join(' · ');
                                  _dirty = true;
                                });
                              }
                            },
                            onClear: () => setState(() {
                              _projectId = null;
                              _projectLabel = '';
                            }),
                          ),
                      ],
                      if (_type == kDocWaste)
                        DropdownButtonFormField<String>(
                          key: const ValueKey('stok-fis-fire-nedeni'),
                          initialValue: _reason.isEmpty ? null : _reason,
                          decoration: const InputDecoration(labelText: 'Fire nedeni *'),
                          items: [
                            for (final e in kWasteReasons.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
                          ],
                          onChanged: (v) => setState(() {
                            _reason = v ?? '';
                            _dirty = true;
                          }),
                        ),
                    ],
                  ),
                  AppFormSection(
                    title: _type == kDocCount ? 'Sayılan Miktarlar' : 'Malzemeler',
                    subtitle: switch (_type) {
                      kDocCount => 'Yalnızca saydığın satırları doldur; boş bırakılanlar değişmez.',
                      kDocIssue || kDocTransfer || kDocWaste => 'Parti seçmezsen SKT\'si en yakın parti önce düşer.',
                      _ => null,
                    },
                    children: [
                      if (_type == kDocCount && _countLoading) const LoadingState(),
                      if (_type == kDocCount && _countLoaded && _lines.isEmpty)
                        const Text('Bu depoda stok yok. Sayımda bulduğun malzemeyi ekleyebilirsin.', style: AppTypography.helper),
                      for (final l in _lines)
                        _LineCard(
                          key: ValueKey('stok-satir-${l.item.id}-${l.lotId ?? ''}-${_lines.indexOf(l)}'),
                          line: l,
                          docType: _type,
                          onChanged: _touch,
                          onRemove: () => setState(() {
                            _lines.remove(l);
                            _dirty = true;
                          }),
                          onPickLot: () => _pickLot(l),
                          onPickDate: (production) async {
                            final d = await _pickDate(production ? l.productionDate : l.expiryDate, allowFuture: !production);
                            if (d != null) {
                              setState(() {
                                if (production) {
                                  l.productionDate = d;
                                } else {
                                  l.expiryDate = d;
                                }
                                _dirty = true;
                              });
                            }
                          },
                        ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          key: const ValueKey('stok-satir-ekle'),
                          onPressed: _addLine,
                          icon: const Icon(Icons.add),
                          label: const Text('Malzeme ekle'),
                        ),
                      ),
                    ],
                  ),
                  TextField(
                    key: const ValueKey('stok-fis-not'),
                    controller: _note,
                    maxLines: 2,
                    decoration: const InputDecoration(labelText: 'Not'),
                    onChanged: (_) => _touch(),
                  ),
                ],
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.sm),
                child: SizedBox(
                  width: double.infinity,
                  child: PrimaryButton(
                    key: const ValueKey('stok-fis-kaydet'),
                    label: 'Kaydet',
                    icon: Icons.check,
                    loading: _saving,
                    onPressed: _save,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DateField extends StatelessWidget {
  const _DateField({required this.label, required this.value, required this.onTap});

  final String label;
  final String? value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: const ValueKey('stok-fis-tarih'),
      onTap: onTap,
      child: InputDecorator(
        decoration: InputDecoration(labelText: label, isDense: true, suffixIcon: const Icon(Icons.calendar_today, size: 18)),
        child: Text(value == null ? '—' : Formatters.date(value!)),
      ),
    );
  }
}

class _PhotoField extends StatelessWidget {
  const _PhotoField({required this.photo, required this.onPick, required this.onClear});

  final PickedDeviceFile? photo;
  final VoidCallback onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    if (photo == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const ValueKey('stok-fis-foto'),
          onPressed: onPick,
          icon: const Icon(Icons.add_a_photo_outlined),
          label: const Text('İrsaliye fotoğrafı ekle'),
        ),
      );
    }
    return Row(
      children: [
        const Icon(Icons.image_outlined, color: AppColors.success),
        const SizedBox(width: AppSpacing.xs),
        Expanded(child: Text(photo!.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
        IconButton(tooltip: 'Kaldır', onPressed: onClear, icon: const Icon(Icons.close)),
      ],
    );
  }
}

class _ProjectField extends StatelessWidget {
  const _ProjectField({required this.label, required this.onPick, required this.onClear});

  final String label;
  final VoidCallback onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: const ValueKey('stok-fis-proje'),
      onTap: onPick,
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: 'Proje (isteğe bağlı, yalnızca bilgi)',
          isDense: true,
          suffixIcon: label.isEmpty
              ? const Icon(Icons.chevron_right)
              : IconButton(icon: const Icon(Icons.close, size: 18), onPressed: onClear),
        ),
        child: Text(label.isEmpty ? 'Seçilmedi' : label),
      ),
    );
  }
}

/// Fiş satırı: türüne göre miktar, birim fiyat, parti/SKT ya da sayılan.
class _LineCard extends StatefulWidget {
  const _LineCard({
    super.key,
    required this.line,
    required this.docType,
    required this.onChanged,
    required this.onRemove,
    required this.onPickLot,
    required this.onPickDate,
  });

  final InventoryLineDraft line;
  final String docType;
  final VoidCallback onChanged;
  final VoidCallback onRemove;
  final VoidCallback onPickLot;
  final void Function(bool production) onPickDate;

  @override
  State<_LineCard> createState() => _LineCardState();
}

class _LineCardState extends State<_LineCard> {
  late final _qty = TextEditingController(
    text: widget.docType == kDocCount ? qtyInputText(widget.line.countedQuantity) : qtyInputText(
        widget.line.quantity > 0 ? widget.line.quantity : null),
  );
  late final _cost = TextEditingController(text: qtyInputText(widget.line.unitCost));
  late final _lotNo = TextEditingController(text: widget.line.lotNo);

  @override
  void dispose() {
    _qty.dispose();
    _cost.dispose();
    _lotNo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.line;
    final it = l.item;
    final isCount = widget.docType == kDocCount;
    final isReceipt = widget.docType == kDocReceipt;
    final takesOut = !isCount && !isReceipt;
    final showLotEntry = isReceipt || (isCount && l.lotId == null && it.trackExpiry);
    return Container(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xs, AppSpacing.xs, AppSpacing.sm),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(it.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppTypography.cardTitle),
                    Text(
                      [
                        it.code,
                        if (l.lotLabel.isNotEmpty) l.lotLabel,
                        if (isCount && l.systemQuantity != null) 'Sistemde ${formatQty(l.systemQuantity!, it.unit)}',
                      ].join(' · '),
                      style: AppTypography.helper,
                    ),
                  ],
                ),
              ),
              if (!isCount || l.systemQuantity == 0)
                IconButton(tooltip: 'Satırı çıkar', onPressed: widget.onRemove, icon: const Icon(Icons.close, size: 18)),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.sm),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: ValueKey('stok-satir-miktar-${it.id}'),
                    controller: _qty,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: isCount ? 'Sayılan' : 'Miktar',
                      suffixText: it.unit,
                      isDense: true,
                    ),
                    onChanged: (v) {
                      final n = parseQtyInput(v);
                      if (isCount) {
                        l.countedQuantity = n;
                      } else {
                        l.quantity = n ?? 0;
                      }
                      widget.onChanged();
                    },
                  ),
                ),
                if (isReceipt) ...[
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: TextField(
                      key: ValueKey('stok-satir-fiyat-${it.id}'),
                      controller: _cost,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Birim fiyat', helperText: 'KDV hariç', isDense: true),
                      onChanged: (v) {
                        l.unitCost = parseQtyInput(v);
                        widget.onChanged();
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (takesOut && it.trackExpiry)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: ValueKey('stok-satir-parti-${it.id}'),
                onPressed: widget.onPickLot,
                icon: const Icon(Icons.layers_outlined, size: 18),
                label: Text(l.lotLabel.isEmpty ? 'Parti: otomatik' : 'Parti değiştir'),
              ),
            ),
          if (showLotEntry) ...[
            const SizedBox(height: AppSpacing.xs),
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.sm),
              child: TextField(
                key: ValueKey('stok-satir-parti-no-${it.id}'),
                controller: _lotNo,
                decoration: const InputDecoration(labelText: 'Parti no (isteğe bağlı)', isDense: true),
                onChanged: (v) {
                  l.lotNo = v;
                  widget.onChanged();
                },
              ),
            ),
            if (it.trackExpiry || isReceipt)
              Wrap(
                spacing: AppSpacing.sm,
                children: [
                  TextButton.icon(
                    key: ValueKey('stok-satir-skt-${it.id}'),
                    onPressed: () => widget.onPickDate(false),
                    icon: const Icon(Icons.event_outlined, size: 18),
                    label: Text(l.expiryDate == null
                        ? (it.trackExpiry ? 'SKT gir *' : 'SKT (varsa)')
                        : 'SKT ${Formatters.date(l.expiryDate!)}'),
                  ),
                  if (it.trackExpiry && it.shelfLifeMonths != null)
                    TextButton.icon(
                      key: ValueKey('stok-satir-uretim-${it.id}'),
                      onPressed: () => widget.onPickDate(true),
                      icon: const Icon(Icons.factory_outlined, size: 18),
                      label: Text(l.productionDate == null
                          ? 'ya da üretim tarihi'
                          : 'Üretim ${Formatters.date(l.productionDate!)} (+${it.shelfLifeMonths} ay)'),
                    ),
                ],
              ),
          ],
        ],
      ),
    );
  }
}
