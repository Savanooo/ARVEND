import '../../../core/api/api_client.dart';
import '../domain/customer.dart';

class CustomersRepository {
  CustomersRepository(this._client);
  final ApiClient _client;

  /// `q` yalnızca `name` alanında arar (bkz. API_CONTRACT.md) - telefon/
  /// e-posta araması backend'de desteklenmiyor.
  Future<List<Customer>> list({String filter = '', String q = ''}) async {
    final json = await _client.get<Map<String, dynamic>>('/customers', query: {
      if (filter.isNotEmpty) 'filter': filter,
      if (q.isNotEmpty) 'q': q,
    });
    return (json['customers'] as List).cast<Map<String, dynamic>>().map(Customer.fromJson).toList();
  }

  Future<Customer> get(String id) async {
    final json = await _client.get<Map<String, dynamic>>('/customers/$id');
    return Customer.fromJson(json);
  }

  Future<Customer> create({
    required String name,
    String phone = '',
    String email = '',
    String address = '',
    String taxOffice = '',
    String taxNumber = '',
    String notes = '',
  }) async {
    final json = await _client.post<Map<String, dynamic>>('/customers', data: {
      'name': name,
      'phone': phone,
      'email': email,
      'address': address,
      'tax_office': taxOffice,
      'tax_number': taxNumber,
      'notes': notes,
      'is_active': true,
    });
    return Customer.fromJson(json);
  }

  /// Create'in aksine `is_active` backend'de burada CLIENT'tan gelen
  /// değeri aynen kullanır (bkz. backend Phase 1 doğrulaması:
  /// `customer_handler.go` Create'de zorla `true`'ya sabitler, Update'de
  /// sabitlemez) -- bu yüzden mevcut değeri korumak isteyen çağıran
  /// `isActive: existing.isActive` geçirmelidir.
  Future<Customer> update(
    String id, {
    required String name,
    String phone = '',
    String email = '',
    String address = '',
    String taxOffice = '',
    String taxNumber = '',
    String notes = '',
    required bool isActive,
  }) async {
    final json = await _client.put<Map<String, dynamic>>('/customers/$id', data: {
      'name': name,
      'phone': phone,
      'email': email,
      'address': address,
      'tax_office': taxOffice,
      'tax_number': taxNumber,
      'notes': notes,
      'is_active': isActive,
    });
    return Customer.fromJson(json);
  }

  /// DELETE /customers/{id} -- backend'de bu bir HARD DELETE değil, soft
  /// archive'dır (`is_active = false`, bkz. backend Phase 1 doğrulaması:
  /// `CustomerService.Archive` -> `ArchiveCustomer` SQL'i `UPDATE ... SET
  /// is_active = false`, asla `DELETE FROM customers` yok). Bu yüzden
  /// mobilde güvenle sunulabilir.
  Future<void> archive(String id) => _client.delete<void>('/customers/$id');

  /// Pasif (arşivlenmiş) müşteriyi yeniden aktifleştirir -- web ile AYNI
  /// uç: `PUT /customers/{id}` ve `is_active: true`. PUT tüm alanları
  /// yazdığı için mevcut bilgiler aynen geri gönderilir.
  Future<Customer> reactivate(Customer c) => update(
        c.id,
        name: c.name,
        phone: c.phone,
        email: c.email,
        address: c.address,
        taxOffice: c.taxOffice,
        taxNumber: c.taxNumber,
        notes: c.notes,
        isActive: true,
      );
}
