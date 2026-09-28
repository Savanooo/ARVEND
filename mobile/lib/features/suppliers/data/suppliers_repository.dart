import '../../../core/api/api_client.dart';
import '../domain/supplier.dart';

/// `/organization/suppliers` uçları (backend router.go, Sprint 4). Web
/// `SuppliersManager.tsx` ile aynı çağrılar:
/// - GET  /            -> `{suppliers: [...]}` (aktif + arşivlenmiş, kod sırasıyla)
/// - GET  /{id}        -> tek tedarikçi
/// - POST /            -> oluştur (201, tedarikçi döner)
/// - PUT  /{id}        -> güncelle (kod DEĞİŞMEZ)
/// - DELETE /{id}      -> ARŞİVLE (hard delete DEĞİL, `is_active=false`, 204)
/// - POST /{id}/reactivate -> yeniden etkinleştir (204)
class SuppliersRepository {
  SuppliersRepository(this._client);
  final ApiClient _client;

  static const _base = '/organization/suppliers';

  Future<List<OrganizationSupplier>> list() async {
    final json = await _client.get<Map<String, dynamic>>(_base);
    return (json['suppliers'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(OrganizationSupplier.fromJson)
        .toList();
  }

  Future<OrganizationSupplier> get(String id) async {
    final json = await _client.get<Map<String, dynamic>>('$_base/$id');
    return OrganizationSupplier.fromJson(json);
  }

  Future<OrganizationSupplier> create(SupplierInput input) async {
    final json = await _client.post<Map<String, dynamic>>(_base, data: input.toJson());
    return OrganizationSupplier.fromJson(json);
  }

  Future<OrganizationSupplier> update(String id, SupplierInput input) async {
    final json = await _client.put<Map<String, dynamic>>('$_base/$id', data: input.toJson());
    return OrganizationSupplier.fromJson(json);
  }

  Future<void> archive(String id) => _client.delete<void>('$_base/$id');

  Future<void> reactivate(String id) => _client.post<void>('$_base/$id/reactivate');
}
