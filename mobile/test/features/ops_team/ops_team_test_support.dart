import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/core/theme/app_theme.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/projects/data/projects_providers.dart';
import 'package:arvend/features/projects/domain/project.dart';
import 'package:arvend/features/projects/ops_team/data/ops_team_providers.dart';
import 'package:arvend/features/projects/ops_team/data/ops_team_repository.dart';
import 'package:arvend/features/projects/ops_team/domain/project_access.dart';
import 'package:arvend/features/projects/ops_team/domain/schedule_item.dart';
import 'package:arvend/features/projects/ops_team/domain/team_member.dart';
import 'package:arvend/features/projects/ops_team/ops_team_routes.dart';
import 'package:arvend/features/projects/presentation/project_sub_view_bar.dart';

import '../suppliers/suppliers_test_support.dart' show FakeAuth, buildUser;

export '../suppliers/suppliers_test_support.dart' show goldenTheme, loadAppFonts, forbidden;

/// Planlama / Ekip / Erişim testlerinin ortak kurulumu: sahte depo (ağ
/// YOK), persona kullanıcıları, sabit "bugün" (2026-09-29, İstanbul) ve
/// gerçek rota ağacı (`opsTeamRoutes`, `/projeler/:id` altında).

const kProjectId = 'p1';
final kToday = DateTime.utc(2026, 9, 29);

const kOpsAll = {
  'projects.read',
  'projects.operations.read',
  'projects.operations.manage',
  'projects.access.read',
  'projects.access.manage',
};

/// Sahip: kaba rol admin + tüm proje izinleri + seçicilerin listeleri
/// (personel: employees.read, kullanıcılar: organization.users.read).
final opsOwnerUser = buildUser(
  id: 'owner',
  role: UserRole.admin,
  roleCode: 'owner',
  permissions: {...kOpsAll, 'employees.read', 'organization.users.read'},
);

/// Proje yöneticisi: operasyonları yönetir, erişimi yalnızca görür (web
/// rol matrisi: projects.access.manage yalnızca sahip/yönetici). Varsayılan
/// rolde employees.read YOK (migration 0034) -- ekipten çıkarabilir, ekibe
/// personel ekleyemez.
final opsManagerUser = buildUser(
  id: 'pm',
  roleCode: 'project_manager',
  permissions: {'projects.read', 'projects.operations.read', 'projects.operations.manage', 'projects.access.read'},
);

/// Salt-okunur: görür, değiştiremez.
final opsReadOnlyUser = buildUser(
  id: 'viewer',
  roleCode: 'custom',
  permissions: {'projects.read', 'projects.operations.read', 'projects.access.read'},
);

/// Finans benzeri: operasyon/erişim izni yok.
final opsNoAccessUser = buildUser(id: 'finance', roleCode: 'finance', permissions: {'projects.read', 'projects.finance.read'});

/// Özel izin kümesiyle kullanıcı.
User buildOpsUser(Set<String> permissions) => buildUser(id: 'custom', permissions: permissions);

const kScheduleFixtures = <ScheduleItem>[
  ScheduleItem(
    id: 's1',
    name: 'Mobilizasyon ve Şantiye Kurulumu',
    startDate: '2026-08-01',
    endDate: '2026-08-15',
    status: ScheduleStatus.completed,
    sortOrder: 0,
    taskCount: 4,
    completedTaskCount: 4,
  ),
  ScheduleItem(
    id: 's2',
    name: 'Hafriyat ve Temel',
    description: 'Kazı, grobeton ve radye temel',
    startDate: '2026-08-16',
    endDate: '2026-09-10',
    status: ScheduleStatus.completed,
    sortOrder: 1,
    taskCount: 6,
    completedTaskCount: 6,
  ),
  ScheduleItem(
    id: 's3',
    name: 'Kaba İnşaat',
    description: 'Betonarme karkas, döşemeler ve perde duvarlar',
    startDate: '2026-09-01',
    endDate: '2026-09-24',
    status: ScheduleStatus.active,
    sortOrder: 2,
    taskCount: 8,
    completedTaskCount: 3,
    assignedEmployeeId: 'e1',
    assignedName: 'Mehmet Usta',
  ),
  ScheduleItem(
    id: 's4',
    name: 'Çatı ve Yalıtım',
    startDate: '2026-10-01',
    endDate: '2026-10-20',
    status: ScheduleStatus.planned,
    sortOrder: 3,
  ),
  ScheduleItem(
    id: 's5',
    name: 'İnce İşler',
    description: 'Sıva, alçı, boya ve zemin kaplamaları',
    startDate: '2026-10-21',
    endDate: '2026-12-10',
    status: ScheduleStatus.planned,
    sortOrder: 4,
    taskCount: 2,
  ),
  ScheduleItem(id: 's6', name: 'Peyzaj', status: ScheduleStatus.cancelled, sortOrder: 5),
];

/// Görev/plan "kime" seçicisi (GET /projects/{id}/assignees).
const kAssigneeFixtures = <Assignee>[
  Assignee(id: 'e1', fullName: 'Mehmet Usta', position: 'Kalıpçı', hasAccount: true),
  Assignee(id: 'e2', fullName: 'Ali Kalfa', position: 'Demirci'),
];

const kMemberFixtures = <ProjectTeamMember>[
  ProjectTeamMember(
    id: 'm1',
    employeeId: 'e1',
    employeeName: 'Ahmet Yılmaz',
    roleTitle: 'Şantiye Şefi',
    startDate: '2026-08-01',
  ),
  ProjectTeamMember(id: 'm2', employeeId: 'e2', employeeName: 'Mehmet Kaya', roleTitle: 'Formen', startDate: '2026-08-10'),
  ProjectTeamMember(
    id: 'm3',
    employeeId: 'e3',
    employeeName: 'Ayşe Demir',
    roleTitle: 'İş Güvenliği Uzmanı',
    notes: 'Haftada iki gün sahada',
  ),
  ProjectTeamMember(id: 'm4', employeeId: 'e4', employeeName: 'Can Öztürk'),
  ProjectTeamMember(
    id: 'm5',
    employeeId: 'e5',
    employeeName: 'Hasan Çelik',
    roleTitle: 'Kalıpçı',
    startDate: '2026-08-16',
    endDate: '2026-09-15',
    isActive: false,
  ),
  ProjectTeamMember(
    id: 'm6',
    employeeId: 'e6',
    employeeName: 'Emre Şahin',
    roleTitle: 'Demirci',
    endDate: '2026-09-20',
    isActive: false,
  ),
];

const kEmployeeFixtures = <EmployeeOption>[
  EmployeeOption(id: 'e1', fullName: 'Ahmet Yılmaz', position: 'İnşaat Mühendisi'),
  EmployeeOption(id: 'e2', fullName: 'Mehmet Kaya', position: 'Formen'),
  EmployeeOption(id: 'e3', fullName: 'Ayşe Demir', position: 'İSG Uzmanı'),
  EmployeeOption(id: 'e4', fullName: 'Can Öztürk'),
  EmployeeOption(id: 'e5', fullName: 'Hasan Çelik', position: 'Kalıpçı'),
  EmployeeOption(id: 'e7', fullName: 'Zeynep Arslan', position: 'Mimar'),
  EmployeeOption(id: 'e8', fullName: 'Burak Koç', position: 'Elektrik Teknikeri'),
];

const kAccessFixtures = <ProjectAccessUser>[
  ProjectAccessUser(
    userId: 'u2',
    username: 'deniz.kara',
    fullName: 'Deniz Kara',
    projectRole: ProjectRole.viewer,
    organizationRoleCode: 'finance',
    organizationRoleName: 'Finans',
  ),
  ProjectAccessUser(
    userId: 'u3',
    username: 'murat.er',
    fullName: 'Murat Er',
    projectRole: ProjectRole.member,
    organizationRoleCode: 'field',
    organizationRoleName: 'Saha',
  ),
  ProjectAccessUser(
    userId: 'u4',
    username: 'okan.tekin',
    fullName: 'Okan Tekin',
    userIsActive: false,
    projectRole: ProjectRole.member,
    organizationRoleCode: 'field',
    organizationRoleName: 'Saha',
  ),
  ProjectAccessUser(
    userId: 'u1',
    username: 'selin.aydin',
    fullName: 'Selin Aydın',
    projectRole: ProjectRole.projectManager,
    organizationRoleCode: 'project_manager',
    organizationRoleName: 'Proje Yöneticisi',
  ),
];

const kOrgUserFixtures = <OrgUserOption>[
  OrgUserOption(id: 'u0', fullName: 'Taha Yetişözen', username: 'taha', organizationRoleCode: 'owner'),
  OrgUserOption(id: 'u1', fullName: 'Selin Aydın', username: 'selin.aydin', organizationRoleCode: 'project_manager'),
  OrgUserOption(id: 'u2', fullName: 'Deniz Kara', username: 'deniz.kara', organizationRoleCode: 'finance'),
  OrgUserOption(id: 'u3', fullName: 'Murat Er', username: 'murat.er', organizationRoleCode: 'field'),
  OrgUserOption(id: 'u5', fullName: 'Elif Şen', username: 'elif.sen', organizationRoleCode: 'field'),
  OrgUserOption(id: 'u6', fullName: 'Kerem Ak', username: 'kerem.ak', organizationRoleCode: 'finance'),
  OrgUserOption(id: 'u7', fullName: 'Gül Ay', username: 'gul.ay', organizationRoleCode: 'field', isActive: false),
];

ApiException conflictWith(String message) =>
    ApiException(statusCode: 409, message: message, kind: ApiErrorKind.conflict);

/// Bellek içi sahte depo: çağrıları kaydeder, istenirse hata fırlatır.
class FakeOpsTeamRepository implements OpsTeamRepository {
  FakeOpsTeamRepository({
    List<ScheduleItem> schedule = kScheduleFixtures,
    List<ProjectTeamMember> members = kMemberFixtures,
    List<EmployeeOption> employees = kEmployeeFixtures,
    List<ProjectAccessUser> access = kAccessFixtures,
    List<OrgUserOption> orgUsers = kOrgUserFixtures,
  })  : scheduleItems = [...schedule],
        memberItems = [...members],
        employeeItems = [...employees],
        accessItems = [...access],
        orgUserItems = [...orgUsers];

  final List<ScheduleItem> scheduleItems;
  final List<ProjectTeamMember> memberItems;
  final List<EmployeeOption> employeeItems;
  final List<ProjectAccessUser> accessItems;
  final List<OrgUserOption> orgUserItems;

  final List<String> calls = [];
  final List<ScheduleItemInput> createdSchedule = [];
  final List<(String, ScheduleItemInput)> updatedSchedule = [];
  final List<TeamMemberInput> addedMembers = [];
  final List<(String, String)> grants = [];
  final List<(String, String)> roleChanges = [];

  Object? scheduleError;
  Object? membersError;
  Object? employeesError;
  Object? accessError;
  Object? orgUsersError;
  Object? writeError;

  /// Verilirse yazma çağrıları bu tamamlanana kadar bekler.
  Completer<void>? writeGate;

  Future<void> _write(String call) async {
    calls.add(call);
    if (writeGate != null) await writeGate!.future;
    if (writeError != null) throw writeError!;
  }

  ScheduleItem _fromInput(String id, ScheduleItemInput input, {int taskCount = 0, int completed = 0}) => ScheduleItem(
        id: id,
        name: input.name,
        description: input.description,
        startDate: input.startDate,
        endDate: input.endDate,
        status: input.status,
        sortOrder: input.sortOrder,
        taskCount: taskCount,
        completedTaskCount: completed,
      );

  @override
  Future<List<ScheduleItem>> schedule(String projectId) async {
    calls.add('schedule:$projectId');
    if (scheduleError != null) throw scheduleError!;
    return [...scheduleItems];
  }

  @override
  Future<ScheduleItem> createScheduleItem(String projectId, ScheduleItemInput input) async {
    await _write('createSchedule:$projectId');
    createdSchedule.add(input);
    final item = _fromInput('new${scheduleItems.length + 1}', input);
    scheduleItems.add(item);
    return item;
  }

  @override
  Future<ScheduleItem> updateScheduleItem(String projectId, String itemId, ScheduleItemInput input) async {
    await _write('updateSchedule:$itemId');
    updatedSchedule.add((itemId, input));
    final i = scheduleItems.indexWhere((s) => s.id == itemId);
    final old = scheduleItems[i];
    final item = _fromInput(itemId, input, taskCount: old.taskCount, completed: old.completedTaskCount);
    scheduleItems[i] = item;
    return item;
  }

  @override
  Future<List<ProjectTeamMember>> members(String projectId) async {
    calls.add('members:$projectId');
    if (membersError != null) throw membersError!;
    return [...memberItems];
  }

  @override
  Future<ProjectTeamMember> addMember(String projectId, TeamMemberInput input) async {
    await _write('addMember:${input.employeeId}');
    addedMembers.add(input);
    final employee = employeeItems.firstWhere((e) => e.id == input.employeeId);
    final member = ProjectTeamMember(
      id: 'nm${memberItems.length + 1}',
      employeeId: input.employeeId,
      employeeName: employee.fullName,
      roleTitle: input.roleTitle,
      startDate: input.startDate,
      notes: input.notes,
    );
    final firstPast = memberItems.indexWhere((m) => !m.isActive);
    memberItems.insert(firstPast < 0 ? memberItems.length : firstPast, member);
    return member;
  }

  @override
  Future<ProjectTeamMember> endMembership(String projectId, String memberId) async {
    await _write('endMembership:$memberId');
    final i = memberItems.indexWhere((m) => m.id == memberId);
    final o = memberItems.removeAt(i);
    final ended = ProjectTeamMember(
      id: o.id,
      employeeId: o.employeeId,
      employeeName: o.employeeName,
      roleTitle: o.roleTitle,
      startDate: o.startDate,
      endDate: '2026-09-29',
      notes: o.notes,
      isActive: false,
    );
    memberItems.add(ended);
    return ended;
  }

  @override
  Future<List<EmployeeOption>> activeEmployees() async {
    calls.add('employees');
    if (employeesError != null) throw employeesError!;
    return [...employeeItems];
  }

  @override
  Future<List<ProjectAccessUser>> accessUsers(String projectId) async {
    calls.add('access:$projectId');
    if (accessError != null) throw accessError!;
    return [...accessItems];
  }

  @override
  Future<void> grantAccess(String projectId, {required String userId, required String projectRole}) async {
    await _write('grant:$userId');
    grants.add((userId, projectRole));
    final u = orgUserItems.firstWhere((o) => o.id == userId);
    accessItems.add(ProjectAccessUser(
      userId: u.id,
      username: u.username,
      fullName: u.fullName,
      projectRole: projectRole,
      organizationRoleCode: u.organizationRoleCode,
    ));
  }

  @override
  Future<void> changeAccessRole(String projectId, {required String userId, required String projectRole}) async {
    await _write('role:$userId');
    roleChanges.add((userId, projectRole));
    final i = accessItems.indexWhere((a) => a.userId == userId);
    final o = accessItems[i];
    accessItems[i] = ProjectAccessUser(
      userId: o.userId,
      username: o.username,
      fullName: o.fullName,
      userIsActive: o.userIsActive,
      projectRole: projectRole,
      organizationRoleCode: o.organizationRoleCode,
      organizationRoleName: o.organizationRoleName,
    );
  }

  @override
  Future<void> revokeAccess(String projectId, {required String userId}) async {
    await _write('revoke:$userId');
    accessItems.removeWhere((a) => a.userId == userId);
  }

  @override
  Future<List<OrgUserOption>> orgUsers() async {
    calls.add('orgUsers');
    if (orgUsersError != null) throw orgUsersError!;
    return [...orgUserItems];
  }
}

Project sampleOpsProject({String status = 'active'}) => Project.fromJson({
      'id': kProjectId,
      'project_no': 'PRJ-2026-0007',
      'name': 'Kadıköy Konut Projesi',
      'project_type': 'Konut',
      'customer_name': 'Moda Yapı A.Ş.',
      'contract_amount': 12500000,
      'currency': 'TRY',
      'status': status,
      'start_date': '2026-08-01',
      'end_date': '2027-03-31',
      'description': '',
      'created_at': '2026-07-20T08:00:00Z',
    });

/// Proje detayı yerine geçen sade ev sahibi: `?alt=` ile seçilen bölümü
/// (`opsTeamSections`) Operasyon grubunun gövdesi gibi çizer -- proje
/// detayının yerleşimiyle aynı (gerçek çip şeridi + Expanded gövde).
class OpsSectionHost extends ConsumerWidget {
  const OpsSectionHost({super.key, required this.projectId, this.alt});

  final String projectId;
  final String? alt;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectAsync = ref.watch(projectDetailProvider(projectId));
    final user = ref.watch(authControllerProvider).valueOrNull;
    final visible = opsTeamSections.where((s) => s.visibleFor(user)).toList();
    final selected = visible.where((s) => s.alt == alt).firstOrNull ?? visible.firstOrNull;
    return Scaffold(
      appBar: AppBar(title: const Text('Proje')),
      body: projectAsync.when(
        loading: () => const SizedBox.shrink(),
        error: (e, _) => Text('$e'),
        data: (project) => selected == null
            ? const Center(child: Text('Bölüm yok'))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Proje detayındaki gerçek alt görünüm çip şeridi.
                  ProjectSubViewBar(
                    items: [for (final s in visible) (alt: s.alt, label: s.label)],
                    selected: selected.alt,
                    onSelected: (alt) => context.go('/projeler/$projectId?alt=$alt'),
                  ),
                  Expanded(child: selected.builder(projectId, project)),
                ],
              ),
      ),
    );
  }
}

/// Gerçek uygulamadaki gibi: `/projeler/:id` altında `opsTeamRoutes`.
Widget buildOpsApp({
  required User user,
  required FakeOpsTeamRepository repo,
  required String initialLocation,
  String projectStatus = 'active',
  ThemeData? theme,
}) {
  final router = GoRouter(
    initialLocation: initialLocation,
    routes: [
      GoRoute(
        path: '/projeler',
        builder: (_, _) => const Scaffold(body: Center(child: Text('Projeler'))),
        routes: [
          GoRoute(
            path: ':id',
            builder: (_, state) => OpsSectionHost(
              projectId: state.pathParameters['id']!,
              alt: state.uri.queryParameters['alt'],
            ),
            routes: opsTeamRoutes,
          ),
        ],
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      authControllerProvider.overrideWith(() => FakeAuth(user)),
      opsTeamRepositoryProvider.overrideWithValue(repo),
      opsTodayProvider.overrideWithValue(kToday),
      projectDetailProvider.overrideWith((ref, id) async => sampleOpsProject(status: projectStatus)),
      projectAssigneesProvider.overrideWith((ref, id) async => kAssigneeFixtures),
    ],
    child: MaterialApp.router(
      debugShowCheckedModeBanner: false,
      theme: theme ?? AppTheme.light(),
      locale: const Locale('tr', 'TR'),
      supportedLocales: const [Locale('tr', 'TR')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      routerConfig: router,
    ),
  );
}
