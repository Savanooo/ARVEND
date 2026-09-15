import '../../../core/api/api_client.dart';
import '../domain/onboarding_state.dart';

/// /api/v1/onboarding/* (ilk-giriş sihirbazı) VE /api/v1/organization/
/// settings/* (onboarding sonrası "Firma Ayarları" düzenleme) AYNI backend
/// handler'ına (OnboardingHandler) bağlanır, yalnızca mount path'i farklıdır
/// -- bu repository de [basePath] parametresiyle ikisine de hizmet eder.
class OnboardingRepository {
  OnboardingRepository(this._client, {required this._basePath});

  final ApiClient _client;
  final String _basePath;

  Future<OnboardingState> getState() async {
    final json = await _client.get<Map<String, dynamic>>(_basePath);
    return OnboardingState.fromJson(json);
  }

  Future<OnboardingState> saveCompany({
    required String authorizedPerson,
    String phone = '',
    String email = '',
    String website = '',
    String city = '',
    String district = '',
    String country = '',
  }) async {
    final json = await _client.put<Map<String, dynamic>>('$_basePath/company', data: {
      'authorized_person': authorizedPerson,
      'phone': phone,
      'email': email,
      'website': website,
      'city': city,
      'district': district,
      'country': country,
    });
    return OnboardingState.fromJson(json);
  }

  Future<OnboardingState> saveBilling({
    required String legalName,
    String taxOffice = '',
    required String taxNumber,
    String invoiceAddress = '',
  }) async {
    final json = await _client.put<Map<String, dynamic>>('$_basePath/billing', data: {
      'legal_name': legalName,
      'tax_office': taxOffice,
      'tax_number': taxNumber,
      'invoice_address': invoiceAddress,
    });
    return OnboardingState.fromJson(json);
  }

  Future<OnboardingState> saveOffers({
    String defaultCurrency = 'TRY',
    double defaultVatRate = 20,
    String offerPrefix = 'TKF',
    int offerValidityDays = 30,
    String defaultOfferFooter = '',
    String defaultPaymentTerms = '',
    String defaultDeliveryTerms = '',
  }) async {
    final json = await _client.put<Map<String, dynamic>>('$_basePath/offers', data: {
      'default_currency': defaultCurrency,
      'default_vat_rate': defaultVatRate,
      'offer_prefix': offerPrefix,
      'offer_validity_days': offerValidityDays,
      'default_offer_footer': defaultOfferFooter,
      'default_payment_terms': defaultPaymentTerms,
      'default_delivery_terms': defaultDeliveryTerms,
    });
    return OnboardingState.fromJson(json);
  }

  /// [iban] null ise mevcut IBAN korunur; boş string verilirse temizlenir
  /// (backend konvansiyonu, SMTP şifresiyle aynı).
  Future<OnboardingState> saveFinance({
    String bankName = '',
    String accountHolder = '',
    String? iban,
    int? paymentDueDays,
  }) async {
    final json = await _client.put<Map<String, dynamic>>('$_basePath/finance', data: {
      'bank_name': bankName,
      'account_holder': accountHolder,
      'iban': ?iban,
      'payment_due_days': paymentDueDays,
    });
    return OnboardingState.fromJson(json);
  }

  /// Sihirbaz bağlamında bu adım onboarding'i de TAMAMLAR (bkz. backend
  /// SaveBusinessStep) -- Firma Ayarları bağlamında da AYNI uçtur, tekrar
  /// çağırmak zararsızdır (idempotent).
  Future<OnboardingState> saveBusiness({
    required String businessType,
    String? logoObjectKey,
  }) async {
    final json = await _client.put<Map<String, dynamic>>('$_basePath/business', data: {
      'business_type': businessType,
      'logo_object_key': ?logoObjectKey,
    });
    return OnboardingState.fromJson(json);
  }
}

/// backend/internal/domain/onboarding.go: BusinessTypeWhitelist.
const kBusinessTypeOptions = <String, String>{
  'insaat_taahhut': 'İnşaat / Taahhüt',
  'tasarim_mimarlik': 'Tasarım / Mimarlık',
  'muhendislik_danismanlik': 'Mühendislik / Danışmanlık',
  'tedarik_montaj': 'Tedarik / Montaj',
  'diger': 'Diğer',
};
