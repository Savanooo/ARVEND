import 'package:flutter/material.dart';

import '../../../core/auth/permissions.dart';
import '../../auth/domain/user.dart';
import '../domain/project.dart';
import 'domain/ops_permissions.dart';
import 'ops_team_paths.dart';
import 'presentation/access_tab.dart';
import 'presentation/schedule_tab.dart';
import 'presentation/team_tab.dart';

/// Entegrasyon adımı için bölüm tanımı: hangi proje grubunda (`?grup=`),
/// hangi alt görünüm anahtarıyla (`?alt=`), hangi etiket/izinle görüneceği
/// ve gövde widget'ı. Proje detayı grubun `SegmentedButton`'ına bir segment
/// ekler, `builder`'ı `Expanded` içinde çizer (gövde kendi kaydırılabilir
/// listesini ve pull-to-refresh'ini taşır). Aynı gövde tam ekran olarak da
/// `location(projectId)` yolunda açılır (Özet kartı / derin bağlantı).
class OpsTeamSection {
  const OpsTeamSection({
    required this.group,
    required this.alt,
    required this.label,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.readPermission,
    required this.managePermission,
    required this.location,
    required this.builder,
  });

  /// Proje detayı grubu: `ozet|finans|operasyon|dokumanlar`.
  final String group;

  /// Grup içi alt görünüm anahtarı (`?alt=`).
  final String alt;

  /// Segment etiketi (kısa).
  final String label;

  /// Tam ekran / kart başlığı.
  final String title;

  /// Özet'teki gezinme kartı alt metni.
  final String subtitle;
  final IconData icon;

  /// Görünürlük (okuma) izni -- proje detayındaki `_failOpen` ile aynı
  /// anlamda `UserCan.can` ile değerlendirilir.
  final String readPermission;

  /// Yazma izni (bilgi amaçlı -- gövde kendisi denetler).
  final String managePermission;

  /// Tam ekran mutlak yolu.
  final String Function(String projectId) location;

  /// Proje detayındaki alt görünüm gövdesi.
  final Widget Function(String projectId, Project project) builder;

  bool visibleFor(User? user) => user.can(readPermission);
}

/// Operasyon grubuna eklenecek üç alt görünüm (web'de de "Operasyon"
/// sekmesindeler: Planlama, Personel / Ekip, Proje Erişimi). Sıra = web.
final List<OpsTeamSection> opsTeamSections = [
  OpsTeamSection(
    group: 'operasyon',
    alt: 'planlama',
    label: 'Planlama',
    title: 'Planlama',
    subtitle: 'İş programı, aşamalar ve gecikmeler',
    icon: Icons.view_timeline_outlined,
    readPermission: kProjectOpsReadPermission,
    managePermission: kProjectOpsManagePermission,
    location: schedulePath,
    builder: (projectId, project) =>
        ProjectScheduleTab(projectId: projectId, locked: isProjectLocked(project.status)),
  ),
  OpsTeamSection(
    group: 'operasyon',
    alt: 'ekip',
    label: 'Ekip',
    title: 'Proje Ekibi',
    subtitle: 'Projede çalışan personel ve görevleri',
    icon: Icons.groups_outlined,
    readPermission: kProjectOpsReadPermission,
    managePermission: kProjectOpsManagePermission,
    location: teamPath,
    builder: (projectId, project) => ProjectTeamTab(projectId: projectId, locked: isProjectLocked(project.status)),
  ),
  OpsTeamSection(
    group: 'operasyon',
    alt: 'erisim',
    label: 'Erişim',
    title: 'Proje Erişimi',
    subtitle: 'Projeyi görebilen kullanıcılar ve proje rolleri',
    icon: Icons.admin_panel_settings_outlined,
    readPermission: kProjectAccessReadPermission,
    managePermission: kProjectAccessManagePermission,
    location: accessPath,
    builder: (projectId, project) => ProjectAccessTab(projectId: projectId),
  ),
];
