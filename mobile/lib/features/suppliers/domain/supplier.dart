/// Tedarikçi kataloğu (Sprint 4, organizasyon-seviyeli, projeler arası
/// PAYLAŞILAN) izin kodları -- backend router.go `/organization/suppliers`:
/// liste/detay `.read`, ekle/düzenle/arşivle/etkinleştir `.manage` ister.
/// requireAdmin YOKTUR (web `SuppliersManager` ile aynı): izni olan her üye
/// girer, `.manage` yoksa ekran salt-okunur çalışır.
const kSuppliersReadPermission = 'organization.suppliers.read';
const kSuppliersManagePermission = 'organization.suppliers.manage';

/// backend `supplierResponse` (supplier_handler.go) -- metin alanları HER
/// ZAMAN string döner (boş olabilir), null gelmez; yine de savunmacı
/// okunur. IBAN'ın KENDİSİ hiçbir yanıtta DÖNMEZ (şifreli saklanır), yalnızca
/// `iban_set` boolean'ı görünür -- bu modelde IBAN alanı bilinçli olarak YOK.
///
/// `projects/domain/subcontract.dart`'taki `Supplier` (taşeron formunda
/// seçim için minimal izdüşüm) İLE KARIŞTIRILMAMASI için ayrı ad taşır.
class OrganizationSupplier {
  const OrganizationSupplier({
    required this.id,
    required this.code,
    required this.legalName,
    this.tradeName = '',
    this.taxNumber = '',
    this.taxOffice = '',
    this.contactName = '',
    this.email = '',
    this.phone = '',
    this.address = '',
    this.city = '',
    this.country = '',
    this.specialty = '',
    this.notes = '',
    this.ibanSet = false,
    this.isActive = true,
    this.createdAt = '',
    this.updatedAt = '',
  });

  final String id;
  final String code;
  final String legalName;
  final String tradeName;
  final String taxNumber;
  final String taxOffice;
  final String contactName;
  final String email;
  final String phone;
  final String address;
  final String city;
  final String country;

  /// Branş/uzmanlık (migration 0038, taşeron seçimi için eklendi). Web
  /// formunda alanı yok; mobil hem gösterir hem düzenler -- güncellemede
  /// gönderilmezse backend boş string yazıp SİLER, bu yüzden form mevcut
  /// değeri her zaman geri gönderir.
  final String specialty;
  final String notes;
  final bool ibanSet;
  final bool isActive;

  /// RFC3339.
  final String createdAt;
  final String updatedAt;

  /// Web listesindeki "İletişim" sütunu: yetkili kişi, yoksa telefon, yoksa
  /// e-posta (hiçbiri yoksa boş).
  String get contactSummary => [contactName, phone, email].firstWhere((v) => v.isNotEmpty, orElse: () => '');

  factory OrganizationSupplier.fromJson(Map<String, dynamic> json) => OrganizationSupplier(
        id: json['id'] as String,
        code: json['code'] as String? ?? '',
        legalName: json['legal_name'] as String? ?? '',
        tradeName: json['trade_name'] as String? ?? '',
        taxNumber: json['tax_number'] as String? ?? '',
        taxOffice: json['tax_office'] as String? ?? '',
        contactName: json['contact_name'] as String? ?? '',
        email: json['email'] as String? ?? '',
        phone: json['phone'] as String? ?? '',
        address: json['address'] as String? ?? '',
        city: json['city'] as String? ?? '',
        country: json['country'] as String? ?? '',
        specialty: json['specialty'] as String? ?? '',
        notes: json['notes'] as String? ?? '',
        ibanSet: json['iban_set'] as bool? ?? false,
        isActive: json['is_active'] as bool? ?? true,
        createdAt: json['created_at'] as String? ?? '',
        updatedAt: json['updated_at'] as String? ?? '',
      );
}

/// POST/PUT gövdesi (backend `supplierRequest`). `code` yalnızca oluşturmada
/// anlamlıdır -- backend `UpdateSupplier` sorgusu kodu HİÇ yazmaz (kod
/// oluşturulduktan sonra değişmez); web gibi yine de gönderilir.
///
/// IBAN üç durumludur (backend `SupplierService.encryptIBAN`): alan YOK =
/// değiştirme, "" = temizle, dolu = şifrele. Web gibi mobil de yalnızca
/// "değiştirme" ve "yeni değer yaz" durumlarını kullanır: `iban` null ya da
/// boşsa anahtar gövdeden TAMAMEN çıkarılır.
class SupplierInput {
  const SupplierInput({
    required this.code,
    required this.legalName,
    this.tradeName = '',
    this.taxNumber = '',
    this.taxOffice = '',
    this.contactName = '',
    this.email = '',
    this.phone = '',
    this.address = '',
    this.city = '',
    this.country = '',
    this.specialty = '',
    this.notes = '',
    this.iban,
  });

  final String code;
  final String legalName;
  final String tradeName;
  final String taxNumber;
  final String taxOffice;
  final String contactName;
  final String email;
  final String phone;
  final String address;
  final String city;
  final String country;
  final String specialty;
  final String notes;
  final String? iban;

  Map<String, dynamic> toJson() => {
        'code': code,
        'legal_name': legalName,
        'trade_name': tradeName,
        'tax_number': taxNumber,
        'tax_office': taxOffice,
        'contact_name': contactName,
        'email': email,
        'phone': phone,
        'address': address,
        'city': city,
        'country': country,
        'specialty': specialty,
        if (iban != null && iban!.trim().isNotEmpty) 'iban': iban!.trim(),
        'notes': notes,
      };
}

/// Liste filtresi -- backend TÜM tedarikçileri (aktif + arşivlenmiş) tek
/// seferde döner (bkz. ListSuppliers sorgu yorumu), süzme istemcidedir.
/// Varsayılan `active`: web'deki "Arşivlenmiş tedarikçileri de göster"
/// kutusu kapalıyken olduğu gibi.
enum SupplierStatusFilter { active, archived, all }

/// Web `SuppliersManager` ile aynı arama alanları: kod, unvan, ticari ad.
/// Türkçe büyük/küçük harf duyarsız (İ/I/ı/i aynı sayılır).
List<OrganizationSupplier> filterSuppliers(
  List<OrganizationSupplier> all, {
  String query = '',
  SupplierStatusFilter status = SupplierStatusFilter.active,
}) {
  final q = foldForSearch(query.trim());
  return [
    for (final s in all)
      if (_statusMatches(s.isActive, status) &&
          (q.isEmpty ||
              foldForSearch(s.code).contains(q) ||
              foldForSearch(s.legalName).contains(q) ||
              foldForSearch(s.tradeName).contains(q)))
        s,
  ];
}

bool _statusMatches(bool isActive, SupplierStatusFilter status) => switch (status) {
      SupplierStatusFilter.active => isActive,
      SupplierStatusFilter.archived => !isActive,
      SupplierStatusFilter.all => true,
    };

/// Aramada Türkçe harf farklarını yok sayar: `toLowerCase()` "İ"yi "i̇"
/// (noktalı birleşik karakter) yapar ve "I"yı "ı"ya çevirmez -- bu yüzden
/// önce dört "i" biçimi tek "i"ye indirilir.
String foldForSearch(String value) =>
    value.replaceAll('İ', 'i').replaceAll('I', 'i').replaceAll('ı', 'i').toLowerCase();

/// IBAN normalizasyonu: boşluklar atılır, harfler büyütülür ("tr12 0006
/// ..." -> "TR120006...").
String normalizeIban(String raw) => raw.replaceAll(RegExp(r'\s+'), '').toUpperCase();

/// ISO 13616 IBAN doğrulaması (biçim + mod-97 kontrol basamağı). IBAN
/// yalnızca YAZILABİLİR bir alandır -- kaydedildikten sonra hiçbir ekranda
/// geri okunamadığı için yazım hatası sonradan fark edilemez; bu yüzden
/// kaydetmeden ÖNCE burada yakalanır. TR IBAN'ları 26 karakterdir.
bool isValidIban(String normalized) {
  if (!RegExp(r'^[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}$').hasMatch(normalized)) return false;
  if (normalized.startsWith('TR') && normalized.length != 26) return false;
  final rearranged = normalized.substring(4) + normalized.substring(0, 4);
  var remainder = 0;
  for (final unit in rearranged.codeUnits) {
    // '0'-'9' -> 0-9, 'A'-'Z' -> 10-35 (iki basamak).
    final value = unit >= 65 ? unit - 55 : unit - 48;
    remainder = value >= 10 ? (remainder * 100 + value) % 97 : (remainder * 10 + value) % 97;
  }
  return remainder == 1;
}
