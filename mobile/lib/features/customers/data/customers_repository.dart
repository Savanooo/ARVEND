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
}
