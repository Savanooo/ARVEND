import 'package:flutter/material.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../data/onboarding_repository.dart';
import '../domain/onboarding_state.dart';

/// Bu dosyadaki 5 form, HEM ilk-giriş sihirbazı (onboarding_wizard_screen.dart,
/// basePath=/onboarding, submitLabel='İleri') HEM DE onboarding sonrası
/// "Firma Ayarları" (organization_settings_screen.dart, basePath=/organization/
/// settings, submitLabel='Kaydet') tarafından AYNEN kullanılır -- ikisi de
/// AYNI [OnboardingRepository] sınıfını (yalnızca basePath'i farklı) [repository]
/// parametresiyle geçirir, form/validasyon mantığı TEK yerde yaşar.

const _fieldGap = SizedBox(height: 12);

Widget _errorText(String? error) {
  if (error == null) return const SizedBox.shrink();
  return Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Text(error, style: const TextStyle(color: AppColors.danger)),
  );
}

Widget _submitRow({required VoidCallback? onSubmit, required bool submitting, required String label, Widget? leading}) {
  return Padding(
    padding: const EdgeInsets.only(top: 20),
    child: Row(
      children: [
        // OutlinedButton/ElevatedButton tema varsayılanı (Size.fromHeight)
        // width'i infinity yapar -- Row'un loose/sınırsız genişlik veren
        // main-axis constraint'i ile birleşince "infinite width" layout
        // hatasına yol açar (yalnızca bu ekranda çıkar, çünkü diğer tüm
        // buton kullanımları Column içinde tek başınadır). Expanded ile
        // sarmalamak, butona SONLU (Row'un payına düşen) bir genişlik verir.
        if (leading != null) ...[Expanded(child: leading), const SizedBox(width: 12)],
        Expanded(
          child: ElevatedButton(
            onPressed: submitting ? null : onSubmit,
            child: submitting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                  )
                : Text(label),
          ),
        ),
      ],
    ),
  );
}

class CompanyStepForm extends StatefulWidget {
  const CompanyStepForm({
    super.key,
    required this.repository,
    required this.initial,
    required this.onSaved,
    this.submitLabel = 'Kaydet',
    this.leading,
  });

  final OnboardingRepository repository;
  final OrganizationProfile initial;
  final void Function(OnboardingState) onSaved;
  final String submitLabel;
  final Widget? leading;

  @override
  State<CompanyStepForm> createState() => _CompanyStepFormState();
}

class _CompanyStepFormState extends State<CompanyStepForm> {
  final _formKey = GlobalKey<FormState>();
  late final _authorizedPerson = TextEditingController(text: widget.initial.authorizedPerson);
  late final _phone = TextEditingController(text: widget.initial.phone);
  late final _email = TextEditingController(text: widget.initial.email);
  late final _website = TextEditingController(text: widget.initial.website);
  late final _city = TextEditingController(text: widget.initial.city);
  late final _district = TextEditingController(text: widget.initial.district);
  late final _country =
      TextEditingController(text: widget.initial.country.isEmpty ? 'Türkiye' : widget.initial.country);
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _authorizedPerson.dispose();
    _phone.dispose();
    _email.dispose();
    _website.dispose();
    _city.dispose();
    _district.dispose();
    _country.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final state = await widget.repository.saveCompany(
        authorizedPerson: _authorizedPerson.text.trim(),
        phone: _phone.text.trim(),
        email: _email.text.trim(),
        website: _website.text.trim(),
        city: _city.text.trim(),
        district: _district.text.trim(),
        country: _country.text.trim(),
      );
      widget.onSaved(state);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: _authorizedPerson,
            decoration: const InputDecoration(labelText: 'Yetkili Kişi'),
            validator: (v) => (v == null || v.trim().isEmpty) ? 'Yetkili kişi gerekli' : null,
          ),
          _fieldGap,
          TextFormField(
            controller: _phone,
            decoration: const InputDecoration(labelText: 'Telefon'),
            keyboardType: TextInputType.phone,
          ),
          _fieldGap,
          TextFormField(
            controller: _email,
            decoration: const InputDecoration(labelText: 'E-posta'),
            keyboardType: TextInputType.emailAddress,
          ),
          _fieldGap,
          TextFormField(controller: _website, decoration: const InputDecoration(labelText: 'Web Sitesi')),
          _fieldGap,
          Row(children: [
            Expanded(
                child:
                    TextFormField(controller: _city, decoration: const InputDecoration(labelText: 'Şehir'))),
            const SizedBox(width: 12),
            Expanded(
                child: TextFormField(
                    controller: _district, decoration: const InputDecoration(labelText: 'İlçe'))),
          ]),
          _fieldGap,
          TextFormField(controller: _country, decoration: const InputDecoration(labelText: 'Ülke')),
          _errorText(_error),
          _submitRow(onSubmit: _submit, submitting: _submitting, label: widget.submitLabel, leading: widget.leading),
        ],
      ),
    );
  }
}

class BillingStepForm extends StatefulWidget {
  const BillingStepForm({
    super.key,
    required this.repository,
    required this.initial,
    required this.onSaved,
    this.submitLabel = 'Kaydet',
    this.leading,
  });

  final OnboardingRepository repository;
  final OrganizationProfile initial;
  final void Function(OnboardingState) onSaved;
  final String submitLabel;
  final Widget? leading;

  @override
  State<BillingStepForm> createState() => _BillingStepFormState();
}

class _BillingStepFormState extends State<BillingStepForm> {
  final _formKey = GlobalKey<FormState>();
  late final _legalName = TextEditingController(text: widget.initial.legalName);
  late final _taxOffice = TextEditingController(text: widget.initial.taxOffice);
  late final _taxNumber = TextEditingController(text: widget.initial.taxNumber);
  late final _invoiceAddress = TextEditingController(text: widget.initial.invoiceAddress);
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _legalName.dispose();
    _taxOffice.dispose();
    _taxNumber.dispose();
    _invoiceAddress.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final state = await widget.repository.saveBilling(
        legalName: _legalName.text.trim(),
        taxOffice: _taxOffice.text.trim(),
        taxNumber: _taxNumber.text.trim(),
        invoiceAddress: _invoiceAddress.text.trim(),
      );
      widget.onSaved(state);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: _legalName,
            decoration: const InputDecoration(labelText: 'Resmi Unvan'),
            validator: (v) => (v == null || v.trim().isEmpty) ? 'Resmi unvan gerekli' : null,
          ),
          _fieldGap,
          TextFormField(controller: _taxOffice, decoration: const InputDecoration(labelText: 'Vergi Dairesi')),
          _fieldGap,
          TextFormField(
            controller: _taxNumber,
            decoration: const InputDecoration(labelText: 'Vergi Numarası'),
            keyboardType: TextInputType.number,
            validator: (v) => (v == null || v.trim().isEmpty) ? 'Vergi numarası gerekli' : null,
          ),
          _fieldGap,
          TextFormField(
            controller: _invoiceAddress,
            decoration: const InputDecoration(labelText: 'Fatura Adresi'),
            maxLines: 3,
          ),
          _errorText(_error),
          _submitRow(onSubmit: _submit, submitting: _submitting, label: widget.submitLabel, leading: widget.leading),
        ],
      ),
    );
  }
}

class OffersStepForm extends StatefulWidget {
  const OffersStepForm({
    super.key,
    required this.repository,
    required this.initial,
    required this.onSaved,
    this.submitLabel = 'Kaydet',
    this.leading,
  });

  final OnboardingRepository repository;
  final OrganizationCommercialSettings initial;
  final void Function(OnboardingState) onSaved;
  final String submitLabel;
  final Widget? leading;

  @override
  State<OffersStepForm> createState() => _OffersStepFormState();
}

class _OffersStepFormState extends State<OffersStepForm> {
  final _formKey = GlobalKey<FormState>();
  late final _offerPrefix =
      TextEditingController(text: widget.initial.offerPrefix.isEmpty ? 'TKF' : widget.initial.offerPrefix);
  late final _validityDays =
      TextEditingController(text: widget.initial.offerValidityDays.toString());
  late final _vatRate = TextEditingController(text: widget.initial.defaultVatRate.toString());
  late final _footer = TextEditingController(text: widget.initial.defaultOfferFooter);
  late final _paymentTerms = TextEditingController(text: widget.initial.defaultPaymentTerms);
  late final _deliveryTerms = TextEditingController(text: widget.initial.defaultDeliveryTerms);
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _offerPrefix.dispose();
    _validityDays.dispose();
    _vatRate.dispose();
    _footer.dispose();
    _paymentTerms.dispose();
    _deliveryTerms.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final state = await widget.repository.saveOffers(
        offerPrefix: _offerPrefix.text.trim(),
        offerValidityDays: int.parse(_validityDays.text.trim()),
        defaultVatRate: double.parse(_vatRate.text.trim().replaceAll(',', '.')),
        defaultOfferFooter: _footer.text.trim(),
        defaultPaymentTerms: _paymentTerms.text.trim(),
        defaultDeliveryTerms: _deliveryTerms.text.trim(),
      );
      widget.onSaved(state);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: _offerPrefix,
            decoration: const InputDecoration(labelText: 'Teklif Numarası Öneki (ör. TKF)'),
            validator: (v) => (v == null || v.trim().isEmpty) ? 'Önek gerekli' : null,
          ),
          _fieldGap,
          Row(children: [
            Expanded(
              child: TextFormField(
                controller: _validityDays,
                decoration: const InputDecoration(labelText: 'Geçerlilik (gün)'),
                keyboardType: TextInputType.number,
                validator: (v) {
                  final n = int.tryParse((v ?? '').trim());
                  return (n == null || n <= 0) ? 'Geçerli bir sayı girin' : null;
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                controller: _vatRate,
                decoration: const InputDecoration(labelText: 'KDV Oranı (%)'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                validator: (v) {
                  final n = double.tryParse((v ?? '').trim().replaceAll(',', '.'));
                  return (n == null || n < 0) ? 'Geçerli bir oran girin' : null;
                },
              ),
            ),
          ]),
          _fieldGap,
          TextFormField(
            controller: _paymentTerms,
            decoration: const InputDecoration(labelText: 'Varsayılan Ödeme Koşulları'),
            maxLines: 2,
          ),
          _fieldGap,
          TextFormField(
            controller: _deliveryTerms,
            decoration: const InputDecoration(labelText: 'Varsayılan Teslimat Koşulları'),
            maxLines: 2,
          ),
          _fieldGap,
          TextFormField(
            controller: _footer,
            decoration: const InputDecoration(labelText: 'Teklif Alt Notu'),
            maxLines: 2,
          ),
          _errorText(_error),
          _submitRow(onSubmit: _submit, submitting: _submitting, label: widget.submitLabel, leading: widget.leading),
        ],
      ),
    );
  }
}

class FinanceStepForm extends StatefulWidget {
  const FinanceStepForm({
    super.key,
    required this.repository,
    required this.initial,
    required this.onSaved,
    this.submitLabel = 'Kaydet',
    this.leading,
  });

  final OnboardingRepository repository;
  final OrganizationCommercialSettings initial;
  final void Function(OnboardingState) onSaved;
  final String submitLabel;
  final Widget? leading;

  @override
  State<FinanceStepForm> createState() => _FinanceStepFormState();
}

class _FinanceStepFormState extends State<FinanceStepForm> {
  final _formKey = GlobalKey<FormState>();
  late final _bankName = TextEditingController(text: widget.initial.bankName);
  late final _accountHolder = TextEditingController(text: widget.initial.accountHolder);
  // IBAN alanı BİLİNÇLİ OLARAK önceden doldurulmaz (backend hiçbir zaman
  // plaintext IBAN döndürmez) -- boş bırakılırsa mevcut IBAN korunur.
  final _iban = TextEditingController();
  late final _paymentDueDays =
      TextEditingController(text: widget.initial.paymentDueDays?.toString() ?? '');
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _bankName.dispose();
    _accountHolder.dispose();
    _iban.dispose();
    _paymentDueDays.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final state = await widget.repository.saveFinance(
        bankName: _bankName.text.trim(),
        accountHolder: _accountHolder.text.trim(),
        iban: _iban.text.trim().isEmpty ? null : _iban.text.trim(),
        paymentDueDays: _paymentDueDays.text.trim().isEmpty ? null : int.tryParse(_paymentDueDays.text.trim()),
      );
      widget.onSaved(state);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(controller: _bankName, decoration: const InputDecoration(labelText: 'Banka Adı')),
          _fieldGap,
          TextFormField(
              controller: _accountHolder, decoration: const InputDecoration(labelText: 'Hesap Sahibi')),
          _fieldGap,
          TextFormField(
            controller: _iban,
            decoration: InputDecoration(
              labelText: 'IBAN',
              hintText: widget.initial.ibanSet ? 'Kayıtlı IBAN korunuyor -- değiştirmek için girin' : 'TR..',
            ),
            textCapitalization: TextCapitalization.characters,
          ),
          _fieldGap,
          TextFormField(
            controller: _paymentDueDays,
            decoration: const InputDecoration(labelText: 'Ödeme Vadesi (gün, opsiyonel)'),
            keyboardType: TextInputType.number,
          ),
          _errorText(_error),
          _submitRow(onSubmit: _submit, submitting: _submitting, label: widget.submitLabel, leading: widget.leading),
        ],
      ),
    );
  }
}

class BusinessStepForm extends StatefulWidget {
  const BusinessStepForm({
    super.key,
    required this.repository,
    required this.initial,
    required this.onSaved,
    this.submitLabel = 'Tamamla',
    this.leading,
  });

  final OnboardingRepository repository;
  final OrganizationProfile initial;
  final void Function(OnboardingState) onSaved;
  final String submitLabel;
  final Widget? leading;

  @override
  State<BusinessStepForm> createState() => _BusinessStepFormState();
}

class _BusinessStepFormState extends State<BusinessStepForm> {
  final _formKey = GlobalKey<FormState>();
  late String? _businessType =
      kBusinessTypeOptions.containsKey(widget.initial.businessType) ? widget.initial.businessType : null;
  bool _submitting = false;
  String? _error;

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final state = await widget.repository.saveBusiness(businessType: _businessType!);
      widget.onSaved(state);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            initialValue: _businessType,
            decoration: const InputDecoration(labelText: 'İşletme Türü'),
            items: kBusinessTypeOptions.entries
                .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                .toList(),
            onChanged: (v) => setState(() => _businessType = v),
            validator: (v) => v == null ? 'İşletme türü seçin' : null,
          ),
          _errorText(_error),
          _submitRow(onSubmit: _submit, submitting: _submitting, label: widget.submitLabel, leading: widget.leading),
        ],
      ),
    );
  }
}
