import '../../../core/api/api_client.dart';
import '../domain/cost_code.dart';

/// `/organization/cost-codes` uçları (backend router.go, Sprint 2). Web
/// `CostCodesManager.tsx` ile aynı çağrılar:
/// - GET  /            -> `{cost_codes: [...]}` (aktif + arşivlenmiş, kod sırasıyla)
/// - GET  /{id}        -> tek kod
/// - POST /            -> oluştur `{code, name, description, category}` (201)
/// - PUT  /{id}        -> güncelle `{name, description, category}` (kod DEĞİŞMEZ)
/// - DELETE /{id}      -> ARŞİVLE (hard delete DEĞİL, `is_active=false`)
/// - POST /{id}/reactivate -> yeniden etkinleştir
class CostCodesRepository {
  CostCodesRepository(this._client);
  final ApiClient _client;

  static const _base = '/organization/cost-codes';

  Future<List<OrganizationCostCode>> list() async {
    final json = await _client.get<Map<String, dynamic>>(_base);
    return (json['cost_codes'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(OrganizationCostCode.fromJson)
        .toList();
  }

  Future<OrganizationCostCode> get(String id) async {
    final json = await _client.get<Map<String, dynamic>>('$_base/$id');
    return OrganizationCostCode.fromJson(json);
  }

  Future<OrganizationCostCode> create({required String code, required CostCodeInput input}) async {
    final json = await _client.post<Map<String, dynamic>>(_base, data: input.toCreateJson(code));
    return OrganizationCostCode.fromJson(json);
  }

  Future<OrganizationCostCode> update(String id, CostCodeInput input) async {
    final json = await _client.put<Map<String, dynamic>>('$_base/$id', data: input.toUpdateJson());
    return OrganizationCostCode.fromJson(json);
  }

  Future<void> archive(String id) => _client.delete<void>('$_base/$id');

  Future<void> reactivate(String id) => _client.post<void>('$_base/$id/reactivate');
}
