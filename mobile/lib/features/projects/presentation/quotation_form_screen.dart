import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_shadows.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_data_row.dart';
import '../../../core/widgets/app_form_section.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/async_state_view.dart';
import '../data/projects_providers.dart';
import '../domain/procurement.dart';
import '../domain/subcontract.dart' show Supplier;
import 'form_number_input.dart';

class _DraftItem {
  _DraftItem({
    required this.rfqItemId,
    required this.description,
    required this.unit,
  });

  final String rfqItemId;
  final String description;
  final String unit;
  String quantity = '';
  String unitPrice = '';
  String notes = '';

  /// Birim fiyatı boş bırakılan RFQ kalemi "teklif edilmedi" demektir ve
  /// gönderilmez. Fiyatı yazılmış ama geçersiz bir satır ise kendi alanında
  /// hata gösterir ve kaydı durdurur (eskiden sessizce atlanırdı).
  bool get isBlank => unitPrice.trim().isEmpty;
}

String? _fmtDate(DateTime? d) {
  if (d == null) return null;
  return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

DateTime? _parseDate(String? s) {
  if (s == null || s.isEmpty) return null;
  return DateTime.tryParse(s);
}

/// P3 — Tedarikçi Teklifi Ekle/Düzenle. Kalemler DİNAMİK bir liste
/// DEĞİLDİR -- RFQ'nun KENDİ kalem listesindeki her satır için bir fiyat
/// girilir (backend `rfq_item_id` bazlı çalışır, bkz. Phase 1). `currency`/
/// `subtotal`/`tax`/`total` bu formda HİÇ YOK -- backend hesaplar, mobil
/// bunları asla göstermeye/göndermeye ÇALIŞMAZ.
class QuotationFormScreen extends ConsumerStatefulWidget {
  const QuotationFormScreen({
    super.key,
    required this.projectId,
    required this.rfqId,
    this.quotationId,
  });

  final String projectId;
  final String rfqId;
  final String? quotationId;

  bool get isEdit => quotationId != null;

  @override
  ConsumerState<QuotationFormScreen> createState() =>
      _QuotationFormScreenState();
}

class _QuotationFormScreenState extends ConsumerState<QuotationFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _quotationNumberController = TextEditingController();
  final _discountController = TextEditingController(text: '0');
  final _taxRateController = TextEditingController(text: '20');
  final _deliveryDaysController = TextEditingController();
  final _paymentTermsController = TextEditingController();
  final _notesController = TextEditingController();
  final List<_DraftItem> _items = [];
  String? _supplierId;
  String? _supplierLabel;
  DateTime? _quotationDate;
  DateTime? _validUntil;
  bool _loading = true;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _quotationDate = DateTime.now();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final repo = ref.read(projectsRepositoryProvider);
      final rfqDetail = await repo.rfqDetail(widget.projectId, widget.rfqId);
      // Award, status'u AYNI atomik UPDATE'te 'closed' yapar -- yani
      // status=='issued' olmak zaten awardedQuotationId==null anlamına
      // gelir (bkz. Phase 1). Bu, backend'deki `requireOpenRFQForQuotation`
      // kapısıyla AYNI koşuldur.
      if (rfqDetail.rfq.status != RFQ.statusIssued) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = widget.isEdit
              ? 'Bu RFQ artık açık değil -- teklif düzenlenemez.'
              : 'Bu RFQ açık değil (yayınlanmış ve ödüllendirilmemiş olmalı) -- yeni teklif eklenemez.';
        });
        return;
      }

      if (widget.isEdit) {
        final detail = await repo.quotationDetail(
          widget.projectId,
          widget.rfqId,
          widget.quotationId!,
        );
        final q = detail.quotation;
        _supplierId = q.supplierId;
        // `GetQuotation` (bare, tek teklif) supplier_name/code TAŞIMAZ (bkz.
        // Phase 1) -- bu yüzden RFQ'nun davetli tedarikçi listesinden
        // eşleştirilir.
        _supplierLabel = q.supplierId;
        for (final s in rfqDetail.suppliers) {
          if (s.supplierId == q.supplierId && s.supplierName.isNotEmpty) {
            _supplierLabel = s.supplierName;
            break;
          }
        }
        _quotationNumberController.text = q.quotationNumber;
        _quotationDate = _parseDate(q.quotationDate);
        _validUntil = _parseDate(q.validUntil);
        _discountController.text = formNumberText(q.discount);
        _taxRateController.text = formNumberText(q.taxRate);
        _deliveryDaysController.text = q.deliveryDays?.toString() ?? '';
        _paymentTermsController.text = q.paymentTerms;
        _notesController.text = q.notes;
        final existingByRfqItem = {
          for (final it in detail.items) it.rfqItemId: it,
        };
        for (final rfqItem in rfqDetail.items) {
          final draft = _DraftItem(
            rfqItemId: rfqItem.id,
            description: rfqItem.description,
            unit: rfqItem.unit,
          );
          final existing = existingByRfqItem[rfqItem.id];
          if (existing != null) {
            draft.quantity = formNumberText(existing.quantity);
            draft.unitPrice = formNumberText(existing.unitPrice);
            draft.notes = existing.notes;
          } else {
            draft.quantity = formNumberText(rfqItem.quantity);
          }
          _items.add(draft);
        }
      } else {
        for (final rfqItem in rfqDetail.items) {
          _items.add(
            _DraftItem(
              rfqItemId: rfqItem.id,
              description: rfqItem.description,
              unit: rfqItem.unit,
            )..quantity = formNumberText(rfqItem.quantity),
          );
        }
      }
      if (!mounted) return;
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
    _quotationNumberController.dispose();
    _discountController.dispose();
    _taxRateController.dispose();
    _deliveryDaysController.dispose();
    _paymentTermsController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  /// Form doğrulandıktan SONRA çağrılır: fiyatı girilmiş her satır geçerlidir.
  List<QuotationItem> _buildItems() => [
        for (final i in _items)
          if (!i.isBlank)
            QuotationItem(
              id: '',
              rfqItemId: i.rfqItemId,
              quantity: parseFormNumber(i.quantity)!,
              unitPrice: parseFormNumber(i.unitPrice)!,
              lineTotal: 0,
              notes: i.notes,
            ),
      ];

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (!widget.isEdit && (_supplierId == null || _supplierId!.isEmpty)) {
      setState(() => _error = 'Tedarikçi seçin.');
      return;
    }
    final items = _buildItems();
    if (items.isEmpty) {
      setState(
        () => _error = 'En az bir kalem için miktar ve birim fiyat girin.',
      );
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final repo = ref.read(projectsRepositoryProvider);
      final discount = parseFormNumber(_discountController.text) ?? 0;
      final taxRate = parseFormPercent(_taxRateController.text) ?? 0;
      final deliveryDays = int.tryParse(_deliveryDaysController.text);
      final Quotation q;
      if (widget.isEdit) {
        q = await repo.updateQuotation(
          widget.projectId,
          widget.rfqId,
          widget.quotationId!,
          quotationNumber: _quotationNumberController.text.trim(),
          quotationDate: _fmtDate(_quotationDate),
          validUntil: _fmtDate(_validUntil),
          discount: discount,
          taxRate: taxRate,
          deliveryDays: deliveryDays,
          paymentTerms: _paymentTermsController.text.trim(),
          notes: _notesController.text.trim(),
          items: items,
        );
      } else {
        q = await repo.createQuotation(
          widget.projectId,
          widget.rfqId,
          supplierId: _supplierId!,
          quotationNumber: _quotationNumberController.text.trim(),
          quotationDate: _fmtDate(_quotationDate),
          validUntil: _fmtDate(_validUntil),
          discount: discount,
          taxRate: taxRate,
          deliveryDays: deliveryDays,
          paymentTerms: _paymentTermsController.text.trim(),
          notes: _notesController.text.trim(),
          items: items,
        );
      }
      final rfqArgs = (projectId: widget.projectId, rfqId: widget.rfqId);
      ref.invalidate(rfqQuotationsProvider(rfqArgs));
      ref.invalidate(bidComparisonProvider(rfqArgs));
      if (widget.isEdit) {
        ref.invalidate(
          quotationDetailProvider((
            projectId: widget.projectId,
            rfqId: widget.rfqId,
            quotationId: widget.quotationId!,
          )),
        );
      }
      if (mounted) context.pop(q);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final suppliersAsync = ref.watch(suppliersProvider);

    return AppPageScaffold(
      title: Text(widget.isEdit ? 'Teklifi Düzenle' : 'Yeni Teklif'),
      body: _loading
          ? const LoadingState()
          : (_error != null && _items.isEmpty)
          ? _BusinessErrorView(
              message: _error!,
              onRetry: () => setState(() {
                _loading = true;
                _error = null;
                _load();
              }),
            )
          : widget.isEdit
          ? _buildForm(context, const [])
          : suppliersAsync.when(
              loading: () => const LoadingState(),
              error: (e, _) => ErrorState(
                error: e,
                onRetry: () async => ref.invalidate(suppliersProvider),
              ),
              data: (suppliers) => _buildForm(context, suppliers),
            ),
    );
  }

  Widget _buildForm(BuildContext context, List<Supplier> suppliers) {
    return Form(
      key: _formKey,
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              children: [
                AppFormSection(
                  title: 'Tedarikçi Bilgileri',
                  children: [
                    if (widget.isEdit)
                      AppDataRow(
                        label: 'Tedarikçi',
                        value: _supplierLabel ?? '-',
                      )
                    else
                      DropdownButtonFormField<String>(
                        initialValue: _supplierId,
                        decoration: const InputDecoration(
                          labelText: 'Tedarikçi',
                        ),
                        items: suppliers
                            .where((s) => s.isActive)
                            .map(
                              (s) => DropdownMenuItem(
                                value: s.id,
                                child: Text(
                                  s.code.isNotEmpty
                                      ? '${s.code} — ${s.displayName}'
                                      : s.displayName,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (v) => setState(() => _supplierId = v),
                        validator: (v) =>
                            (v == null || v.isEmpty) ? 'Tedarikçi seçin' : null,
                      ),
                    TextFormField(
                      controller: _quotationNumberController,
                      decoration: const InputDecoration(
                        labelText: 'Teklif No (opsiyonel)',
                      ),
                    ),
                    _DatePickerTile(
                      label: 'Teklif Tarihi (opsiyonel)',
                      value: _quotationDate,
                      onChanged: (d) => setState(() => _quotationDate = d),
                    ),
                    _DatePickerTile(
                      label: 'Geçerlilik Tarihi (opsiyonel)',
                      value: _validUntil,
                      onChanged: (d) => setState(() => _validUntil = d),
                    ),
                  ],
                ),
                AppFormSection(
                  title: 'Ticari Bilgiler',
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _discountController,
                            decoration: const InputDecoration(
                              labelText: 'İskonto (tutar)',
                              errorMaxLines: 3,
                            ),
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            validator: (v) => formNumberError(
                              v,
                              required: false,
                              allowZero: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: TextFormField(
                            controller: _taxRateController,
                            decoration: const InputDecoration(
                              labelText: 'KDV Oranı (%)',
                              errorMaxLines: 3,
                            ),
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            validator: formPercentError,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _deliveryDaysController,
                            decoration: const InputDecoration(
                              labelText: 'Teslimat Süresi (gün, opsiyonel)',
                            ),
                            keyboardType: TextInputType.number,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: TextFormField(
                            controller: _paymentTermsController,
                            decoration: const InputDecoration(
                              labelText: 'Ödeme Koşulları (opsiyonel)',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                AppFormSection(
                  title: 'Kalemler',
                  spacing: AppSpacing.sm,
                  children: [
                    for (final item in _items)
                      _ItemRow(
                        key: ObjectKey(item),
                        item: item,
                        onChanged: () => setState(() {}),
                      ),
                  ],
                ),
                AppFormSection(
                  title: 'Notlar',
                  children: [
                    TextFormField(
                      controller: _notesController,
                      decoration: const InputDecoration(
                        labelText: 'Notlar (opsiyonel)',
                      ),
                      maxLines: 3,
                    ),
                  ],
                ),
                if (_error != null) ...[
                  Text(_error!, style: AppTypography.error),
                  const SizedBox(height: AppSpacing.sm),
                ],
              ],
            ),
          ),
          _StickyActionBar(
            child: PrimaryButton(
              label: widget.isEdit ? 'Kaydet' : 'Teklifi Kaydet',
              loading: _submitting,
              onPressed: _submit,
            ),
          ),
        ],
      ),
    );
  }
}

/// Formun altına sabitlenmiş aksiyon çubuğu (bkz. offer_create_screen.dart/
/// rfq_form_screen.dart AYNI kalıp).
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

class _DatePickerTile extends StatelessWidget {
  const _DatePickerTile({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      subtitle: value != null
          ? Text(
              '${value!.day.toString().padLeft(2, '0')}.${value!.month.toString().padLeft(2, '0')}.${value!.year}',
            )
          : null,
      trailing: value != null
          ? IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => onChanged(null),
            )
          : const Icon(Icons.calendar_today_outlined, size: 18),
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: value ?? DateTime.now(),
          firstDate: DateTime(2020),
          lastDate: DateTime(2100),
        );
        if (picked != null) onChanged(picked);
      },
    );
  }
}

/// Kalem fiyat satırı -- RFQ'nun kendi kalem listesindeki bir satıra
/// karşılık gelir (dinamik eklenebilir/silinebilir bir liste DEĞİLDİR,
/// bkz. sınıf yorumu). Miktar + birim fiyat HER ZAMAN doğrudan görünür,
/// hiçbir alan bir daraltılabilir bölümün arkasına gizlenmez.
class _ItemRow extends StatelessWidget {
  const _ItemRow({super.key, required this.item, required this.onChanged});

  final _DraftItem item;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            item.description,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.cardTitle,
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  initialValue: item.quantity,
                  decoration: InputDecoration(
                    labelText: 'Miktar (${item.unit})',
                    isDense: true,
                    errorMaxLines: 3,
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  validator: (v) => item.isBlank ? null : formNumberError(v),
                  onChanged: (v) {
                    item.quantity = v;
                    onChanged();
                  },
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: TextFormField(
                  initialValue: item.unitPrice,
                  decoration: const InputDecoration(
                    labelText: 'Birim Fiyat',
                    isDense: true,
                    errorMaxLines: 3,
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  validator: (v) => item.isBlank ? null : formNumberError(v),
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
    );
  }
}

/// İş kuralı kaynaklı hata mesajları (ör. "RFQ artık açık değil") -- ağ
/// hatası DEĞİLDİR, bu yüzden ortak `ErrorState`in `ApiException` ayrımı
/// yerine zaten çözülmüş mesaj OLDUĞU GİBİ gösterilir.
class _BusinessErrorView extends StatelessWidget {
  const _BusinessErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: AppColors.danger, size: 40),
            const SizedBox(height: AppSpacing.md),
            Text(
              message,
              textAlign: TextAlign.center,
              style: AppTypography.body.copyWith(color: AppColors.textMuted),
            ),
            const SizedBox(height: AppSpacing.lg),
            SecondaryButton(label: 'Tekrar Dene', onPressed: onRetry),
          ],
        ),
      ),
    );
  }
}
