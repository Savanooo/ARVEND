/// Taşeron Paneli (backend migration 0075, docs/taseron-paneli.md).
///
/// Taşeron tarafı: `GET /portal/overview` -- taşeron yalnızca firmanın izin
/// verdiği projelerdeki kendi işlerini ve ödemelerini görür.
/// Firma tarafı: `GET /subcontractors/{id}/portal` -- kartın girişleri ve
/// proje izinleri.
library;

double _d(Object? v) => (v as num?)?.toDouble() ?? 0;

class PortalProject {
  const PortalProject({required this.id, required this.projectNo, required this.name, required this.status});

  final String id;
  final String projectNo;
  final String name;
  final String status;

  String get label => projectNo.isEmpty ? name : '$projectNo · $name';

  factory PortalProject.fromJson(Map<String, dynamic> j) => PortalProject(
        id: j['id'] as String,
        projectNo: j['project_no'] as String? ?? '',
        name: j['name'] as String? ?? '',
        status: j['status'] as String? ?? '',
      );
}

/// Taşeronun bir projedeki işi. [kind] "simple" (basit taşeron) ya da
/// "contract" (sözleşmeli taşeron); [certified] yalnızca sözleşmelide dolu.
class PortalEngagement {
  const PortalEngagement({
    required this.kind,
    required this.id,
    required this.projectId,
    required this.projectName,
    required this.projectNo,
    required this.title,
    required this.status,
    required this.currency,
    required this.contractAmount,
    this.certified,
    required this.paid,
    this.payable = 0,
    this.retention = 0,
    this.advanceOpen = 0,
    this.pendingClaims = 0,
    required this.remaining,
  });

  final String kind;
  final String id;
  final String projectId;
  final String projectName;
  final String projectNo;
  final String title;
  final String status;
  final String currency;
  final double contractAmount;
  final double? certified;
  final double paid;
  final double payable;
  final double retention;
  final double advanceOpen;
  final double pendingClaims;
  final double remaining;

  bool get isContract => kind == 'contract';
  String get projectLabel => projectNo.isEmpty ? projectName : '$projectNo · $projectName';

  factory PortalEngagement.fromJson(Map<String, dynamic> j) => PortalEngagement(
        kind: j['kind'] as String? ?? 'simple',
        id: j['id'] as String,
        projectId: j['project_id'] as String? ?? '',
        projectName: j['project_name'] as String? ?? '',
        projectNo: j['project_no'] as String? ?? '',
        title: j['title'] as String? ?? '',
        status: j['status'] as String? ?? '',
        currency: j['currency'] as String? ?? 'TRY',
        contractAmount: _d(j['contract_amount']),
        certified: (j['certified'] as num?)?.toDouble(),
        paid: _d(j['paid']),
        payable: _d(j['payable']),
        retention: _d(j['retention']),
        advanceOpen: _d(j['advance_open']),
        pendingClaims: _d(j['pending_claims']),
        remaining: _d(j['remaining']),
      );
}

/// Taşerona yapılmış (iptal edilmemiş) ödeme. [source] "direct" ise proje
/// dışıdır; [kind] "work" | "advance" | "general".
class PortalPayment {
  const PortalPayment({
    required this.source,
    required this.id,
    this.projectId,
    this.projectName = '',
    this.projectNo = '',
    required this.amount,
    required this.currency,
    required this.paidDate,
    this.description = '',
    this.kind = 'work',
  });

  final String source;
  final String id;
  final String? projectId;
  final String projectName;
  final String projectNo;
  final double amount;
  final String currency;

  /// "YYYY-MM-DD".
  final String paidDate;
  final String description;
  final String kind;

  bool get isAdvance => kind == 'advance';
  String get projectLabel =>
      source == 'direct' ? 'Proje dışı' : (projectNo.isEmpty ? projectName : '$projectNo · $projectName');

  factory PortalPayment.fromJson(Map<String, dynamic> j) => PortalPayment(
        source: j['source'] as String? ?? 'direct',
        id: j['id'] as String,
        projectId: j['project_id'] as String?,
        projectName: j['project_name'] as String? ?? '',
        projectNo: j['project_no'] as String? ?? '',
        amount: _d(j['amount']),
        currency: j['currency'] as String? ?? 'TRY',
        paidDate: j['paid_date'] as String? ?? '',
        description: j['description'] as String? ?? '',
        kind: j['kind'] as String? ?? 'work',
      );
}

/// Para birimi başına toplamlar: [remaining] işlerin kalanı (alacak),
/// [paid] ödeme listesinin toplamı (proje dışı dahil).
class PortalTotals {
  const PortalTotals({
    required this.currency,
    required this.contractAmount,
    required this.paid,
    required this.remaining,
    this.payable = 0,
    this.retention = 0,
  });

  final String currency;
  final double contractAmount;
  final double paid;
  final double remaining;
  final double payable;
  final double retention;

  factory PortalTotals.fromJson(Map<String, dynamic> j) => PortalTotals(
        currency: j['currency'] as String? ?? 'TRY',
        contractAmount: _d(j['contract_amount']),
        paid: _d(j['paid']),
        remaining: _d(j['remaining']),
        payable: _d(j['payable']),
        retention: _d(j['retention']),
      );
}

class PortalOverview {
  const PortalOverview({
    required this.supplierName,
    this.projects = const [],
    this.engagements = const [],
    this.payments = const [],
    this.totals = const [],
  });

  final String supplierName;
  final List<PortalProject> projects;
  final List<PortalEngagement> engagements;
  final List<PortalPayment> payments;
  final List<PortalTotals> totals;

  static List<T> _list<T>(Object? v, T Function(Map<String, dynamic>) f) =>
      (v as List? ?? const []).cast<Map<String, dynamic>>().map(f).toList();

  factory PortalOverview.fromJson(Map<String, dynamic> j) => PortalOverview(
        supplierName: (j['supplier'] as Map<String, dynamic>?)?['name'] as String? ?? '',
        projects: _list(j['projects'], PortalProject.fromJson),
        engagements: _list(j['engagements'], PortalEngagement.fromJson),
        payments: _list(j['payments'], PortalPayment.fromJson),
        totals: _list(j['totals'], PortalTotals.fromJson),
      );
}

// ---------- Firma tarafı: taşeron girişleri ve proje izinleri ----------

class PortalUser {
  const PortalUser({
    required this.id,
    required this.username,
    required this.fullName,
    required this.isActive,
    required this.mustChangePassword,
    this.lastLoginAt,
  });

  final String id;
  final String username;
  final String fullName;
  final bool isActive;

  /// Geçici şifreyle açıldı, taşeron henüz kendi şifresini belirlemedi.
  final bool mustChangePassword;
  final String? lastLoginAt;

  factory PortalUser.fromJson(Map<String, dynamic> j) => PortalUser(
        id: j['id'] as String,
        username: j['username'] as String? ?? '',
        fullName: j['full_name'] as String? ?? '',
        isActive: j['is_active'] as bool? ?? true,
        mustChangePassword: j['must_change_password'] as bool? ?? false,
        lastLoginAt: j['last_login_at'] as String?,
      );
}

class PortalProjectChoice {
  const PortalProjectChoice({
    required this.id,
    required this.projectNo,
    required this.name,
    required this.status,
    required this.granted,
    required this.hasEngagement,
  });

  final String id;
  final String projectNo;
  final String name;
  final String status;
  final bool granted;

  /// Taşeronun bu projede kayıtlı bir işi var (izin önerisi).
  final bool hasEngagement;

  String get label => projectNo.isEmpty ? name : '$projectNo · $name';

  factory PortalProjectChoice.fromJson(Map<String, dynamic> j) => PortalProjectChoice(
        id: j['id'] as String,
        projectNo: j['project_no'] as String? ?? '',
        name: j['name'] as String? ?? '',
        status: j['status'] as String? ?? '',
        granted: j['granted'] as bool? ?? false,
        hasEngagement: j['has_engagement'] as bool? ?? false,
      );
}

class PortalSettings {
  const PortalSettings({this.users = const [], this.projects = const []});

  final List<PortalUser> users;
  final List<PortalProjectChoice> projects;

  List<PortalProjectChoice> get granted => projects.where((p) => p.granted).toList();

  factory PortalSettings.fromJson(Map<String, dynamic> j) => PortalSettings(
        users: PortalOverview._list(j['users'], PortalUser.fromJson),
        projects: PortalOverview._list(j['projects'], PortalProjectChoice.fromJson),
      );
}
