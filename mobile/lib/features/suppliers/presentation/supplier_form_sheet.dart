import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_form_section.dart';
import '../../../core/widgets/unsaved_changes_scope.dart';
import '../data/suppliers_providers.dart';
import '../domain/supplier.dart';
import 'widgets/supplier_ui.dart';
import '../../../core/widgets/app_sheet.dart';

/// Yeni/düzenle formunu alt sayfa olarak açar; kaydedilen tedarikçiyi
/// döner (vazgeçilirse null). Yalnızca `organization.suppliers.manage`
/// sahibine gösterilen düğmelerden çağrılır.
Future<OrganizationSupplier?> showSupplierFormSheet(BuildContext context, {OrganizationSupplier? existing}) {
  return showAppSheet<OrganizationSupplier>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => SupplierFormSheet(existing: existing),
  );
}

final _emailFormat = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

/// Web `SuppliersManager` modalının alanları ve kuralları:
/// - Kod + Unvan zorunlu; kod düzenlemede kilitli (backend güncellemede
///   kodu hiç yazmaz).
/// - IBAN yalnızca YAZILIR: düzenlemede boş bırakılırsa gövdeye hiç
///   konmaz, kayıtlı IBAN değişmez. Mevcut IBAN hiçbir zaman gösterilmez.
/// - Ülke varsayılanı "Türkiye".
/// Uzunluk sınırları veritabanı sütunlarıyla (migration 0037/0038) aynıdır;
/// aşan metin sunucuda ham bir hata vermesin diye yazarken kesilir.
class SupplierFormSheet extends ConsumerStatefulWidget {
  const SupplierFormSheet({super.key, this.existing});

  final OrganizationSupplier? existing;

  bool get isEdit => existing != null;

  @override
  ConsumerState<SupplierFormSheet> createState() => _SupplierFormSheetState();
}

class _SupplierFormSheetState extends ConsumerState<SupplierFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _code;
  late final TextEditingController _legalName;
  late final TextEditingController _tradeName;
  late final TextEditingController _specialty;
  late final TextEditingController _taxNumber;
  late final TextEditingController _taxOffice;
  late final TextEditingController _contactName;
  late final TextEditingController _phone;
  late final TextEditingController _email;
  late final TextEditingController _city;
  late final TextEditingController _country;
  late final TextEditingController _address;
  late final TextEditingController _iban;
  late final TextEditingController _notes;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final s = widget.existing;
    _code = TextEditingController(text: s?.code ?? '');
    _legalName = TextEditingController(text: s?.legalName ?? '');
    _tradeName = TextEditingController(text: s?.tradeName ?? '');
    _specialty = TextEditingController(text: s?.specialty ?? '');
    _taxNumber = TextEditingController(text: s?.taxNumber ?? '');
    _taxOffice = TextEditingController(text: s?.taxOffice ?? '');
    _contactName = TextEditingController(text: s?.contactName ?? '');
    _phone = TextEditingController(text: s?.phone ?? '');
    _email = TextEditingController(text: s?.email ?? '');
    _city = TextEditingController(text: s?.city ?? '');
    _country = TextEditingController(text: s == null ? 'Türkiye' : s.country);
    _address = TextEditingController(text: s?.address ?? '');
    _iban = TextEditingController();
    _notes = TextEditingController(text: s?.notes ?? '');
  }

  @override
  void dispose() {
    for (final c in [
      _code,
      _legalName,
      _tradeName,
      _specialty,
      _taxNumber,
      _taxOffice,
      _contactName,
      _phone,
      _email,
      _city,
      _country,
      _address,
      _iban,
      _notes,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.existing;
    return UnsavedChangesScope(
      busy: _submitting,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(AppSpacing.xl, AppSpacing.xl, AppSpacing.xl, AppSpacing.xl),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.isEdit ? 'Tedarikçiyi Düzenle' : 'Yeni Tedarikçi',
                  style: AppTypography.pageTitle.copyWith(fontSize: 17),
                ),
                const SizedBox(height: AppSpacing.lg),
                AppFormSection(
                  title: 'Firma Bilgileri',
                  children: [
                    TextFormField(
                      key: const ValueKey('supplier-code'),
                      controller: _code,
                      enabled: !widget.isEdit,
                      textCapitalization: TextCapitalization.characters,
                      inputFormatters: [LengthLimitingTextInputFormatter(30)],
                      decoration: InputDecoration(
                        labelText: 'Kod *',
                        hintText: 'ör. TED-001',
                        helperText: widget.isEdit
                            ? 'Kod oluşturulduktan sonra değiştirilemez (geçmiş kayıtlarla bağlantısını korumak için).'
                            : null,
                        helperMaxLines: 3,
                      ),
                      validator: (v) => (v == null || v.trim().isEmpty) ? 'Tedarikçi kodu zorunludur' : null,
                    ),
                    TextFormField(
                      key: const ValueKey('supplier-legal-name'),
                      controller: _legalName,
                      textCapitalization: TextCapitalization.words,
                      // Resmi unvanlar uzun olur: alan büyür, ad tamamıyla okunur.
                      minLines: 1,
                      maxLines: 3,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.next,
                      inputFormatters: [
                        FilteringTextInputFormatter.deny(RegExp(r'[\r\n]')),
                        LengthLimitingTextInputFormatter(200),
                      ],
                      decoration: const InputDecoration(labelText: 'Unvan *', hintText: 'Resmi ticari unvan'),
                      validator: (v) => (v == null || v.trim().isEmpty) ? 'Unvan zorunludur' : null,
                    ),
                    TextFormField(
                      controller: _tradeName,
                      inputFormatters: [LengthLimitingTextInputFormatter(200)],
                      decoration: const InputDecoration(labelText: 'Ticari Ad', hintText: 'ör. bilinen kısa ad'),
                    ),
                    TextFormField(
                      controller: _specialty,
                      inputFormatters: [LengthLimitingTextInputFormatter(150)],
                      decoration: const InputDecoration(
                        labelText: 'Uzmanlık / Branş',
                        hintText: 'ör. Elektrik, Sıhhi tesisat',
                      ),
                    ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _taxNumber,
                            keyboardType: TextInputType.number,
                            inputFormatters: [LengthLimitingTextInputFormatter(30)],
                            decoration: const InputDecoration(labelText: 'Vergi No'),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: TextFormField(
                            controller: _taxOffice,
                            inputFormatters: [LengthLimitingTextInputFormatter(100)],
                            decoration: const InputDecoration(labelText: 'Vergi Dairesi'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                AppFormSection(
                  title: 'İletişim',
                  children: [
                    TextFormField(
                      controller: _contactName,
                      textCapitalization: TextCapitalization.words,
                      inputFormatters: [LengthLimitingTextInputFormatter(150)],
                      decoration: const InputDecoration(labelText: 'Yetkili Kişi'),
                    ),
                    TextFormField(
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      inputFormatters: [LengthLimitingTextInputFormatter(30)],
                      decoration: const InputDecoration(labelText: 'Telefon'),
                    ),
                    TextFormField(
                      key: const ValueKey('supplier-email'),
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      inputFormatters: [LengthLimitingTextInputFormatter(200)],
                      decoration: const InputDecoration(labelText: 'E-posta'),
                      validator: (v) {
                        final value = v?.trim() ?? '';
                        return value.isNotEmpty && !_emailFormat.hasMatch(value)
                            ? 'Geçerli bir e-posta adresi gir'
                            : null;
                      },
                    ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _city,
                            inputFormatters: [LengthLimitingTextInputFormatter(100)],
                            decoration: const InputDecoration(labelText: 'Şehir'),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: TextFormField(
                            controller: _country,
                            inputFormatters: [LengthLimitingTextInputFormatter(100)],
                            decoration: const InputDecoration(labelText: 'Ülke'),
                          ),
                        ),
                      ],
                    ),
                    TextFormField(
                      controller: _address,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(labelText: 'Adres', alignLabelWithHint: true),
                    ),
                  ],
                ),
                AppFormSection(
                  title: 'Banka',
                  subtitle: 'IBAN şifreli saklanır; kaydedildikten sonra hiçbir ekranda gösterilmez.',
                  children: [
                    TextFormField(
                      key: const ValueKey('supplier-iban'),
                      controller: _iban,
                      textCapitalization: TextCapitalization.characters,
                      inputFormatters: [LengthLimitingTextInputFormatter(42)],
                      decoration: InputDecoration(
                        labelText: widget.isEdit ? 'IBAN (değiştirmek için doldur)' : 'IBAN',
                        hintText: existing != null && existing.ibanSet
                            ? '•••• (kayıtlı, değiştirmemek için boş bırak)'
                            : 'TR..',
                        helperText: existing == null
                            ? null
                            : existing.ibanSet
                            ? 'Şu an kayıtlı bir IBAN var.'
                            : 'Şu an kayıtlı IBAN yok.',
                      ),
                      validator: (v) {
                        final value = normalizeIban(v ?? '');
                        return value.isNotEmpty && !isValidIban(value)
                            ? 'Geçerli bir IBAN gir (ör. TR33 0006 1005 1978 6457 8413 26)'
                            : null;
                      },
                    ),
                  ],
                ),
                AppFormSection(
                  title: 'Notlar',
                  children: [
                    TextFormField(
                      controller: _notes,
                      minLines: 2,
                      maxLines: 5,
                      decoration: const InputDecoration(labelText: 'Notlar', alignLabelWithHint: true),
                    ),
                  ],
                ),
                if (_error != null) ...[
                  Text(_error!, style: AppTypography.error),
                  const SizedBox(height: AppSpacing.md),
                ],
                PrimaryButton(label: 'Kaydet', loading: _submitting, onPressed: _submit),
                const SizedBox(height: AppSpacing.sm),
                TextButton(
                  onPressed: _submitting ? null : () => Navigator.of(context).pop(),
                  child: const Text('Vazgeç'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final iban = normalizeIban(_iban.text);
    final input = SupplierInput(
      code: widget.isEdit ? widget.existing!.code : _code.text.trim(),
      legalName: _legalName.text.trim(),
      tradeName: _tradeName.text.trim(),
      specialty: _specialty.text.trim(),
      taxNumber: _taxNumber.text.trim(),
      taxOffice: _taxOffice.text.trim(),
      contactName: _contactName.text.trim(),
      phone: _phone.text.trim(),
      email: _email.text.trim(),
      city: _city.text.trim(),
      country: _country.text.trim(),
      address: _address.text.trim(),
      notes: _notes.text.trim(),
      iban: iban.isEmpty ? null : iban,
    );
    setState(() {
      _submitting = true;
      _error = null;
    });
    // Kayıt sürerken sayfa kapanmış olsa bile altta açık kalan liste/detay
    // tazelensin: kapsayıcı ilk await'ten ÖNCE alınır.
    final container = ProviderScope.containerOf(context, listen: false);
    final existing = widget.existing;
    try {
      final repo = container.read(suppliersRepositoryProvider);
      final saved = existing != null ? await repo.update(existing.id, input) : await repo.create(input);
      container.invalidate(suppliersListProvider);
      if (existing != null) container.invalidate(supplierDetailProvider(existing.id));
      if (mounted) Navigator.of(context).pop(saved);
    } catch (e) {
      if (mounted) setState(() => _error = supplierErrorText(e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }
}
