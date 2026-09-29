/// Planlama/Ekip/Erişim ekranlarının mutlak yolları -- rotalar proje
/// detayının (`/projeler/:id`) ALTINA kaydedilir (bkz. ops_team_routes.dart).
library;

String _project(String projectId) => '/projeler/${Uri.encodeComponent(projectId)}';

/// `/projeler/:id/planlama` -- iş programı (tam ekran).
String schedulePath(String projectId) => '${_project(projectId)}/planlama';

/// `/projeler/:id/planlama/yeni` -- yeni aşama.
String scheduleNewPath(String projectId) => '${schedulePath(projectId)}/yeni';

/// `/projeler/:id/planlama/:itemId` -- aşama detayı.
String scheduleItemPath(String projectId, String itemId) =>
    '${schedulePath(projectId)}/${Uri.encodeComponent(itemId)}';

/// `/projeler/:id/planlama/:itemId/duzenle` -- aşamayı düzenle.
String scheduleItemEditPath(String projectId, String itemId) => '${scheduleItemPath(projectId, itemId)}/duzenle';

/// `/projeler/:id/ekip` -- proje ekibi (personel roster'ı).
String teamPath(String projectId) => '${_project(projectId)}/ekip';

/// `/projeler/:id/erisim` -- proje erişimi (uygulama kullanıcıları).
String accessPath(String projectId) => '${_project(projectId)}/erisim';
