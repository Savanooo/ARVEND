import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/widgets/app_page_scaffold.dart';
import '../../data/projects_providers.dart';
import '../domain/ops_permissions.dart';
import 'access_tab.dart';
import 'schedule_tab.dart';
import 'team_tab.dart';

/// Proje detayının dışından (derin bağlantı, Özet kartı) açılan tam
/// ekranlar -- gövde, proje detayındaki alt görünümle AYNI widget'tır.
/// Kilit durumu (`completed`/`cancelled`) proje kaydından okunur; proje
/// yüklenene kadar yazma düğmeleri gösterilmez.

bool? _lockedOf(WidgetRef ref, String projectId) {
  final status = ref.watch(projectDetailProvider(projectId)).valueOrNull?.status;
  return status == null ? null : isProjectLocked(status);
}

/// `/projeler/:id/planlama`
class ProjectScheduleScreen extends ConsumerWidget {
  const ProjectScheduleScreen({super.key, required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AppPageScaffold(
      title: const Text('Planlama'),
      body: ProjectScheduleTab(projectId: projectId, locked: _lockedOf(ref, projectId)),
    );
  }
}

/// `/projeler/:id/ekip`
class ProjectTeamScreen extends ConsumerWidget {
  const ProjectTeamScreen({super.key, required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AppPageScaffold(
      title: const Text('Proje Ekibi'),
      body: ProjectTeamTab(projectId: projectId, locked: _lockedOf(ref, projectId)),
    );
  }
}

/// `/projeler/:id/erisim`
class ProjectAccessScreen extends StatelessWidget {
  const ProjectAccessScreen({super.key, required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context) {
    return AppPageScaffold(
      title: const Text('Proje Erişimi'),
      body: ProjectAccessTab(projectId: projectId),
    );
  }
}
