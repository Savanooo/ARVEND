import '../../../core/api/api_client.dart';
import '../domain/calc.dart';

class CalcRepository {
  CalcRepository(this._client);
  final ApiClient _client;

  /// `group_id` YOK -> nested grup+kategori kademeli listesi
  /// (bkz. API_CONTRACT.md - iki farklı gövde şekli).
  Future<List<CalcGroupWithCategories>> groupsWithCategories() async {
    final json = await _client.get<Map<String, dynamic>>('/calculations/categories');
    return (json['groups'] as List).cast<Map<String, dynamic>>().map(CalcGroupWithCategories.fromJson).toList();
  }

  Future<CalcRunResult> run({
    required String categoryId,
    String? area,
    String? width,
    String? height,
    String? perimeter,
    String? pitchDeg,
  }) async {
    final json = await _client.post<Map<String, dynamic>>('/calculations/run', data: {
      'category_id': categoryId,
      'area': area,
      'width': width,
      'height': height,
      'perimeter': perimeter,
      'pitch_deg': pitchDeg,
    });
    return CalcRunResult.fromJson(json);
  }
}
