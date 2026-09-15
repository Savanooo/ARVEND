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
