/// Proje operasyon/ekip/erişim ekranlarının izin kodları -- backend
/// `router.go` ile BİREBİR:
///
/// - `/projects/{id}/schedule`, `/projects/{id}/members` okuma
///   `projects.operations.read`, yazma `projects.operations.manage`
///   (Faz 7 operasyon grubu -- dosya/fotoğraf/not ile AYNI izin çifti).
/// - `/projects/{id}/access` okuma `projects.access.read`, ekle/rol
///   değiştir/kaldır `projects.access.manage`.
///
/// Hepsi `projPerm` ile korunur: izin + proje üyeliği backend'de her
/// istekte ayrıca doğrulanır. Mobildeki kontrol (`UserCan.can`, proje
/// detayındaki `_failOpen` ile aynı anlam) yalnızca UX'tir.
library;

const kProjectOpsReadPermission = 'projects.operations.read';
const kProjectOpsManagePermission = 'projects.operations.manage';
const kProjectAccessReadPermission = 'projects.access.read';
const kProjectAccessManagePermission = 'projects.access.manage';

/// "Erişim Ver" seçicisi `GET /users` -- `requireAdmin` + bu izin
/// (`UserAccess.canAccess` ikisini birlikte denetler).
const kOrgUsersReadPermission = 'organization.users.read';

/// Tamamlanmış/iptal edilmiş projede yeni operasyon kaydı açılamaz
/// (backend `requireOpenProject` -> 409 "proje kilitli"); web `locked`
/// ile aynı karar. Proje erişimi bu kilide TABİ DEĞİLDİR (web de
/// kilitlemiyor, backend de kontrol etmiyor).
bool isProjectLocked(String status) => status == 'completed' || status == 'cancelled';
