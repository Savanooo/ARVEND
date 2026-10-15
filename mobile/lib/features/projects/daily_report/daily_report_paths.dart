/// Günlük şantiye raporu yolları (proje detayının alt rotaları, bkz.
/// daily_report_routes.dart). [date] YYYY-AA-GG.
String dailyReportsPath(String projectId) => '/projeler/${Uri.encodeComponent(projectId)}/gunluk-rapor';

String dailyReportPath(String projectId, String date) => '${dailyReportsPath(projectId)}/${Uri.encodeComponent(date)}';
