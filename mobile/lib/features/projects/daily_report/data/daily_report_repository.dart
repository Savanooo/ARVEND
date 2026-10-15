import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/api/api_client.dart';
import '../../../../core/api/api_providers.dart';
import '../domain/daily_report.dart';

/// `/projects/{id}/daily-reports` uçları (backend migration 0071). Okuma ve
/// PDF `projects.operations.read`, kaydetme/gönderme
/// `projects.operations.manage` (proje erişimiyle):
/// - GET  /                 -> raporlar + bugün (İstanbul)
/// - GET  /{date}           -> günün raporu (yazılmamışsa exists=false) + otomatik veriler
/// - PUT  /{date}           -> yaz/güncelle (taşeron listesi bütünüyle)
/// - POST /{date}/submit    -> gönder (yöneticilere bildirim; ikinci kez 409)
/// - GET  /{date}/pdf       -> PDF
class DailyReportRepository {
  DailyReportRepository(this._client);
  final ApiClient _client;

  String _base(String projectId) => '/projects/${Uri.encodeComponent(projectId)}/daily-reports';
  String _day(String projectId, String date) => '${_base(projectId)}/${Uri.encodeComponent(date)}';

  Future<DailyReportList> list(String projectId) async =>
      DailyReportList.fromJson(await _client.get<Map<String, dynamic>>(_base(projectId)));

  Future<DailyReport> get(String projectId, String date) async =>
      DailyReport.fromJson(await _client.get<Map<String, dynamic>>(_day(projectId, date)));

  Future<DailyReport> save(String projectId, String date, DailyReportInput input) async =>
      DailyReport.fromJson(await _client.put<Map<String, dynamic>>(_day(projectId, date), data: input.toJson()));

  Future<DailyReport> submit(String projectId, String date) async =>
      DailyReport.fromJson(await _client.post<Map<String, dynamic>>('${_day(projectId, date)}/submit'));

  Future<Uint8List> pdf(String projectId, String date) => _client.getBytes('${_day(projectId, date)}/pdf');
}

final dailyReportRepositoryProvider =
    Provider<DailyReportRepository>((ref) => DailyReportRepository(ref.watch(apiClientProvider)));

final dailyReportsProvider = FutureProvider.autoDispose.family<DailyReportList, String>(
  (ref, projectId) => ref.watch(dailyReportRepositoryProvider).list(projectId),
);

typedef DailyReportKey = ({String projectId, String date});

final dailyReportProvider = FutureProvider.autoDispose.family<DailyReport, DailyReportKey>(
  (ref, key) => ref.watch(dailyReportRepositoryProvider).get(key.projectId, key.date),
);
