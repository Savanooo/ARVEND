import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/auth/auth_controller.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/access_notices.dart';
import '../../../../core/widgets/app_buttons.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_form_section.dart';
import '../../../../core/widgets/app_page_scaffold.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../../../../core/widgets/unsaved_changes_scope.dart';
import '../../../../core/utils/formatters.dart';
import '../../budget/domain/budget.dart' show formatTrDecimalInput, parseTrDecimal;
import '../../data/projects_providers.dart';
import '../contract_co_paths.dart';
import '../data/contract_co_providers.dart';
import '../domain/project_change_order.dart';
import 'widgets/contract_co_ui.dart';

/// Ek iş kalemlerinin sayı alanları -- bütçe/masraf/tahsilat formlarıyla
/// AYNI Türkçe kural ([parseTrDecimal]): "8.500" = sekiz bin beş yüz,
/// "1.250,50" = bin iki yüz elli virgül elli, "12,5" / "12.5" = on iki
/// buçuk. Miktar/birim fiyat/KDV sütunları numeric(…, 2): en çok 2 ondalık.
/// "NaN"/"Infinity" gibi girdiler reddedilir. Boş ya da geçersizse `null`.
double? parseChangeOrderNumber(String raw) => parseTrDecimal(raw).value;

/// Mevcut bir değeri alana yazmak için (gruplamasız, ondalık virgül) --
/// [parseChangeOrderNumber] ile birebir geri okunur.
String _numText(double v) => formatTrDecimalInput(v);

/// Sunucunun toplam hesabının (SQL `round(q*p, 2)`, KDV `round(ara*oran/100,
/// 2)`) önizlemesi -- yalnızca yanlış büyüklüğün (ör. 8,50 yerine 8.500)
/// kayıttan ÖNCE görünmesi için. Kesin toplamı kayıtta sunucu hesaplar.
double _round2(double v) => (v * 100).roundToDouble() / 100;

/// Formdaki bir kalem satırı. `productId`/`estimatedUnitCost` formda
/// gösterilmez ama mevcut bir kalemden KORUNUR -- PUT kalemleri tümden
/// değiştirdiği için gönderilmezse sessizce silinirdi (web formunun
/// kaybettiği iki alan).
class _DraftItem {
  _DraftItem({this.description = '', this.quantity = '1', this.unit = 'adet', this.unitPrice = ''});

  factory _DraftItem.from(ProjectChangeOrderItem item) => _DraftItem(
        description: item.description,
        quantity: _numText(item.quantity),
        unit: item.unit,
        unitPrice: _numText(item.unitPrice),
      )
        ..productId = item.productId
        ..estimatedUnitCost = item.estimatedUnitCost;

  String description;
  String quantity;
  String unit;
  String unitPrice;
  String? productId;
  double? estimatedUnitCost;

  /// Hiç dokunulmamış (varsayılanlarla duran) satır gönderilmez.
  bool get isBlank => description.trim().isEmpty && unitPrice.trim().isEmpty;

  /// Satır toplamı önizlemesi; miktar ya da birim fiyat geçersizse `null`.
  double? get lineTotal {
    final q = parseChangeOrderNumber(quantity);
    final p = parseChangeOrderNumber(unitPrice);
    if (q == null || p == null || q <= 0 || p <= 0) return null;
    return _round2(q * p);
  }

  String get signature => '$description|$quantity|$unit|$unitPrice|$productId|$estimatedUnitCost';
}

/// Ek İş oluştur / düzenle (`/projeler/:id/ek-isler/yeni`,
/// `/projeler/:id/ek-isler/:coId/duzenle`). Web ChangeOrderSections'ın
/// oluşturma + düzenleme formlarının birleşimi: tür (Ek İş/Eksiltme),
/// başlık, kalemler (teklif kalemleriyle aynı: açıklama, miktar, birim,
/// birim fiyat), KDV %, müşteriye görünecek not ve dahili not. Toplamlar
/// kayıtta SUNUCUDA hesaplanır. Yalnızca taslak düzenlenir; izin
/// `projects.finance.manage`.
class ChangeOrderFormScreen extends ConsumerWidget {
  const ChangeOrderFormScreen({super.key, required this.projectId, this.changeOrderId});

  final String projectId;
  final String? changeOrderId;

  bool get isEdit => changeOrderId != null;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final title = Text(isEdit ? 'Ek İşi Düzenle' : 'Yeni Ek İş');
    final auth = ref.watch(authControllerProvider);
    if (isAuthPending(auth)) return AppPageScaffold(title: title, body: const LoadingState());
    final user = auth.valueOrNull;
    if (!user.can(kChangeOrdersManagePermission)) {
      return AppPageScaffold(
        title: title,
        body: const NoAccessView(
          message: 'Ek iş oluşturma/düzenleme yetkin yok. Bunun için rolünde "Proje finansal işlemlerini '
              'yönetme" izni olmalı.',
        ),
      );
    }
    final projectAsync = ref.watch(projectDetailProvider(projectId));
    if (isProjectLocked(projectAsync.valueOrNull)) {
      return AppPageScaffold(
        title: title,
        body: const Padding(padding: EdgeInsets.all(AppSpacing.lg), child: ReadOnlyNotice(kProjectLockedText)),
      );
    }
    final currency = projectAsync.valueOrNull?.currency ?? 'TRY';

    if (!isEdit) {
      return AppPageScaffold(title: title, body: _ChangeOrderForm(projectId: projectId, currency: currency));
    }
    final key = (projectId: projectId, changeOrderId: changeOrderId!);
    final detailAsync = ref.watch(projectChangeOrderDetailProvider(key));
    return AppPageScaffold(
      title: title,
      body: detailAsync.when(
        loading: () => const LoadingState(),
        error: (e, _) => isForbiddenError(e)
            ? const NoAccessView(message: kChangeOrdersNoAccessText)
            : ErrorState(error: e, onRetry: () async => ref.invalidate(projectChangeOrderDetailProvider(key))),
        data: (co) => co.isEditable
            ? _ChangeOrderForm(projectId: projectId, currency: co.currency, initial: co)
            : const Padding(
                padding: EdgeInsets.all(AppSpacing.lg),
                child: ReadOnlyNotice('Yalnızca taslak durumundaki ek işler düzenlenebilir.'),
              ),
      ),
    );
  }
}

class _ChangeOrderForm extends ConsumerStatefulWidget {
  const _ChangeOrderForm({required this.projectId, required this.currency, this.initial});

  final String projectId;
  final String currency;
  final ProjectChangeOrder? initial;

  @override
  ConsumerState<_ChangeOrderForm> createState() => _ChangeOrderFormState();
}

class _ChangeOrderFormState extends ConsumerState<_ChangeOrderForm> {
  final _formKey = GlobalKey<FormState>();
  late String _changeType = widget.initial?.changeType ?? ProjectChangeOrder.typeAddition;
  late final _title = TextEditingController(text: widget.initial?.title ?? '');
  late final _description = TextEditingController(text: widget.initial?.description ?? '');
  late final _vatRate = TextEditingController(text: widget.initial == null ? '20' : _numText(widget.initial!.vatRate));
  late final _customerNotes = TextEditingController(text: widget.initial?.customerNotes ?? '');
  late final _internalNotes = TextEditingController(text: widget.initial?.internalNotes ?? '');
  late final List<_DraftItem> _items = [
    ...?widget.initial?.items.map(_DraftItem.from),
  ];
  late final String _initialSignature;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (_items.isEmpty) _items.add(_DraftItem());
    _initialSignature = _signature;
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _vatRate.dispose();
    _customerNotes.dispose();
    _internalNotes.dispose();
    super.dispose();
  }

  String get _signature => [
        _changeType,
        _title.text,
        _description.text,
        _vatRate.text,
        _customerNotes.text,
        _internalNotes.text,
        for (final i in _items) i.signature,
      ].join('\u0001');

  bool get _dirty => _signature != _initialSignature;

  Future<void> _submit() async {
    setState(() => _error = null);
    if (!_formKey.currentState!.validate()) return;
    final items = <ChangeOrderItemInput>[
      for (final i in _items)
        if (!i.isBlank)
          ChangeOrderItemInput(
            productId: i.productId,
            description: i.description.trim(),
            quantity: parseChangeOrderNumber(i.quantity)!,
            unit: i.unit.trim(),
            unitPrice: parseChangeOrderNumber(i.unitPrice)!,
            estimatedUnitCost: i.estimatedUnitCost,
          ),
    ];
    if (items.isEmpty) {
      setState(() => _error = 'En az bir kalem girilmeli ve toplam sıfırdan büyük olmalıdır.');
      return;
    }
    final input = ChangeOrderInput(
      changeType: _changeType,
      title: _title.text.trim(),
      description: _description.text.trim(),
      vatRate: parseChangeOrderNumber(_vatRate.text) ?? 0,
      customerNotes: _customerNotes.text.trim(),
      internalNotes: _internalNotes.text.trim(),
      items: items,
    );

    setState(() => _submitting = true);
    // Tazeleme, ekran bu arada kapansa da yapılsın diye kapsayıcı ilk
    // await'ten ÖNCE alınır (bkz. invalidateChangeOrders).
    final invalidate = ProviderScope.containerOf(context, listen: false).invalidate;
    final repo = ref.read(contractCoRepositoryProvider);
    try {
      final initial = widget.initial;
      if (initial == null) {
        final created = await repo.createChangeOrder(widget.projectId, input);
        invalidateChangeOrders(invalidate, widget.projectId);
        if (!mounted) return;
        setState(() => _submitting = false);
        showContractCoSnack(context, '${created.changeOrderNo} oluşturuldu.');
        context.pushReplacement(projectChangeOrderPath(widget.projectId, created.id));
      } else {
        await repo.updateChangeOrder(widget.projectId, initial.id, input);
        invalidateChangeOrders(invalidate, widget.projectId, changeOrderId: initial.id);
        if (!mounted) return;
        setState(() => _submitting = false);
        showContractCoSnack(context, '${initial.changeOrderNo} kaydedildi.');
        if (context.canPop()) {
          context.pop();
        } else {
          context.go(projectChangeOrderPath(widget.projectId, initial.id));
        }
      }
    } catch (e) {
      // 409: bu arada gönderildi/iptal edildi -- detay güncel duruma dönsün.
      if (isConflictError(e) && widget.initial != null) {
        invalidateChangeOrders(invalidate, widget.projectId, changeOrderId: widget.initial!.id);
      }
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = contractCoErrorText(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return UnsavedChangesScope(
      dirty: _dirty,
      busy: _submitting,
      child: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
          children: [
            if (widget.initial != null) ...[
              Text(widget.initial!.changeOrderNo, style: AppTypography.metadata),
              const SizedBox(height: AppSpacing.sm),
            ],
            AppFormSection(
              title: 'Temel Bilgiler',
              children: [
                DropdownButtonFormField<String>(
                  initialValue: _changeType,
                  decoration: const InputDecoration(labelText: 'Tür'),
                  items: [
                    for (final e in kChangeOrderTypeLabels.entries)
                      DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: (v) => setState(() => _changeType = v ?? ProjectChangeOrder.typeAddition),
                ),
                TextFormField(
                  controller: _title,
                  decoration: const InputDecoration(labelText: 'Başlık *'),
                  textCapitalization: TextCapitalization.sentences,
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Ek iş başlığı zorunludur' : null,
                  onChanged: (_) => setState(() {}),
                ),
                TextFormField(
                  controller: _description,
                  decoration: const InputDecoration(labelText: 'Açıklama (opsiyonel)', alignLabelWithHint: true),
                  minLines: 2,
                  maxLines: 4,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (_) => setState(() {}),
                ),
              ],
            ),
            AppFormSection(
              title: 'Kalemler',
              subtitle: 'Kesin toplamlar kayıtta hesaplanır; aşağıdaki önizleme yanlış bir tutarı kaydetmeden önce '
                  'fark etmen içindir.',
              spacing: AppSpacing.sm,
              children: [
                for (var i = 0; i < _items.length; i++)
                  _ItemEditor(
                    key: ObjectKey(_items[i]),
                    index: i,
                    item: _items[i],
                    currency: widget.currency,
                    onChanged: () => setState(() {}),
                    onRemove: _items.length > 1 ? () => setState(() => _items.removeAt(i)) : null,
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Kalem Ekle'),
                    onPressed: () => setState(() => _items.add(_DraftItem())),
                  ),
                ),
                _TotalsPreview(items: _items, vatRateText: _vatRate.text, currency: widget.currency),
              ],
            ),
            AppFormSection(
              title: 'Vergi ve Notlar',
              children: [
                TextFormField(
                  controller: _vatRate,
                  decoration: const InputDecoration(labelText: 'KDV (%) *'),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  validator: (v) {
                    final parsed = parseTrDecimal(v ?? '');
                    if (parsed.error != null) return parsed.error;
                    final n = parsed.value;
                    if (n == null) return 'KDV oranı zorunludur';
                    if (n > 100) return 'KDV oranı en fazla %100 olabilir';
                    return null;
                  },
                  onChanged: (_) => setState(() {}),
                ),
                TextFormField(
                  controller: _customerNotes,
                  decoration: const InputDecoration(labelText: 'Müşteriye görünecek not', alignLabelWithHint: true),
                  minLines: 1,
                  maxLines: 4,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (_) => setState(() {}),
                ),
                TextFormField(
                  controller: _internalNotes,
                  decoration: const InputDecoration(labelText: 'Dahili not (yalnızca ekip görür)', alignLabelWithHint: true),
                  minLines: 1,
                  maxLines: 4,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (_) => setState(() {}),
                ),
              ],
            ),
            if (_error != null) ...[
              Text(_error!, style: AppTypography.error),
              const SizedBox(height: AppSpacing.md),
            ],
            PrimaryButton(
              label: widget.initial == null ? 'Oluştur' : 'Kaydet',
              loading: _submitting,
              onPressed: _submit,
            ),
          ],
        ),
      ),
    );
  }
}

class _ItemEditor extends StatelessWidget {
  const _ItemEditor({
    super.key,
    required this.index,
    required this.item,
    required this.currency,
    required this.onChanged,
    this.onRemove,
  });

  final int index;
  final _DraftItem item;
  final String currency;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    String? requiredIfFilled(String? v, String message) => item.isBlank || (v != null && v.trim().isNotEmpty) ? null : message;

    String? positive(String? v, String message) {
      if (item.isBlank) return null;
      final parsed = parseTrDecimal(v ?? '');
      if (parsed.error != null) return parsed.error;
      final n = parsed.value;
      return (n == null || n <= 0) ? message : null;
    }

    final lineTotal = item.lineTotal;

    return AppCard(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.xs, AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text('Kalem ${index + 1}', style: AppTypography.cardTitle)),
              if (onRemove != null)
                IconButton(
                  tooltip: 'Kalemi Sil',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 18, color: AppColors.textMuted),
                  onPressed: onRemove,
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  initialValue: item.description,
                  decoration: const InputDecoration(labelText: 'Kalem açıklaması *', isDense: true),
                  textCapitalization: TextCapitalization.sentences,
                  validator: (v) => requiredIfFilled(v, 'Kalem açıklaması zorunludur'),
                  onChanged: (v) {
                    item.description = v;
                    onChanged();
                  },
                ),
                const SizedBox(height: AppSpacing.sm),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextFormField(
                        initialValue: item.quantity,
                        decoration: const InputDecoration(labelText: 'Miktar *', isDense: true),
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        validator: (v) => positive(v, 'Sıfırdan büyük olmalı'),
                        onChanged: (v) {
                          item.quantity = v;
                          onChanged();
                        },
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      flex: 2,
                      child: TextFormField(
                        initialValue: item.unit,
                        decoration: const InputDecoration(labelText: 'Birim', isDense: true),
                        onChanged: (v) {
                          item.unit = v;
                          onChanged();
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                TextFormField(
                  initialValue: item.unitPrice,
                  decoration: InputDecoration(
                    labelText: 'Birim Fiyat ($currency) *',
                    isDense: true,
                    // Satır toplamı önizlemesi: "8.500" -> 8.500,00 TL mi
                    // yoksa 8,50 TL mi, kayıttan önce görünsün.
                    helperText: lineTotal == null
                        ? null
                        : 'Satır toplamı: ${Formatters.money(lineTotal, currency: currency)}',
                  ),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  validator: (v) => positive(v, 'Birim fiyat sıfırdan büyük olmalı'),
                  onChanged: (v) {
                    item.unitPrice = v;
                    onChanged();
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Kalemlerin altındaki Ara Toplam / KDV / Toplam önizlemesi (sunucu
/// formülüyle aynı yuvarlama). Geçerli satır yoksa çizilmez.
class _TotalsPreview extends StatelessWidget {
  const _TotalsPreview({required this.items, required this.vatRateText, required this.currency});

  final List<_DraftItem> items;
  final String vatRateText;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final totals = [for (final i in items) if (!i.isBlank) i.lineTotal].whereType<double>().toList();
    if (totals.isEmpty) return const SizedBox.shrink();
    final subtotal = _round2(totals.fold<double>(0, (a, b) => a + b));
    final rate = parseChangeOrderNumber(vatRateText) ?? 0;
    final vat = _round2(subtotal * rate / 100);
    return AppCard(
      key: const ValueKey('change-order-totals-preview'),
      child: Column(
        children: [
          ContractCoValueRow(label: 'Ara Toplam', value: Formatters.money(subtotal, currency: currency)),
          ContractCoValueRow(
            label: 'KDV (${Formatters.percent(rate)})',
            value: Formatters.money(vat, currency: currency),
          ),
          const Divider(height: AppSpacing.lg),
          ContractCoValueRow(
            label: 'Toplam',
            value: Formatters.money(subtotal + vat, currency: currency),
            emphasize: true,
          ),
        ],
      ),
    );
  }
}
