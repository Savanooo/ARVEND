import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/api/api_providers.dart';
import '../../data/istanbul_day.dart';
import '../domain/ops_dates.dart';
import '../domain/project_access.dart';
import '../domain/schedule_item.dart';
import '../domain/team_member.dart';
import 'ops_team_repository.dart';

final opsTeamRepositoryProvider = Provider<OpsTeamRepository>((ref) => OpsTeamRepository(ref.watch(apiClientProvider)));

/// Proje planlama aşamaları (backend sırası).
final opsScheduleProvider = FutureProvider.autoDispose.family<List<ScheduleItem>, String>(
  (ref, projectId) => ref.watch(opsTeamRepositoryProvider).schedule(projectId),
);

/// Proje ekibi (aktif + geçmiş).
final opsTeamMembersProvider = FutureProvider.autoDispose.family<List<ProjectTeamMember>, String>(
  (ref, projectId) => ref.watch(opsTeamRepositoryProvider).members(projectId),
);

/// Ekibe eklenebilecek aktif personel (projenin `assignees` ucu) --
/// yalnızca "Ekibe Ekle" formu açıldığında izlenir.
final opsEmployeeOptionsProvider = FutureProvider.autoDispose.family<List<EmployeeOption>, String>(
  (ref, projectId) => ref.watch(opsTeamRepositoryProvider).activeEmployees(projectId),
);

/// Projeye açıkça erişimi olan kullanıcılar.
final opsAccessUsersProvider = FutureProvider.autoDispose.family<List<ProjectAccessUser>, String>(
  (ref, projectId) => ref.watch(opsTeamRepositoryProvider).accessUsers(projectId),
);

/// Erişim verilebilecek kullanıcılar -- yalnızca "Erişim Ver" formu
/// açıldığında izlenir (uç Yönetici rolü ister; diğerleri hiç çağırmaz).
final opsOrgUserOptionsProvider = FutureProvider.autoDispose<List<OrgUserOption>>(
  (ref) => ref.watch(opsTeamRepositoryProvider).orgUsers(),
);

/// Gecikme hesabının "bugün"ü (İstanbul günü). Gün değişince kendini
/// yeniler (bkz. [trackIstanbulDay]); eskiden süreç boyunca ilk okunduğu
/// günde donuyordu. Testler sabit bir günle override eder -- ekran
/// görüntüleri takvimden bağımsız kalsın.
final opsTodayProvider = Provider.autoDispose<DateTime>((ref) => trackIstanbulDay(ref, istanbulToday));
