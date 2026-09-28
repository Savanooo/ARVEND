/// Maliyet kodu kataloğu (Sprint 2, organizasyon-seviyeli, projeler arası
/// PAYLAŞILAN) izin kodları -- backend router.go `/organization/cost-codes`:
/// liste/detay `.read`, ekle/düzenle/arşivle/etkinleştir `.manage` ister.
/// requireAdmin YOKTUR (web `CostCodesManager` ile aynı).
const kCostCodesReadPermission = 'organization.cost_codes.read';
const kCostCodesManagePermission = 'organization.cost_codes.manage';

/// Kategorisi boş kodların grubu (listede en sonda).
const kUncategorizedLabel = 'Kategorisiz';

/// backend `costCodeResponse` (cost_code_handler.go). WBS (projeye özel
/// ağaç) İLE KARIŞTIRILMAMALI -- bkz. docs/cost-control.md "WBS ≠ Cost Code".
/// `projects/domain/subcontract.dart`'taki `OrgCostCode` (SOV kalemi
/// seçicisi için minimal izdüşüm) ayrı bir tiptir; bu tam kayıt web
/// `OrganizationCostCode` tipiyle aynı adı taşır.
class OrganizationCostCode {
  const OrganizationCostCode({
    required this.id,
    required this.code,
    required this.name,
    this.description = '',
    this.category = '',
    this.isActive = true,
  });

  final String id;
  final String code;
  final String name;
  final String description;
  final String category;
  final bool isActive;

  factory OrganizationCostCode.fromJson(Map<String, dynamic> json) => OrganizationCostCode(
        id: json['id'] as String,
        code: json['code'] as String? ?? '',
        name: json['name'] as String? ?? '',
        description: json['description'] as String? ?? '',
        category: json['category'] as String? ?? '',
        isActive: json['is_active'] as bool? ?? true,
      );
}

/// POST gövdesi `{code, name, description, category}`; PUT gövdesi web gibi
/// KODSUZ `{name, description, category}` -- backend `UpdateOrganizationCostCode`
/// kodu hiç yazmaz (kod oluşturulduktan sonra DEĞİŞMEZ, bkz.
/// CostCodeService.Update yorumu).
class CostCodeInput {
  const CostCodeInput({required this.name, this.description = '', this.category = ''});

  final String name;
  final String description;
  final String category;

  Map<String, dynamic> toUpdateJson() => {'name': name, 'description': description, 'category': category};

  Map<String, dynamic> toCreateJson(String code) => {'code': code, ...toUpdateJson()};
}

/// Liste filtresi -- backend TÜM kodları (aktif + arşivlenmiş) döner,
/// süzme istemcidedir. Varsayılan `active` (web'de "Arşivlenmiş kodları da
/// göster" kapalıyken olduğu gibi).
enum CostCodeStatusFilter { active, archived, all }

/// Web `CostCodesManager` ile aynı arama alanları: kod, ad, kategori.
/// Türkçe büyük/küçük harf duyarsız.
List<OrganizationCostCode> filterCostCodes(
  List<OrganizationCostCode> all, {
  String query = '',
  CostCodeStatusFilter status = CostCodeStatusFilter.active,
}) {
  final q = _fold(query.trim());
  return [
    for (final c in all)
      if (_statusMatches(c.isActive, status) &&
          (q.isEmpty || _fold(c.code).contains(q) || _fold(c.name).contains(q) || _fold(c.category).contains(q)))
        c,
  ];
}

bool _statusMatches(bool isActive, CostCodeStatusFilter status) => switch (status) {
      CostCodeStatusFilter.active => isActive,
      CostCodeStatusFilter.archived => !isActive,
      CostCodeStatusFilter.all => true,
    };

/// Kategori grubu: başlık + o kategorideki kodlar (backend'in kod sırası
/// korunur).
class CostCodeGroup {
  const CostCodeGroup({required this.category, required this.codes});

  /// Boş kategori için [kUncategorizedLabel].
  final String category;
  final List<OrganizationCostCode> codes;

  bool get isUncategorized => category == kUncategorizedLabel;
}

/// Kodları kategoriye göre gruplar. Kategoriler Türkçe alfabe sırasıyla
/// (Ç/Ğ/İ/Ö/Ş/Ü doğru yerde) dizilir, büyük/küçük harf ve baştaki/sondaki
/// boşluk farkı aynı grup sayılır (ilk görülen yazım başlık olur);
/// kategorisizler en sonda.
List<CostCodeGroup> groupCostCodesByCategory(List<OrganizationCostCode> codes) {
  final groups = <String, (String, List<OrganizationCostCode>)>{};
  for (final c in codes) {
    final label = c.category.trim();
    final key = label.isEmpty ? '' : _fold(label);
    final entry = groups.putIfAbsent(key, () => (label.isEmpty ? kUncategorizedLabel : label, <OrganizationCostCode>[]));
    entry.$2.add(c);
  }
  final keys = groups.keys.toList()
    ..sort((a, b) {
      if (a.isEmpty) return b.isEmpty ? 0 : 1;
      if (b.isEmpty) return -1;
      return compareTurkish(groups[a]!.$1, groups[b]!.$1);
    });
  return [for (final k in keys) CostCodeGroup(category: groups[k]!.$1, codes: groups[k]!.$2)];
}

/// Mevcut, boş olmayan kategori adları (form hızlı seçimi için) -- aynı
/// gruplama kuralıyla tekilleştirilmiş, Türkçe alfabe sırasıyla.
List<String> distinctCategories(List<OrganizationCostCode> codes) => [
      for (final g in groupCostCodesByCategory(codes))
        if (!g.isUncategorized) g.category,
    ];

const _trAlphabet = 'abcçdefgğhıijklmnoöprsştuüvyz';

/// Türkçe alfabe sırasıyla karşılaştırma (Dart'ın `compareTo`'su kod
/// noktasına göre dizer: "İşçilik" "Taşeron"un ARDINA düşerdi). Alfabe dışı
/// karakterler (rakam, q/w/x vb.) kod noktası sırasıyla harflerin önüne/
/// arkasına yerleşir.
int compareTurkish(String a, String b) {
  final x = _lowerTr(a);
  final y = _lowerTr(b);
  final n = x.length < y.length ? x.length : y.length;
  for (var i = 0; i < n; i++) {
    final ca = _rank(x[i]);
    final cb = _rank(y[i]);
    if (ca != cb) return ca.compareTo(cb);
  }
  return x.length.compareTo(y.length);
}

int _rank(String ch) {
  final i = _trAlphabet.indexOf(ch);
  // Alfabe harfleri 1000+ aralığında: rakamlar/noktalama önce gelir.
  return i >= 0 ? 1000 + i * 2 : (ch.codeUnitAt(0) < 'a'.codeUnitAt(0) ? ch.codeUnitAt(0) : 2000 + ch.codeUnitAt(0));
}

String _lowerTr(String s) => s.replaceAll('İ', 'i').replaceAll('I', 'ı').toLowerCase();

/// Aramada dört "i" biçimi (İ/I/ı/i) aynı sayılır.
String _fold(String value) => value.replaceAll('İ', 'i').replaceAll('I', 'i').replaceAll('ı', 'i').toLowerCase();
