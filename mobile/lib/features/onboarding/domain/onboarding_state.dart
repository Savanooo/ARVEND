/// backend/internal/httpapi/handler/onboarding_handler.go: onboardingStateResponse.
/// Hem GET /onboarding/ (ilk-giriş sihirbazı) hem GET /organization/settings/
/// (onboarding sonrası düzenleme) AYNI şekli döner -- ikisi de AYNI
/// backend state'ini (organizations.onboarding_step/onboarding_completed +
/// organization_profile/organization_commercial_settings) okur.
class OrganizationProfile {
  final String authorizedPerson;
  final String phone;
  final String email;
  final String website;
  final String logoObjectKey;
  final String legalName;
  final String taxOffice;
  final String taxNumber;
  final String invoiceAddress;
  final String city;
  final String district;
  final String country;
  final String businessType;

  const OrganizationProfile({
    required this.authorizedPerson,
    required this.phone,
    required this.email,
    required this.website,
    required this.logoObjectKey,
    required this.legalName,
    required this.taxOffice,
    required this.taxNumber,
    required this.invoiceAddress,
    required this.city,
    required this.district,
    required this.country,
    required this.businessType,
  });

  factory OrganizationProfile.fromJson(Map<String, dynamic> json) => OrganizationProfile(
        authorizedPerson: json['authorized_person'] as String? ?? '',
        phone: json['phone'] as String? ?? '',
        email: json['email'] as String? ?? '',
        website: json['website'] as String? ?? '',
        logoObjectKey: json['logo_object_key'] as String? ?? '',
        legalName: json['legal_name'] as String? ?? '',
        taxOffice: json['tax_office'] as String? ?? '',
        taxNumber: json['tax_number'] as String? ?? '',
        invoiceAddress: json['invoice_address'] as String? ?? '',
        city: json['city'] as String? ?? '',
        district: json['district'] as String? ?? '',
        country: json['country'] as String? ?? '',
        businessType: json['business_type'] as String? ?? '',
      );
}

/// IBAN, ASLA plaintext olarak dönmez (bkz. backend yorumu) -- yalnızca
/// [ibanSet] bir IBAN'ın kayıtlı olup olmadığını taşır (smtp password_set
/// ile aynı desen).
class OrganizationCommercialSettings {
  final String defaultCurrency;
  final double defaultVatRate;
  final String offerPrefix;
  final int offerValidityDays;
  final String defaultOfferFooter;
  final String defaultPaymentTerms;
  final String defaultDeliveryTerms;
  final String bankName;
  final String accountHolder;
  final bool ibanSet;
  final int? paymentDueDays;

  const OrganizationCommercialSettings({
    required this.defaultCurrency,
    required this.defaultVatRate,
    required this.offerPrefix,
    required this.offerValidityDays,
    required this.defaultOfferFooter,
    required this.defaultPaymentTerms,
    required this.defaultDeliveryTerms,
    required this.bankName,
    required this.accountHolder,
    required this.ibanSet,
    this.paymentDueDays,
  });

  factory OrganizationCommercialSettings.fromJson(Map<String, dynamic> json) =>
      OrganizationCommercialSettings(
        defaultCurrency: json['default_currency'] as String? ?? 'TRY',
        defaultVatRate: (json['default_vat_rate'] as num?)?.toDouble() ?? 20,
        offerPrefix: json['offer_prefix'] as String? ?? 'TKF',
        offerValidityDays: (json['offer_validity_days'] as num?)?.toInt() ?? 30,
        defaultOfferFooter: json['default_offer_footer'] as String? ?? '',
        defaultPaymentTerms: json['default_payment_terms'] as String? ?? '',
        defaultDeliveryTerms: json['default_delivery_terms'] as String? ?? '',
        bankName: json['bank_name'] as String? ?? '',
        accountHolder: json['account_holder'] as String? ?? '',
        ibanSet: json['iban_set'] as bool? ?? false,
        paymentDueDays: (json['payment_due_days'] as num?)?.toInt(),
      );
}

class OnboardingState {
  final bool onboardingCompleted;
  final String onboardingStep;
  final OrganizationProfile profile;
  final OrganizationCommercialSettings commercial;

  const OnboardingState({
    required this.onboardingCompleted,
    required this.onboardingStep,
    required this.profile,
    required this.commercial,
  });

  factory OnboardingState.fromJson(Map<String, dynamic> json) => OnboardingState(
        onboardingCompleted: json['onboarding_completed'] as bool? ?? false,
        onboardingStep: json['onboarding_step'] as String? ?? 'company',
        profile: OrganizationProfile.fromJson(json['profile'] as Map<String, dynamic>? ?? const {}),
        commercial: OrganizationCommercialSettings.fromJson(
            json['commercial'] as Map<String, dynamic>? ?? const {}),
      );
}

/// Sıradaki adımı belirlemek/ilerlemeyi göstermek için -- backend'deki
/// domain.OnboardingStep sırasının Dart karşılığı. Backend forward-only
/// ilerletiyor, burada yalnızca UI'da "kaçıncı adımdayız" göstermek için
/// kullanılır (sunucu her zaman otoriter kaynaktır).
const kOnboardingStepOrder = ['company', 'billing', 'offers', 'finance', 'business', 'completed'];

int onboardingStepIndex(String step) {
  final i = kOnboardingStepOrder.indexOf(step);
  return i < 0 ? 0 : i;
}
