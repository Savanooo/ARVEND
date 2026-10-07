/// Proje ekibi (İK/puantaj roster'ı, `project_members`) -- `employee_id`'ye
/// bağlıdır, login hesabıyla İLGİSİ YOK. "Proje Erişimi" (`project_users`,
/// uygulama kullanıcıları) İLE KARIŞTIRILMAMALI (bkz. project_access.dart).
library;

/// `GET /projects/{id}/members` satırı (backend `memberResponse`). Ekipten
/// çıkarılan üye SİLİNMEZ: `end_date` yazılır ve `is_active=false` olur;
/// liste önce aktifleri, sonra geçmişi döner.
class ProjectTeamMember {
  const ProjectTeamMember({
    required this.id,
    required this.employeeId,
    required this.employeeName,
    this.roleTitle = '',
    this.startDate,
    this.endDate,
    this.notes = '',
    this.isActive = true,
  });

  final String id;
  final String employeeId;

  /// Atama anındaki ad (personel kartı sonradan değişse de korunur).
  final String employeeName;
  final String roleTitle;
  final String? startDate;
  final String? endDate;
  final String notes;
  final bool isActive;

  factory ProjectTeamMember.fromJson(Map<String, dynamic> json) => ProjectTeamMember(
        id: json['id'] as String,
        employeeId: json['employee_id'] as String? ?? '',
        employeeName: json['employee_name'] as String? ?? '',
        roleTitle: json['role_title'] as String? ?? '',
        startDate: json['start_date'] as String?,
        endDate: json['end_date'] as String?,
        notes: json['notes'] as String? ?? '',
        isActive: json['is_active'] as bool? ?? (json['end_date'] == null),
      );
}

/// Ekibe eklenebilecek personel (`GET /projects/{id}/assignees`) --
/// yalnızca seçicinin ihtiyaç duyduğu alanlar; uç ücret alanı hiç
/// döndürmez. Eskiden `GET /employees` (employees.read) kullanılıyordu;
/// Proje Yöneticisi/Saha rollerinde o izin olmadığı için "Ekibe Ekle"
/// onlara hiç gösterilemiyordu.
class EmployeeOption {
  const EmployeeOption({
    required this.id,
    required this.fullName,
    this.position = '',
    this.hasAccount = false,
    this.hasProjectAccess = true,
  });

  final String id;
  final String fullName;
  final String position;

  /// Aktif uygulama hesabı var mı.
  final bool hasAccount;

  /// O hesap bu projeyi görebiliyor mu (Sahip/Yönetici ya da Proje
  /// Erişimi'nde). Ekibe eklemek erişim VERMEZ.
  final bool hasProjectAccess;

  /// Hesabı var ama projeyi göremiyor: ekibe eklenebilir, görev atanamaz.
  bool get lacksProjectAccess => hasAccount && !hasProjectAccess;

  factory EmployeeOption.fromJson(Map<String, dynamic> json) => EmployeeOption(
        id: json['id'] as String,
        fullName: json['full_name'] as String? ?? '',
        position: json['position'] as String? ?? '',
        hasAccount: json['has_account'] as bool? ?? false,
        // Alan yoksa (eski sunucu) erişim bilinmiyor: uyarma, engelleme.
        hasProjectAccess: json['has_project_access'] as bool? ?? true,
      );

  /// Web seçicisiyle aynı: "Ad — Pozisyon".
  String get label => position.isEmpty ? fullName : '$fullName — $position';
}

/// `POST /projects/{id}/members` gövdesi (backend `assignMemberRequest`).
class TeamMemberInput {
  const TeamMemberInput({required this.employeeId, this.roleTitle = '', this.startDate, this.notes = ''});

  final String employeeId;
  final String roleTitle;

  /// "YYYY-MM-DD" ya da null.
  final String? startDate;
  final String notes;

  Map<String, dynamic> toJson() => {
        'employee_id': employeeId,
        'role_title': roleTitle,
        'start_date': startDate,
        'notes': notes,
      };
}
