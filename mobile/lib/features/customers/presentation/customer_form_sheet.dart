import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_form_section.dart';
import '../data/customers_providers.dart';
import '../domain/customer.dart';

/// Create + Edit aynı sheet -- hem `customers_screen.dart` (create) hem
/// `customer_detail_screen.dart` (edit) tarafından paylaşılır. Yalnızca
/// backend'in kabul ettiği alanlar vardır (bkz. backend Phase 1
/// doğrulaması: `upsertCustomerRequest` -- name/phone/email/address/
/// tax_office/tax_number/notes/is_active); müşteri tipi (bireysel/kurumsal)
/// veya ayrı iletişim kişisi gibi backend'de HİÇ olmayan alanlar İCAT
/// EDİLMEZ.
class CustomerFormSheet extends ConsumerStatefulWidget {
  const CustomerFormSheet({super.key, this.existing});

  final Customer? existing;

  bool get isEdit => existing != null;

  @override
  ConsumerState<CustomerFormSheet> createState() => _CustomerFormSheetState();
}

final _emailFormat = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

class _CustomerFormSheetState extends ConsumerState<CustomerFormSheet> {
  late final TextEditingController _nameController;
  late final TextEditingController _phoneController;
  late final TextEditingController _emailController;
  late final TextEditingController _addressController;
  late final TextEditingController _taxOfficeController;
  late final TextEditingController _taxNumberController;
  late final TextEditingController _notesController;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final c = widget.existing;
    _nameController = TextEditingController(text: c?.name ?? '');
    _phoneController = TextEditingController(text: c?.phone ?? '');
    _emailController = TextEditingController(text: c?.email ?? '');
    _addressController = TextEditingController(text: c?.address ?? '');
    _taxOfficeController = TextEditingController(text: c?.taxOffice ?? '');
    _taxNumberController = TextEditingController(text: c?.taxNumber ?? '');
    _notesController = TextEditingController(text: c?.notes ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _addressController.dispose();
    _taxOfficeController.dispose();
    _taxNumberController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.xl,
        right: AppSpacing.xl,
        top: AppSpacing.xl,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.xl,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.isEdit ? 'Müşteriyi Düzenle' : 'Yeni Müşteri', style: AppTypography.pageTitle.copyWith(fontSize: 17)),
            const SizedBox(height: AppSpacing.lg),
            AppFormSection(
              title: 'Müşteri Bilgileri',
              children: [
                TextField(controller: _nameController, decoration: const InputDecoration(labelText: 'Ad *')),
                TextField(
                  controller: _phoneController,
                  decoration: const InputDecoration(labelText: 'Telefon'),
                  keyboardType: TextInputType.phone,
                ),
                TextField(
                  controller: _emailController,
                  decoration: const InputDecoration(labelText: 'E-posta'),
                  keyboardType: TextInputType.emailAddress,
                ),
                TextField(
                  controller: _addressController,
                  decoration: const InputDecoration(labelText: 'Adres'),
                  maxLines: 2,
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                          controller: _taxOfficeController,
                          decoration: const InputDecoration(labelText: 'Vergi Dairesi')),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: TextField(
                          controller: _taxNumberController, decoration: const InputDecoration(labelText: 'Vergi No')),
                    ),
                  ],
                ),
                TextField(
                  controller: _notesController,
                  decoration: const InputDecoration(labelText: 'Not (opsiyonel)'),
                  maxLines: 2,
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
    );
  }

  /// [allowDuplicate]: kullanıcı çakışma uyarısında "Yine de kaydet" dedi.
  Future<void> _submit({bool allowDuplicate = false}) async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Müşteri adı zorunludur');
      return;
    }
    final email = _emailController.text.trim();
    if (email.isNotEmpty && !_emailFormat.hasMatch(email)) {
      setState(() => _error = 'Geçerli bir e-posta adresi girin');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final repo = ref.read(customersRepositoryProvider);
      if (widget.isEdit) {
        await repo.update(
          widget.existing!.id,
          name: name,
          phone: _phoneController.text.trim(),
          email: email,
          address: _addressController.text.trim(),
          taxOffice: _taxOfficeController.text.trim(),
          taxNumber: _taxNumberController.text.trim(),
          notes: _notesController.text.trim(),
          isActive: widget.existing!.isActive,
          allowDuplicate: allowDuplicate,
        );
        ref.invalidate(customerDetailProvider(widget.existing!.id));
      } else {
        await repo.create(
          name: name,
          phone: _phoneController.text.trim(),
          email: email,
          address: _addressController.text.trim(),
          taxOffice: _taxOfficeController.text.trim(),
          taxNumber: _taxNumberController.text.trim(),
          notes: _notesController.text.trim(),
          allowDuplicate: allowDuplicate,
        );
      }
      ref.invalidate(customersListProvider);
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      final dup = DuplicateCustomer.fromError(e);
      if (dup != null && !allowDuplicate) {
        if (mounted) setState(() => _submitting = false);
        await _onDuplicate(dup);
        return;
      }
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// Aynı vergi no/telefonla kayıtlı müşteri: web'deki gibi kullanıcı seçer.
  /// Sessizce reddetmek aynı müşterinin farklı yazımlarla tekrar açılmasını
  /// önlerken iki şubeli firmayı kaydedilemez bırakırdı.
  Future<void> _onDuplicate(DuplicateCustomer dup) async {
    final choice = await showDuplicateCustomerDialog(context, dup);
    if (!mounted) return;
    switch (choice) {
      case DuplicateCustomerChoice.saveAnyway:
        await _submit(allowDuplicate: true);
      case DuplicateCustomerChoice.open:
        // Sheet kapanınca context gider; router önce alınır.
        final router = GoRouter.maybeOf(context);
        Navigator.of(context).pop();
        router?.push('/diger/musteriler/${Uri.encodeComponent(dup.id)}');
      case DuplicateCustomerChoice.cancel:
      case null:
        break;
    }
  }
}

enum DuplicateCustomerChoice { cancel, open, saveAnyway }

/// 409 `duplicate_customer` diyaloğu: çakışan müşteriyi gösterir, "Vazgeç /
/// Mevcut müşteriyi aç / Yine de kaydet" sorar. Oluştur/düzenle formu ve
/// müşteri detayındaki "Aktifleştir" (o da bir PUT) aynı diyaloğu kullanır --
/// aynı çakışma iki ekranda iki farklı biçimde anlatılmasın.
Future<DuplicateCustomerChoice?> showDuplicateCustomerDialog(BuildContext context, DuplicateCustomer dup) {
  return showDialog<DuplicateCustomerChoice>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('customer-duplicate-dialog'),
      title: const Text('Bu müşteri zaten kayıtlı olabilir'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            dup.field == 'tax_number'
                ? 'Aynı vergi numarasıyla kayıtlı bir müşteri var:'
                : 'Aynı telefon numarasıyla kayıtlı bir müşteri var:',
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            dup.isActive ? dup.name : '${dup.name} (arşivde)',
            style: AppTypography.cardTitle,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Aynı firmanın ayrı bir kaydıysa (ör. ikinci şube) yine de kaydedebilirsin.',
            style: AppTypography.helper,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(DuplicateCustomerChoice.cancel),
          child: const Text('Vazgeç'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(DuplicateCustomerChoice.open),
          child: const Text('Mevcut müşteriyi aç'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(DuplicateCustomerChoice.saveAnyway),
          child: const Text('Yine de kaydet'),
        ),
      ],
    ),
  );
}
