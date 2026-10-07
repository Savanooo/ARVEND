import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_form_section.dart';
import '../../../core/widgets/unsaved_changes_scope.dart';
import '../budget/data/budget_providers.dart';
import '../budget/domain/budget.dart' show formatTrDecimalInput, kBudgetReadPermission, kCostCodesReadPermission;
import '../data/projects_providers.dart';
import '../domain/expense_actions.dart' show kExpenseFinanceManagePermission;
import '../domain/project.dart';
import '../my_expenses/data/my_expenses_repository.dart';
import '../finance_plan/domain/finance_dates.dart' show parseAmountInput, parseApiDate;
import 'form_project_banner.dart';
import '../../../core/widgets/app_sheet.dart';

/// "Masraf Ekle" (web ExpensesSection formu). Kategori/açıklama/tutar/KDV/
/// tarih/tedarikçi/fatura no'nun yanında web'deki opsiyonel bağlar: Ek İş,
/// Bütçe Kalemi (seçilince maliyet kodu ondan gelir) ve Maliyet Kodu + Not.
/// Taşeron ödemeleri buraya girilmez (çift sayım) -- Taşeron Ödemeleri'nden.
/// [projectLabel]: formun başında hangi projeye girildiği (bkz.
/// FormProjectBanner).
///
/// [initial] verilirse "Masrafı Düzenle": form o masrafla dolar ve
/// `PUT .../expenses/{id}` atar. Sunucu satırı bütünüyle yeniden yazar;
/// formun göstermediği/kullanıcının değiştirmediği alanlar (bağlar, not,
/// tarih…) aynen geri gider. Düzenlenen masraf yeniden onay bekler --
/// reddedilen masraf ancak böyle düzeltilebilir.
///
/// Masrafı herkes girer (backend migration 0066): `projects.finance.manage`
/// olmayan kişide bağ seçicileri HİÇ görünmez ve bağlar boş gider -- sunucu
/// dolu bağı 403 ile reddeder, boş bağ düzenlemede "kayıttakini koru"
/// demektir (finansın eklediği bağ sahadaki düzeltmede kaybolmaz).
Future<Expense?> showExpenseFormSheet(
  BuildContext context,
  String projectId, {
  required String currency,
  String? projectLabel,
  Expense? initial,
}) {
  return showAppSheet<Expense>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => _ExpenseFormSheet(
      projectId: projectId,
      currency: currency,
      projectLabel: projectLabel,
      initial: initial,
    ),
  );
}

class _ExpenseFormSheet extends ConsumerStatefulWidget {
  const _ExpenseFormSheet({required this.projectId, required this.currency, this.projectLabel, this.initial});
  final String projectId;
  final String currency;
  final String? projectLabel;
  final Expense? initial;

  @override
  ConsumerState<_ExpenseFormSheet> createState() => _ExpenseFormSheetState();
}

class _ExpenseFormSheetState extends ConsumerState<_ExpenseFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final _descriptionController = TextEditingController(text: widget.initial?.description ?? '');
  late final _amountController = TextEditingController(text: formatTrDecimalInput(widget.initial?.amount));
  late final _supplierController = TextEditingController(text: widget.initial?.supplierName ?? '');
  late final _invoiceController = TextEditingController(text: widget.initial?.invoiceNo ?? '');
  late final _notesController = TextEditingController(text: widget.initial?.notes ?? '');
  late String _category = widget.initial?.category ?? 'material';
  late DateTime _date = _initialDate();
  late String? _changeOrderId = widget.initial?.changeOrderId;
  late String? _budgetLineId = widget.initial?.budgetLineId;
  late String? _costCodeId = widget.initial?.costCodeId;

  /// KDV oranı (%); null = belirtilmedi (sunucuda NULL, tutarın tamamı
  /// maliyet sayılır).
  late double? _vatRate = widget.initial?.vatRate;
  bool _submitting = false;
  String? _error;

  /// Form örneği başına SABİT anahtar -- ağ hatası sonrası yeniden deneme
  /// mükerrer masraf oluşturmaz (web ile aynı). Düzenlemede kullanılmaz.
  final _idempotencyKey = 'exp-${DateTime.now().microsecondsSinceEpoch}';

  bool get _editing => widget.initial != null;

  DateTime _initialDate() {
    final d = parseApiDate(widget.initial?.expenseDate);
    return d == null ? DateTime.now() : DateTime(d.year, d.month, d.day);
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    _amountController.dispose();
    _supplierController.dispose();
    _invoiceController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  /// Onaylanmış masraf düzenlenince toplamlardan düşer -- kayıttan ÖNCE sorulur.
  Future<bool> _confirmBackToApproval() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Yeniden onaya gidecek'),
        content: const Text(
          'Bu masraf onaylanmış. Düzenlenince yeniden onay bekler; onaylanana kadar gerçekleşen maliyete ve kâra '
          'girmez.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Vazgeç')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Kaydet')),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final initial = widget.initial;
    if (initial != null && initial.isApproved && !await _confirmBackToApproval()) return;
    if (!mounted) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    final repo = ref.read(projectsRepositoryProvider);
    final user = ref.read(authControllerProvider).valueOrNull;
    // Bağ yazma yetkisi yoksa üçü de boş gider (bkz. sınıf notu).
    final canLink = user.can(kExpenseFinanceManagePermission);
    String link(String? id) => canLink ? (id ?? '') : '';
    final description = _descriptionController.text.trim();
    // Türkçe giriş: "64.000" = altmış dört bin, "1.250,50" kabul edilir.
    final amount = parseAmountInput(_amountController.text)!;
    final expenseDate =
        '${_date.year.toString().padLeft(4, '0')}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}';
    try {
      final Expense expense;
      if (initial == null) {
        expense = await repo.createExpense(
          widget.projectId,
          category: _category,
          description: description,
          amount: amount,
          currency: widget.currency,
          expenseDate: expenseDate,
          supplierName: _supplierController.text.trim(),
          invoiceNo: _invoiceController.text.trim(),
          notes: _notesController.text.trim(),
          changeOrderId: link(_changeOrderId),
          budgetLineId: link(_budgetLineId),
          costCodeId: link(_costCodeId),
          vatRate: _vatRate,
          idempotencyKey: _idempotencyKey,
        );
      } else {
        expense = await repo.updateExpense(
          widget.projectId,
          initial.id,
          category: _category,
          description: description,
          amount: amount,
          currency: initial.currency.isEmpty ? widget.currency : initial.currency,
          expenseDate: expenseDate,
          supplierName: _supplierController.text.trim(),
          invoiceNo: _invoiceController.text.trim(),
          notes: _notesController.text.trim(),
          changeOrderId: link(_changeOrderId),
          budgetLineId: link(_budgetLineId),
          costCodeId: link(_costCodeId),
          vatRate: _vatRate,
        );
      }
      if (!mounted) return;
      // Masraf onay bekleyerek doğar ve düzenlenince yeniden onaya düşer
      // (backend migration 0060): toplamda hemen görünmemesinin nedeni burada
      // söylenir. Mesaj formda verilir ki her açılış yeri (Finans, proje
      // Özeti, ana sayfa hızlı işlemi, masraf ayrıntısı) aynı şeyi göstersin.
      // "Masraflarım" her giriş yerinden (hızlı işlem dahil) yeni masrafı
      // göstersin; düzenleme ayrıntı sayfasından gelir ve o tazeler.
      if (initial == null) ref.invalidate(myExpensesProvider);
      final messenger = ScaffoldMessenger.maybeOf(context);
      Navigator.of(context).pop(expense);
      messenger?.showSnackBar(
        SnackBar(
          content: Text(initial == null ? 'Masraf onaya gönderildi.' : 'Masraf güncellendi; yeniden onaya gönderildi.'),
        ),
      );
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Seçiciler yalnızca oturum bilinen ve ilgili OKUMA iznine sahip kişide
    // yüklenir (gereksiz 403 yok); liste boşsa ya da yüklenemezse alan hiç
    // görünmez, masraf formu yine çalışır (web ile aynı). Düzenlemede seçili
    // değer yine de korunur ve aynen geri gönderilir.
    final user = ref.watch(authControllerProvider).valueOrNull;
    // Bağlar maliyetin nereye yazılacağı kararıdır: yalnızca finans
    // yöneticisi seçer (backend 0066); diğerinde seçici yüklenmez bile.
    final canLink = user != null && user.can(kExpenseFinanceManagePermission);
    bool allowed(String code) => canLink && user.can(code);

    final changeOrders = allowed('projects.finance.read')
        ? (ref.watch(projectChangeOrdersProvider(widget.projectId)).valueOrNull ?? const <ChangeOrder>[])
              // İptal edilmiş/yerine yenisi gelmiş ek işe bağlamak anlamsız --
              // ama düzenlenen masrafın mevcut bağı listede kalır.
              .where((co) => (co.status != 'cancelled' && co.status != 'superseded') || co.id == _changeOrderId)
              .toList()
        : const <ChangeOrder>[];
    final budgetLines = allowed(kBudgetReadPermission)
        ? (ref.watch(budgetLinesProvider(widget.projectId)).valueOrNull ?? const [])
        : const [];
    final costCodes = allowed(kCostCodesReadPermission)
        ? (ref.watch(orgCostCodesProvider).valueOrNull ?? const [])
              .where((c) => c.isActive || c.id == _costCodeId)
              .toList()
        : const [];
    final initial = widget.initial;

    return UnsavedChangesScope(
      busy: _submitting,
      child: Padding(
        padding: EdgeInsets.only(
          left: AppSpacing.xl,
          right: AppSpacing.xl,
          top: AppSpacing.xl,
          bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.xl,
        ),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_editing ? 'Masrafı Düzenle' : 'Masraf Ekle', style: AppTypography.pageTitle.copyWith(fontSize: 17)),
                if (widget.projectLabel case final label?) ...[
                  const SizedBox(height: AppSpacing.md),
                  FormProjectBanner(label: label),
                ],
                if (initial != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    initial.isRejected && initial.decisionNote.isNotEmpty
                        ? 'Red nedeni: ${initial.decisionNote}. Düzeltip kaydedince yeniden onaya gider.'
                        : 'Kaydedince masraf yeniden onaya gider.',
                    style: AppTypography.helper,
                  ),
                ],
                const SizedBox(height: AppSpacing.lg),
                AppFormSection(
                  title: 'Masraf Bilgileri',
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: _category,
                      decoration: const InputDecoration(labelText: 'Kategori'),
                      items: [
                        for (final e in expenseCategories.entries)
                          DropdownMenuItem(value: e.key, child: Text(e.value)),
                        // Bilinmeyen (yeni sunucu) kategori düzenlemede aynen kalır.
                        if (!expenseCategories.containsKey(_category))
                          DropdownMenuItem(value: _category, child: Text(_category)),
                      ],
                      onChanged: (v) => setState(() => _category = v!),
                    ),
                    TextFormField(
                      controller: _descriptionController,
                      decoration: const InputDecoration(labelText: 'Açıklama'),
                      validator: (v) => (v == null || v.trim().isEmpty) ? 'Açıklama gerekli' : null,
                    ),
                    TextFormField(
                      controller: _amountController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(labelText: 'Tutar (${widget.currency})'),
                      validator: (v) {
                        final parsed = parseAmountInput(v ?? '');
                        if (parsed == null || parsed <= 0) return 'Geçerli bir tutar girin';
                        return null;
                      },
                    ),
                    _VatRateField(
                      rate: _vatRate,
                      amount: _amountController,
                      currency: widget.currency,
                      onChanged: (rate) => setState(() => _vatRate = rate),
                    ),
                    // "Tedarikçi" adıyla en altta duruyordu; usta/işçi
                    // ödemesinde anlamsız kaçtığı için sahada bulunamadı.
                    // Backend alanı aynı (supplier_name, serbest metin).
                    TextFormField(
                      controller: _supplierController,
                      decoration: const InputDecoration(
                        labelText: 'Kime ödendi (opsiyonel)',
                        hintText: 'Tedarikçi, usta ya da kişi adı',
                      ),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Tarih'),
                      subtitle: Text(
                        '${_date.day.toString().padLeft(2, '0')}.${_date.month.toString().padLeft(2, '0')}.${_date.year}',
                      ),
                      trailing: const Icon(Icons.calendar_today_outlined, size: 18),
                      onTap: () async {
                        final first = DateTime(2020);
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: _date,
                          // Aktarılmış eski masrafın tarihi seçiciyi düşürmesin.
                          firstDate: _date.isBefore(first) ? _date : first,
                          lastDate: DateTime(2100),
                        );
                        if (picked != null) setState(() => _date = picked);
                      },
                    ),
                    TextFormField(
                      controller: _invoiceController,
                      decoration: const InputDecoration(labelText: 'Fatura No (opsiyonel)'),
                    ),
                  ],
                ),
                if (changeOrders.isNotEmpty || budgetLines.isNotEmpty || costCodes.isNotEmpty)
                  AppFormSection(
                    title: 'Bağlantılar (opsiyonel)',
                    children: [
                      if (changeOrders.isNotEmpty)
                        DropdownButtonFormField<String?>(
                          key: const ValueKey('masraf-ek-is'),
                          initialValue: changeOrders.any((co) => co.id == _changeOrderId) ? _changeOrderId : null,
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: 'Ek İş (opsiyonel)'),
                          items: [
                            const DropdownMenuItem<String?>(value: null, child: Text('Bağlı değil')),
                            for (final co in changeOrders)
                              DropdownMenuItem<String?>(
                                value: co.id,
                                child: Text(
                                  '${co.changeOrderNo} · ${co.title}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (v) => setState(() => _changeOrderId = v),
                        ),
                      if (budgetLines.isNotEmpty)
                        DropdownButtonFormField<String?>(
                          key: const ValueKey('masraf-butce-kalemi'),
                          initialValue: budgetLines.any((l) => l.id == _budgetLineId) ? _budgetLineId : null,
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: 'Bütçe Kalemi (opsiyonel)'),
                          items: [
                            const DropdownMenuItem<String?>(value: null, child: Text('Bağlı değil (bütçe dışı)')),
                            for (final line in budgetLines)
                              DropdownMenuItem<String?>(
                                value: line.id,
                                child: Text(
                                  line.costCodeCode.isEmpty
                                      ? line.description
                                      : '${line.description} (${line.costCodeCode})',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          // Maliyet kodu seçilen bütçe kaleminden OTOMATİK gelir
                          // (sunucu da aynı kuralı uygular).
                          onChanged: (v) => setState(() {
                            _budgetLineId = v;
                            if (v != null) {
                              _costCodeId = budgetLines.firstWhere((l) => l.id == v).costCodeId;
                            }
                          }),
                        ),
                      if (costCodes.isNotEmpty)
                        DropdownButtonFormField<String?>(
                          // Bütçe kalemi değişince kalemin koduyla yeniden kurulur.
                          key: ValueKey('masraf-maliyet-kodu-$_budgetLineId'),
                          initialValue: costCodes.any((c) => c.id == _costCodeId) ? _costCodeId : null,
                          isExpanded: true,
                          decoration: InputDecoration(
                            labelText: 'Maliyet Kodu (opsiyonel)',
                            helperText: _budgetLineId != null ? 'Bütçe kaleminden gelir.' : null,
                          ),
                          items: [
                            const DropdownMenuItem<String?>(value: null, child: Text('Yok')),
                            for (final c in costCodes)
                              DropdownMenuItem<String?>(
                                value: c.id,
                                child: Text('${c.code} — ${c.name}', maxLines: 1, overflow: TextOverflow.ellipsis),
                              ),
                          ],
                          onChanged: _budgetLineId != null ? null : (v) => setState(() => _costCodeId = v),
                        ),
                    ],
                  ),
                AppFormSection(
                  title: 'Not',
                  children: [
                    TextFormField(
                      controller: _notesController,
                      minLines: 2,
                      maxLines: 4,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(labelText: 'Not (opsiyonel)', alignLabelWithHint: true),
                    ),
                  ],
                ),
                if (_error != null) ...[
                  Text(_error!, style: AppTypography.error),
                  const SizedBox(height: AppSpacing.md),
                ],
                PrimaryButton(label: 'Kaydet', loading: _submitting, onPressed: _submit),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// KDV seçimi: Belirtilmedi (varsayılan) / KDV yok (%0) / %1 / %10 / %20.
/// Oran seçilince tutarın (KDV dahil ödenen) altında canlı "KDV hariç · KDV"
/// önizlemesi -- asıl tutarları sunucu aynı formülle hesaplar
/// (round(tutar × oran / (100 + oran), 2)).
class _VatRateField extends StatelessWidget {
  const _VatRateField({required this.rate, required this.amount, required this.currency, required this.onChanged});

  final double? rate;
  final TextEditingController amount;
  final String currency;
  final ValueChanged<double?> onChanged;

  static String _keyOf(double r) => formatTrDecimalInput(r);

  @override
  Widget build(BuildContext context) {
    // Standart dışı bir oran (web'den/API'den girilmiş, ör. %18) düzenlemede
    // seçili görünür ve aynen geri gider.
    final rates = [...kExpenseVatRates, if (rate != null && !kExpenseVatRates.contains(rate)) rate!];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('KDV', style: AppTypography.metadata),
        const SizedBox(height: AppSpacing.xs),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.xs,
          children: [
            ChoiceChip(
              key: const ValueKey('masraf-kdv-belirtilmedi'),
              label: const Text('Belirtilmedi'),
              selected: rate == null,
              onSelected: (_) => onChanged(null),
            ),
            for (final r in rates)
              ChoiceChip(
                key: ValueKey('masraf-kdv-${_keyOf(r)}'),
                label: Text(r == 0 ? 'KDV yok (%0)' : '%${_keyOf(r)}'),
                selected: rate == r,
                onSelected: (_) => onChanged(r),
              ),
          ],
        ),
        if (rate != null)
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: amount,
            builder: (context, value, _) {
              final paid = parseAmountInput(value.text);
              if (paid == null || paid <= 0) {
                return const Padding(
                  padding: EdgeInsets.only(top: AppSpacing.xs),
                  child: Text('Tutar KDV dahil ödenen tutardır.', style: AppTypography.helper),
                );
              }
              final r = rate!;
              final vat = (paid * r / (100 + r) * 100).round() / 100;
              final net = ((paid - vat) * 100).round() / 100;
              return Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Text(
                  'KDV hariç: ${Formatters.money(net, currency: currency)} · KDV: ${Formatters.money(vat, currency: currency)}',
                  key: const ValueKey('masraf-kdv-onizleme'),
                  style: AppTypography.helper,
                ),
              );
            },
          ),
      ],
    );
  }
}
