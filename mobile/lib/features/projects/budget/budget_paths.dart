// Bütçe & Maliyet Kontrolü ekranlarının MUTLAK yolları. Rotalar proje
// detayının (`/projeler/:id`) ALTINA göreli olarak kaydedilir (bkz.
// budget_routes.dart); ekranlar birbirine bu yardımcılarla `push` eder.

/// Maliyet Kontrolü merkezinin tam ekran hâli (proje detayındaki Finans >
/// Maliyet Kontrolü sekmesiyle aynı gövde).
String costControlPath(String projectId) => '/projeler/${Uri.encodeComponent(projectId)}/maliyet';

String budgetPath(String projectId) => '${costControlPath(projectId)}/butce';

String budgetLineCreatePath(String projectId) => '${budgetPath(projectId)}/kalemler/yeni';

String budgetLineEditPath(String projectId, String lineId) =>
    '${budgetPath(projectId)}/kalemler/${Uri.encodeComponent(lineId)}/duzenle';

String wbsPath(String projectId) => '${costControlPath(projectId)}/wbs';

String budgetAdjustmentsPath(String projectId) => '${costControlPath(projectId)}/revizyonlar';

String commitmentsPath(String projectId) => '${costControlPath(projectId)}/taahhutler';

String commitmentCreatePath(String projectId) => '${commitmentsPath(projectId)}/yeni';

String forecastPath(String projectId) => '${costControlPath(projectId)}/tahmin';

String actualCostPath(String projectId) => '${costControlPath(projectId)}/gerceklesen';
