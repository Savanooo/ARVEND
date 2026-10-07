import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_form_section.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/unsaved_changes_scope.dart';
import '../../access/data/access_providers.dart';
import '../../access/data/access_repository.dart';
import '../../access/domain/access_models.dart';
import '../../access/domain/permission_rules.dart';
import '../../access/presentation/widgets/access_state_views.dart';
import '../../access/presentation/widgets/permission_matrix.dart';
import '../data/employees_providers.dart';
import '../domain/employee_record.dart';
import 'employee_detail_screen.dart' show kEmployeeWarningLoginPermissions;

/// Giriş hesabı olmayan bir personele hesap açar -- web `CreateLoginCard`:
/// kullanıcı adı + şifre + rol + kişiye özel yetkiler tek formda. Sıra:
/// POST /users -> PUT /employees/{id} (user_id) -> rol/yetkiler. Hesap
/// açılıp bağlama başarısız olursa tekrar denemek hesabı YENİDEN açmaz,
/// yalnızca bağlar.
class EmployeeCreateLoginScreen extends ConsumerStatefulWidget {
  const EmployeeCreateLoginScreen({super.key, required this.employeeId});

  final String employeeId;

  @override
  ConsumerState<EmployeeCreateLoginScreen> createState() => _EmployeeCreateLoginScreenState();
}

class _EmployeeCreateLoginScreenState extends ConsumerState<EmployeeCreateLoginScreen> {
  /// Form bir kez gösterildiyse o kayıtla AÇIK kalır: kayıt sırasında
  /// tazelenen personel (artık `user_id` dolu) formu "zaten hesabı var"
  /// notuyla değiştirip sonucu (başarı / yetki uyarısı) kaybettirmesin.
  /// Sayfayı akış bitince form kendisi kapatır.
  EmployeeRecord? _formFor;

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(authControllerProvider).valueOrNull;
    // Hesap açma, personeli güncelleme (bağlantı), rol listesi + katalog ve
    // kişiye özel yetkiler -- dördü de gerekli (web `canCreateLogin`).
    final allowed =
        me.canAccess('employees.manage') &&
        me.canAccess('organization.users.manage') &&
        me.canAccess('organization.roles.read') &&
        me.canAccess('organization.roles.manage');
    if (!allowed) {
      return const AppPageScaffold(
        title: Text('Giriş Hesabı Aç'),
        body: NoAccessView(
          message:
              'Giriş hesabı açmak için rolünde "Personeli düzenleme", "Kullanıcıları düzenleme", '
              '"Rolleri görüntüleme" ve "Rolleri ve izinlerini düzenleme" izinleri olmalı (yalnızca Sahip/Yönetici).',
        ),
      );
    }
    final employeeAsync = ref.watch(employeeDetailProvider(widget.employeeId));
    final rcAsync = ref.watch(roleCatalogProvider);
    return AppPageScaffold(
      title: const Text('Giriş Hesabı Aç'),
      body: GuardedAsyncView<EmployeeRecord>(
        value: employeeAsync,
        keepDataWhileReloading: true,
        onRetry: () async => ref.invalidate(employeeDetailProvider(widget.employeeId)),
        data: (context, e) {
          if (_formFor == null && e.hasLogin) {
            return const FillScrollable(
              child: Padding(
                padding: EdgeInsets.all(AppSpacing.lg),
                child: InfoNote('Bu personelin zaten bir giriş hesabı var.'),
              ),
            );
          }
          final employee = _formFor ??= e;
          return GuardedAsyncView<RoleCatalog>(
            value: rcAsync,
            keepDataWhileReloading: true,
            onRetry: () async {
              ref.invalidate(organizationRolesProvider);
              ref.invalidate(permissionCatalogProvider);
            },
            data: (context, rc) => _CreateLoginForm(employee: employee, roles: rc.roles, catalog: rc.catalog),
          );
        },
      ),
    );
  }
}

class _CreateLoginForm extends ConsumerStatefulWidget {
  const _CreateLoginForm({required this.employee, required this.roles, required this.catalog});

  final EmployeeRecord employee;
  final List<OrganizationRole> roles;
  final List<PermissionDef> catalog;

  @override
  ConsumerState<_CreateLoginForm> createState() => _CreateLoginFormState();
}

class _CreateLoginFormState extends ConsumerState<_CreateLoginForm> {
  final _formKey = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;
  AccessState _access = const AccessState.empty();
  OrgUser? _created;
  String _createdRoleCode = '';
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _username.removeListener(_onTextChanged);
    _password.removeListener(_onTextChanged);
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _username.addListener(_onTextChanged);
    _password.addListener(_onTextChanged);
  }

  void _onTextChanged() => setState(() {});

  /// Yarım kalan iş: yazılmış bilgi, seçilmiş rol ya da açılmış ama henüz
  /// bağlanmamış hesap -- çıkarken onay sorulur.
  bool get _dirty =>
      _created != null || _username.text.isNotEmpty || _password.text.isNotEmpty || _access.roleCode.isNotEmpty;

  Future<void> _submit() async {
    // Eksiklerin hepsi aynı anda söylenir: alan hataları alanların altında,
    // rol eksikliği düğmenin üstünde.
    final fieldsOk = _created != null || _formKey.currentState!.validate();
    if (_access.roleCode.isEmpty) {
      setState(() => _error = 'Rol seçmelisin.');
      return;
    }
    if (!fieldsOk) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    // Akış birkaç istekten oluşur; arada ekran kapanırsa `ref` kullanılamaz.
    // Kapsayıcı ve repository'ler ilk await'ten ÖNCE alınır.
    final container = ProviderScope.containerOf(context, listen: false);
    final accessRepo = container.read(accessRepositoryProvider);
    final employeesRepo = container.read(employeesRepositoryProvider);
    final e = widget.employee;
    final access = _access;

    var created = _created;
    if (created == null) {
      try {
        // Hesap BU personele, hesapla aynı işlemde bağlanır (employee_id):
        // sunucu kendi kuralıyla yeni bir personel açmaz ya da aynı adlı
        // başka bir kayda bağlamaz.
        created = await accessRepo.createUser(
          username: _username.text.trim(),
          password: _password.text,
          fullName: e.fullName,
          organizationRoleCode: access.roleCode,
          employeeId: e.id,
        );
        _created = created;
        _createdRoleCode = access.roleCode;
        container.invalidate(orgUsersProvider);
      } on ApiException catch (err) {
        if (mounted) {
          setState(() {
            _error = err.message;
            _busy = false;
          });
        }
        return;
      }
    }

    try {
      // Sunucu bağı onayladıysa ikinci istek gerekmez. Onaylamadıysa (eski
      // sunucu) eski yol: kayıt employees.manage ile okundu -> ücretler dolu
      // gelir ve aynen geri yazılır (backend tam-güncelleme yapar).
      if (created.employeeId != e.id) {
        await employeesRepo.update(e.id, EmployeeInput.fromRecord(e, userId: created.id));
      }
    } on ApiException catch (err) {
      if (mounted) {
        setState(() {
          _error =
              '"${created!.username}" giriş hesabı oluşturuldu ama bu personele bağlanamadı (${err.message}). '
              'Tekrar denersen hesap yeniden oluşturulmaz, yalnızca bağlanır.';
          _busy = false;
        });
      }
      return;
    }

    String? result = 'ok';
    try {
      // Rol hesap açılırken zaten verildi (sonradan değiştiyse önce rol
      // güncellenir); ardından kişiye özel farklar yazılır.
      await saveUserAccess(accessRepo, created.id, _createdRoleCode, access);
    } on ApiException {
      result = kEmployeeWarningLoginPermissions;
    }
    // Personel listesi/detayı ANCAK şimdi tazelenir: yetkiler yazılmadan
    // tazelenseydi yeni kayıt (user_id dolu) bu formu yarıda söküp sonucu
    // ve olası yetki uyarısını kaybettirebilirdi.
    invalidateEmployeesWith(container.invalidate, id: e.id);
    if (!mounted) return;
    if (result == 'ok') {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('"${created.username}" giriş hesabı açıldı.')));
    }
    context.pop(result);
  }

  @override
  Widget build(BuildContext context) {
    return UnsavedChangesScope(dirty: _dirty, busy: _busy, child: _buildForm());
  }

  Widget _buildForm() {
    final created = _created;
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
        children: [
          Text(widget.employee.fullName, style: AppTypography.pageTitle),
          const SizedBox(height: AppSpacing.xs),
          const Text(
            'Bu personelin sisteme giriş hesabı yok. Aşağıdan bir hesap açıp rolünü ve yetkilerini tek tek '
            'ayarlayabilirsin.',
            style: AppTypography.metadata,
          ),
          const SizedBox(height: AppSpacing.xl),
          AppFormSection(
            title: 'Giriş Bilgileri',
            children: [
              if (created != null)
                InfoNote(
                  '"${created.username}" hesabı açıldı; kaydet ile bu personele bağlanacak.',
                  tone: NoteTone.warning,
                )
              else ...[
                TextFormField(
                  controller: _username,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: 'Kullanıcı Adı *'),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Kullanıcı adı zorunludur' : null,
                ),
                TextFormField(
                  controller: _password,
                  obscureText: _obscure,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'Şifre *',
                    helperText: 'En az 8 karakter.',
                    suffixIcon: IconButton(
                      tooltip: _obscure ? 'Şifreyi göster' : 'Şifreyi gizle',
                      icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                  validator: (v) => (v == null || v.length < 8) ? 'Şifre en az 8 karakter olmalı' : null,
                ),
              ],
            ],
          ),
          AppFormSection(
            title: 'Rol ve Yetkiler',
            children: [
              PermissionMatrix(
                roles: widget.roles,
                catalog: widget.catalog,
                value: _access,
                disabled: _busy,
                onChanged: (next) => setState(() {
                  _access = next;
                  _error = null;
                }),
              ),
            ],
          ),
          if (_error != null) ...[Text(_error!, style: AppTypography.error), const SizedBox(height: AppSpacing.md)],
          PrimaryButton(
            label: created == null ? 'Giriş Hesabı Oluştur' : 'Tekrar Dene',
            icon: Icons.key_outlined,
            loading: _busy,
            // Hep etkin: eksikler basınca söylenir (sebepsiz pasif düğme yok).
            onPressed: _submit,
          ),
        ],
      ),
    );
  }
}
