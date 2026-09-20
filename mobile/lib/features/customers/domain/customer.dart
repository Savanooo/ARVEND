import '../../projects/domain/project.dart';

/// backend `customerResponse` - phone/email HER ZAMAN present, null değil
/// boş string (bkz. API_CONTRACT.md).
class Customer {
  final String id;
  final String name;
  final String phone;
  final String email;
  final String address;
  final String taxOffice;
  final String taxNumber;
  final String notes;
  final bool isActive;

  const Customer({
    required this.id,
    required this.name,
    required this.phone,
    required this.email,
    required this.address,
    required this.taxOffice,
    required this.taxNumber,
    required this.notes,
    required this.isActive,
  });

  factory Customer.fromJson(Map<String, dynamic> json) => Customer(
        id: json['id'] as String,
        name: json['name'] as String,
        phone: json['phone'] as String? ?? '',
        email: json['email'] as String? ?? '',
        address: json['address'] as String? ?? '',
        taxOffice: json['tax_office'] as String? ?? '',
        taxNumber: json['tax_number'] as String? ?? '',
        notes: json['notes'] as String? ?? '',
        isActive: json['is_active'] as bool? ?? true,
      );
}

/// Bir müşterinin projelerindeki, backend'in ZATEN hesapladığı
/// (current_contract_value/collected_amount/remaining_receivable, yalnızca
/// `GET /projects` liste ucunda dolu -- bkz. project.dart yorumu) alanların
/// para birimine göre toplamı. Yeni bir hesap/formül İCAT EDİLMEZ --
/// yalnızca aynı para birimindeki, zaten var olan sayılar toplanır. Farklı
/// para birimleri KARIŞTIRILMAZ; her biri kendi satırında kalır.
class CustomerReceivablesSummary {
  final String currency;
  final double contractValue;
  final double collected;
  final double remaining;

  const CustomerReceivablesSummary({
    required this.currency,
    required this.contractValue,
    required this.collected,
    required this.remaining,
  });
}

List<CustomerReceivablesSummary> summarizeProjectReceivables(List<Project> projects) {
  final byCurrency = <String, (double, double, double)>{};
  for (final p in projects) {
    if (p.currentContractValue == null || p.collectedAmount == null || p.remainingReceivable == null) continue;
    final prev = byCurrency[p.currency] ?? (0.0, 0.0, 0.0);
    byCurrency[p.currency] = (
      prev.$1 + p.currentContractValue!,
      prev.$2 + p.collectedAmount!,
      prev.$3 + p.remainingReceivable!,
    );
  }
  return byCurrency.entries
      .map((e) => CustomerReceivablesSummary(
            currency: e.key,
            contractValue: e.value.$1,
            collected: e.value.$2,
            remaining: e.value.$3,
          ))
      .toList();
}

