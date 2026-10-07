import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_data_row.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/app_section_header.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/quick_action_button.dart';
import '../../../core/widgets/status_badge.dart';
import '../../access/access_paths.dart';
import '../../access/data/access_providers.dart';
import '../../access/presentation/users_screen.dart';
import '../../access/presentation/widgets/access_state_views.dart';
import '../../access/presentation/widgets/user_access_card.dart';
import '../../auth/domain/user.dart';
import '../data/employees_providers.dart';
import '../domain/employee_record.dart';
import '../employees_paths.dart';
import 'employees_screen.dart' show kEmployeesNoAccessText;

/// `uyari` sorgu değerleri -- kayıt tamamlanıp yalnızca kişiye özel
/// yetkiler yazılamadığında detay sayfası bunu açıkça söyler.
const kEmployeeWarningPermissions = 'yetki';
const kEmployeeWarningLoginPermissions = 'giris-yetki';

/// Personel detayı -- web `/admin/personel/[id]`: bilgiler (ücretler yalnızca
/// employees.manage), pasifleştirme, bağlı giriş hesabı ve o hesabın rol +
/// kişiye özel yetkileri; hesabı yoksa "Giriş hesabı aç".
class EmployeeDetailScreen extends ConsumerStatefulWidget {
  const EmployeeDetailScreen({super.key, required this.employeeId, this.warning});

  final String employeeId;
  final String? warning;

  @override
  ConsumerState<EmployeeDetailScreen> createState() => _EmployeeDetailScreenState();
}

class _EmployeeDetailScreenState extends ConsumerState<EmployeeDetailScreen> {
  late String? _warning = widget.warning;
  bool _archiving = false;

  Future<void> _refresh(EmployeeRecord? e) {
    final userId = e?.userId;
    return refreshAndWait(ref, [
      employeeDetailProvider(widget.employeeId),
      if (userId != null) orgUserDetailProvider(userId),
      if (userId != null) userAccessBundleProvider(userId),
    ], () => ref.read(employeeDetailProvider(widget.employeeId).future));
  }

  Future<void> _archive(EmployeeRecord e) async {
    final ok = await confirmAccessAction(
      context,
      title: 'Personeli Pasifleştir',
      message:
          '${e.fullName} pasifleştirilsin mi? Mesai ve görev geçmişi korunur; istersen sonra düzenleme '
          'ekranından yeniden aktifleştirebilirsin.',
      confirmLabel: 'Pasifleştir',
      danger: true,
    );
    if (!ok || !mounted) return;
    setState(() => _archiving = true);
    // Kayıt sürerken ekran kapanabilir: tazeleme yine yapılsın.
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      await container.read(employeesRepositoryProvider).archive(e.id);
      invalidateEmployeesWith(container.invalidate, id: e.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${e.fullName} pasifleştirildi.')));
      }
    } on ApiException catch (err) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err.message)));
    } finally {
      if (mounted) setState(() => _archiving = false);
    }
  }

  Future<void> _openCreateLogin(EmployeeRecord e) async {
    final result = await context.push<String>(EmployeesPaths.createLogin(e.id));
    if (!mounted) return;
    if (result == kEmployeeWarningLoginPermissions) setState(() => _warning = result);
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(authControllerProvider).valueOrNull;
    if (!me.canAccess('employees.read')) {
      return const AppPageScaffold(
        title: Text('Personel'),
        body: NoAccessView(message: kEmployeesNoAccessText),
      );
    }
    final canManage = me.canAccess('employees.manage');
    final employeeAsync = ref.watch(employeeDetailProvider(widget.employeeId));
    final employee = employeeAsync.valueOrNull;

    return AppPageScaffold(
      title: Text(employee?.fullName ?? 'Personel'),
      actions: [
        if (canManage && employee != null)
          IconButton(
            tooltip: 'Düzenle',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => context.push(EmployeesPaths.edit(employee.id)),
          ),
      ],
      body: RefreshIndicator(
        onRefresh: () => _refresh(employee),
        child: GuardedAsyncView<EmployeeRecord>(
          value: employeeAsync,
          onRetry: () => _refresh(employee),
          data: (context, e) => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
            children: [
              if (_warning != null) ...[
                InfoNote(
                  _warning == kEmployeeWarningLoginPermissions
                      ? 'Giriş hesabı oluşturuldu ve bağlandı, ama kişiye özel yetkiler kaydedilemedi. '
                            'Yetkileri aşağıdan tekrar kaydedebilirsin.'
                      : 'Personel kaydedildi ama kişiye özel yetkiler kaydedilemedi. Aşağıdan tekrar kaydedebilirsin.',
                  tone: NoteTone.danger,
                ),
                const SizedBox(height: AppSpacing.md),
              ],
              _EmployeeHeader(employee: e),
              if (!canManage) ...[
                const SizedBox(height: AppSpacing.md),
                const ReadOnlyNotice(
                  'Bu kaydı yalnızca görüntüleyebilirsin; düzenlemek için rolünde "Personeli düzenleme" izni olmalı.',
                ),
              ],
              if (e.phone.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.md),
                Wrap(
                  spacing: AppSpacing.sm,
                  children: [
                    QuickActionButton(
                      icon: Icons.call_outlined,
                      label: 'Ara',
                      onPressed: () => launchUrl(Uri(scheme: 'tel', path: e.phone)),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: AppSpacing.xl),
              const AppSectionHeader(title: 'Personel Bilgileri'),
              const SizedBox(height: AppSpacing.sm),
              _EmployeeInfoCard(employee: e, showWages: canManage),
              const SizedBox(height: AppSpacing.xl),
              const AppSectionHeader(title: 'Sisteme Giriş ve Yetkiler'),
              const SizedBox(height: AppSpacing.sm),
              _LoginSection(employee: e, me: me, onCreateLogin: () => _openCreateLogin(e)),
              // Yıkıcı işlem etiketli ve kırmızı, sayfanın sonunda (Tedarikçi /
              // Maliyet Kodu "Arşivle" ile aynı yerleşim) -- simgeli bir üst
              // çubuk düğmesi Düzenle'ye karıştırılıyordu.
              if (canManage && e.isActive) ...[
                const SizedBox(height: AppSpacing.xl),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
                  onPressed: _archiving ? null : () => _archive(e),
                  icon: _archiving
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.person_off_outlined, size: 18),
                  label: const Text('Pasifleştir'),
                ),
                const SizedBox(height: AppSpacing.xs),
                const Text(
                  'Pasif personel mesai ve görev atamalarında listelenmez; geçmiş kayıtları korunur.',
                  style: AppTypography.helper,
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _EmployeeHeader extends StatelessWidget {
  const _EmployeeHeader({required this.employee});

  final EmployeeRecord employee;

  @override
  Widget build(BuildContext context) {
    final e = employee;
    return Row(
      children: [
        InitialsAvatar(name: e.fullName, size: 52, muted: !e.isActive),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(e.fullName, style: AppTypography.pageTitle, maxLines: 2, overflow: TextOverflow.ellipsis),
              if (e.position.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(e.position, style: AppTypography.metadata),
              ],
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: [
                  StatusRegistry.build(e.isActive ? 'aktif' : 'pasif', StatusRegistry.customer),
                  if (e.hasLogin)
                    e.loginDisabled
                        ? const StatusBadge(label: 'Giriş hesabı kapalı', tone: StatusTone.warning)
                        : StatusBadge(
                            label: e.userUsername == null ? 'Giriş hesabı var' : 'Hesap: ${e.userUsername}',
                            tone: StatusTone.info,
                          ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EmployeeInfoCard extends StatelessWidget {
  const _EmployeeInfoCard({required this.employee, required this.showWages});

  final EmployeeRecord employee;

  /// employees.manage -- aksi halde ücret satırları HİÇ çizilmez.
  final bool showWages;

  @override
  Widget build(BuildContext context) {
    final e = employee;
    String orDash(String v) => v.isEmpty ? '—' : v;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppDataRow(label: 'Telefon', value: orDash(e.phone)),
          AppDataRow(label: 'Görev', value: orDash(e.position)),
          AppDataRow(label: 'İşe Başlama', value: e.startDate == null ? '—' : Formatters.date(e.startDate)),
          if (showWages) ...[
            AppDataRow(label: 'Günlük Yevmiye', value: e.dailyWage == null ? '—' : Formatters.money(e.dailyWage!)),
            AppDataRow(label: 'Aylık Maaş', value: e.salary == null ? '—' : Formatters.money(e.salary!)),
          ],
          if (e.description.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            const Text('Açıklama', style: AppTypography.metadata),
            const SizedBox(height: 2),
            Text(e.description, style: AppTypography.body),
          ],
        ],
      ),
    );
  }
}

/// Bağlı giriş hesabı + rol/yetkiler ya da "Giriş hesabı aç". Ek veriler
/// yalnızca izin varsa çekilir: kişiye özel yetkiler "personeli görür ama
/// kullanıcıları/rolleri görmez" gibi kombinasyonlara izin verir ve bu
/// bölüm o durumda çökmek yerine açıklayıcı bir metin gösterir.
class _LoginSection extends ConsumerWidget {
  const _LoginSection({required this.employee, required this.me, required this.onCreateLogin});

  final EmployeeRecord employee;
  final User? me;
  final VoidCallback onCreateLogin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canReadUsers = me.canAccess('organization.users.read');
    final canReadAccess = me.canAccess('organization.roles.read');
    final canEditAccess = me.canAccess('organization.roles.manage');
    // Hesap açma ekranı rol listesini ve kataloğu da gösterir, personeli
    // günceller (bağlantı) ve hesabı açar -- dördü de gerekli.
    final canCreateLogin =
        canReadAccess && canEditAccess && me.canAccess('employees.manage') && me.canAccess('organization.users.manage');

    final userId = employee.userId;
    if (userId == null) {
      if (!canCreateLogin) {
        return const AppCard(child: Text('Bu personelin sisteme giriş hesabı yok.', style: AppTypography.metadata));
      }
      return AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Bu personelin sisteme giriş hesabı yok. Bir hesap açıp rolünü ve yetkilerini tek tek ayarlayabilirsin.',
              style: AppTypography.metadata,
            ),
            const SizedBox(height: AppSpacing.md),
            PrimaryButton(label: 'Giriş Hesabı Aç', icon: Icons.key_outlined, onPressed: onCreateLogin),
          ],
        ),
      );
    }

    final linkedUser = canReadUsers ? ref.watch(orgUserDetailProvider(userId)) : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (linkedUser != null)
          linkedUser.when(
            data: (u) => UserListTile(
              user: u,
              onTap: () => context.push(AccessPaths.user(u.id)),
              margin: const EdgeInsets.only(bottom: AppSpacing.md),
            ),
            loading: () => const Padding(
              padding: EdgeInsets.only(bottom: AppSpacing.md),
              child: AppCard(child: SizedBox(height: 36, child: LoadingState())),
            ),
            error: (e, _) => const Padding(
              padding: EdgeInsets.only(bottom: AppSpacing.md),
              child: InfoNote('Bağlı giriş hesabının bilgileri alınamadı.', tone: NoteTone.warning),
            ),
          ),
        if (canReadAccess)
          UserAccessCard(userId: userId, username: linkedUser?.valueOrNull?.username, canEdit: canEditAccess)
        else
          AppCard(
            child: Text(
              me?.role == UserRole.admin
                  ? 'Bu personelin giriş hesabı var; rol ve yetkilerini görmek için rolünde "Rolleri görüntüleme" '
                        'izni olmalı.'
                  : 'Bu personelin sisteme giriş hesabı var.',
              style: AppTypography.metadata.copyWith(color: AppColors.textMuted),
            ),
          ),
      ],
    );
  }
}
