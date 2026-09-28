import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_form_section.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/unsaved_changes_scope.dart';
import '../../access/data/access_providers.dart';
import '../../access/data/access_repository.dart';
import '../../access/domain/access_models.dart';
import '../../access/domain/permission_rules.dart';
import '../../access/presentation/widgets/access_state_views.dart';
import '../../access/presentation/widgets/permission_matrix.dart';
import '../data/employees_providers.dart';
import '../domain/employee_record.dart';
import '../employees_paths.dart';
import 'employee_detail_screen.dart' show kEmployeeWarningPermissions;

const kEmployeeManageNoAccessMessage =
    'Personel eklemek veya düzenlemek için rolünde "Personeli düzenleme" izni olmalı.';

/// Yeni personel / personeli düzenle -- web `NewEmployeeForm` +
/// `EditEmployeeForm`. Yalnızca employees.manage; ücret alanları da yalnızca
/// bu izinle görünür. Yeni personelde isteğe bağlı olarak giriş hesabı
/// (mevcut hesaba bağla / yeni hesap aç) + rol + kişiye özel yetkiler aynı
/// formda ayarlanır.
class EmployeeFormScreen extends ConsumerWidget {
  const EmployeeFormScreen({super.key, this.employeeId});

  final String? employeeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(authControllerProvider).valueOrNull;
    final title = Text(employeeId == null ? 'Yeni Personel' : 'Personeli Düzenle');
    if (!me.canAccess('employees.manage')) {
      return AppPageScaffold(
        title: title,
        body: const NoAccessView(message: kEmployeeManageNoAccessMessage),
      );
    }
    if (employeeId == null) {
      return AppPageScaffold(title: title, body: const _EmployeeFormBody());
    }
    final employeeAsync = ref.watch(employeeDetailProvider(employeeId!));
    return AppPageScaffold(
      title: title,
      body: GuardedAsyncView<EmployeeRecord>(
        value: employeeAsync,
        onRetry: () async => ref.invalidate(employeeDetailProvider(employeeId!)),
        data: (context, e) => _EmployeeFormBody(key: ValueKey(e.id), existing: e),
      ),
    );
  }
}

enum _LoginMode { none, existing, create }

class _EmployeeFormBody extends ConsumerStatefulWidget {
  const _EmployeeFormBody({super.key, this.existing});

  final EmployeeRecord? existing;

  @override
  ConsumerState<_EmployeeFormBody> createState() => _EmployeeFormBodyState();
}

class _EmployeeFormBodyState extends ConsumerState<_EmployeeFormBody> {
  final _formKey = GlobalKey<FormState>();
  late final _fullName = TextEditingController(text: widget.existing?.fullName ?? '');
  late final _phone = TextEditingController(text: widget.existing?.phone ?? '');
  late final _position = TextEditingController(text: widget.existing?.position ?? '');
  late final _dailyWage = TextEditingController(text: amountToInput(widget.existing?.dailyWage));
  late final _salary = TextEditingController(text: amountToInput(widget.existing?.salary));
  late final _description = TextEditingController(text: widget.existing?.description ?? '');
  late DateTime? _startDate = DateTime.tryParse(widget.existing?.startDate ?? '');

  // Düzenleme
  late bool _isActive = widget.existing?.isActive ?? true;
  late String _linkedUserId = widget.existing?.userId ?? '';

  // Yeni personel: giriş hesabı
  _LoginMode _mode = _LoginMode.none;
  String _existingUserId = '';
  String _savedRole = '';
  UserPermissionDetail? _existingDetail;
  bool _loadingAccess = false;

  /// Seçilen hesabın yetkileri alınamadı: matris GÖSTERİLMEZ, kayıtta
  /// yetkilere dokunulmaz (aksi halde görülmemiş kişiye özel ayarlar rol
  /// varsayılanlarıyla ezilirdi).
  String? _accessLoadError;
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;
  AccessState _access = const AccessState.empty();
  final List<OrgUser> _createdUsers = [];

  bool _submitting = false;
  String? _error;

  bool get _isEdit => widget.existing != null;

  @override
  void dispose() {
    for (final c in [_fullName, _phone, _position, _dailyWage, _salary, _description, _username, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  void _changeMode(_LoginMode next) => setState(() {
    _mode = next;
    _existingUserId = '';
    _savedRole = '';
    _existingDetail = null;
    _accessLoadError = null;
    _access = const AccessState.empty();
    _error = null;
  });

  Future<void> _selectExisting(String userId, {required bool canReadAccess}) async {
    setState(() {
      _existingUserId = userId;
      _access = const AccessState.empty();
      _savedRole = '';
      _existingDetail = null;
      _accessLoadError = null;
    });
    if (userId.isEmpty || !canReadAccess) return;
    setState(() => _loadingAccess = true);
    try {
      final detail = await ref.read(accessRepositoryProvider).getUserPermissions(userId);
      if (!mounted || _existingUserId != userId) return;
      setState(() {
        _access = AccessState(roleCode: detail.roleCode, selected: {...detail.permissions});
        _savedRole = detail.roleCode;
        _existingDetail = detail;
      });
    } on ApiException catch (e) {
      if (mounted && _existingUserId == userId) setState(() => _accessLoadError = e.message);
    } finally {
      if (mounted) setState(() => _loadingAccess = false);
    }
  }

  String? _amountValidator(String? v) {
    try {
      final value = parseAmountInput(v ?? '');
      if (value != null && value < 0) return 'Tutar negatif olamaz';
      if (value != null && value > kMaxEmployeeAmount) return 'Tutar en fazla 999.999.999.999,99 TL olabilir';
      return null;
    } on FormatException {
      return 'Geçerli bir tutar gir';
    }
  }

  EmployeeInput _input({required String userId}) => EmployeeInput(
    fullName: _fullName.text.trim(),
    phone: _phone.text.trim(),
    position: _position.text.trim(),
    dailyWage: parseAmountInput(_dailyWage.text),
    salary: parseAmountInput(_salary.text),
    startDate: _startDate == null ? null : isoDate(_startDate!),
    description: _description.text.trim(),
    isActive: _isActive,
    userId: userId,
  );

  Future<void> _submitEdit({required bool canLinkUsers}) async {
    if (!_formKey.currentState!.validate()) return;
    final existing = widget.existing!;
    setState(() {
      _submitting = true;
      _error = null;
    });
    // Kayıt sürerken ekran kapanabilir: tazeleme yine yapılsın.
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      // Kullanıcı listesini göremeyen biri bağlantıyı değiştiremez; mevcut
      // bağlantı AYNEN geri yazılır (backend tam-güncelleme yapar).
      await container
          .read(employeesRepositoryProvider)
          .update(existing.id, _input(userId: canLinkUsers ? _linkedUserId : (existing.userId ?? '')));
      invalidateEmployeesWith(container.invalidate, id: existing.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Kaydedildi.')));
      context.pop();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// Kaydetme sırası (web ile aynı): (yeni hesap) -> personel -> yetkiler.
  /// Personel kaydı hesaptan sonra başarısız olursa form "mevcut hesaba
  /// bağla"ya döner; tekrar denemek ikinci bir hesap oluşturmaz.
  Future<void> _submitCreate({required bool canEditAccess}) async {
    if (_mode == _LoginMode.create && _access.roleCode.isEmpty) {
      setState(() => _error = 'Giriş hesabı için bir rol seçin.');
      return;
    }
    if (_mode == _LoginMode.existing && _existingUserId.isEmpty) {
      setState(() => _error = 'Bağlanacak giriş hesabını seçin.');
      return;
    }
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    // Akış birkaç istekten oluşur (hesap -> personel -> yetkiler); arada
    // ekran kapanırsa `ref` kullanılamaz. Kapsayıcı ve repository'ler ilk
    // await'ten ÖNCE alınır; ayrıca kayıt sürerken sayfadan çıkılamaz.
    final container = ProviderScope.containerOf(context, listen: false);
    final accessRepo = container.read(accessRepositoryProvider);
    final employeesRepo = container.read(employeesRepositoryProvider);
    final wasCreate = _mode == _LoginMode.create;
    final access = _access;
    var userId = _mode == _LoginMode.existing ? _existingUserId : '';
    // Boş = hesabın mevcut rolü/yetkileri hiç okunamadı -> yetkilere dokunulmaz.
    var roleBaseline = _savedRole;

    if (wasCreate) {
      try {
        final created = await accessRepo.createUser(
          username: _username.text.trim(),
          password: _password.text,
          fullName: _fullName.text.trim(),
          organizationRoleCode: access.roleCode,
        );
        userId = created.id;
        roleBaseline = access.roleCode;
        container.invalidate(orgUsersProvider);
        if (mounted) {
          setState(() {
            _createdUsers.add(created);
            _mode = _LoginMode.existing;
            _existingUserId = created.id;
            _savedRole = access.roleCode;
          });
        }
      } on ApiException catch (e) {
        if (mounted) {
          setState(() {
            _error = e.message;
            _submitting = false;
          });
        }
        return;
      }
    }

    final EmployeeRecord employee;
    try {
      employee = await employeesRepo.create(_input(userId: userId));
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _error = wasCreate
              ? 'Giriş hesabı oluşturuldu ama personel kaydedilemedi: ${e.message}. Tekrar kaydedebilirsin; '
                    'hesap yeniden oluşturulmaz.'
              : e.message;
          _submitting = false;
        });
      }
      return;
    }
    invalidateEmployeesWith(container.invalidate);

    if (userId.isNotEmpty && canEditAccess && access.roleCode.isNotEmpty && roleBaseline.isNotEmpty) {
      try {
        await saveUserAccess(accessRepo, userId, roleBaseline, access);
      } on ApiException {
        if (mounted) {
          context.pushReplacement('${EmployeesPaths.detail(employee.id)}?uyari=$kEmployeeWarningPermissions');
        }
        return;
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${employee.fullName} eklendi.')));
    context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(authControllerProvider).valueOrNull;
    final canLinkUsers = me.canAccess('organization.users.read');
    final canReadAccess = me.canAccess('organization.roles.read');
    final canEditAccess = me.canAccess('organization.roles.manage');
    final canCreateLogin = canReadAccess && canEditAccess && me.canAccess('organization.users.manage');

    return UnsavedChangesScope(
      busy: _submitting,
      child: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
          children: [
            AppFormSection(
              title: 'Personel Bilgileri',
              children: [
                TextFormField(
                  controller: _fullName,
                  textCapitalization: TextCapitalization.words,
                  inputFormatters: [LengthLimitingTextInputFormatter(150)],
                  decoration: const InputDecoration(labelText: 'Ad Soyad *'),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Ad soyad zorunludur' : null,
                ),
                TextFormField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  inputFormatters: [LengthLimitingTextInputFormatter(40)],
                  decoration: const InputDecoration(labelText: 'Telefon'),
                ),
                TextFormField(
                  controller: _position,
                  inputFormatters: [LengthLimitingTextInputFormatter(100)],
                  decoration: const InputDecoration(labelText: 'Görev'),
                ),
                _DateField(
                  label: 'İşe Başlama Tarihi',
                  value: _startDate,
                  onChanged: (v) => setState(() => _startDate = v),
                ),
                TextFormField(
                  controller: _description,
                  decoration: const InputDecoration(labelText: 'Açıklama'),
                  maxLines: 2,
                ),
              ],
            ),
            // Ücretler yalnızca "Personeli düzenleme" ile görünür -- bu form
            // zaten o izne kapılı; "Personeli görüntüleme" maaşları açmamalı.
            AppFormSection(
              title: 'Ücret',
              subtitle: 'Yalnızca "Personeli düzenleme" izni olanlar görür.',
              children: [
                // Alt alta: 360 px'te yan yana "Günlük Yevmiye" etiketi kesiliyordu.
                _amountField(_dailyWage, 'Günlük Yevmiye'),
                _amountField(_salary, 'Aylık Maaş'),
              ],
            ),
            if (_isEdit)
              _buildEditAccountSection(canLinkUsers: canLinkUsers)
            else
              _buildLoginSection(
                canLinkUsers: canLinkUsers,
                canReadAccess: canReadAccess,
                canEditAccess: canEditAccess,
                canCreateLogin: canCreateLogin,
              ),
            if (_error != null) ...[Text(_error!, style: AppTypography.error), const SizedBox(height: AppSpacing.md)],
            PrimaryButton(
              label: _isEdit ? 'Kaydet' : 'Personel Ekle',
              loading: _submitting,
              onPressed: _loadingAccess
                  ? null
                  : _isEdit
                  ? () => _submitEdit(canLinkUsers: canLinkUsers)
                  : () => _submitCreate(canEditAccess: canEditAccess),
            ),
          ],
        ),
      ),
    );
  }

  Widget _amountField(TextEditingController controller, String label) => TextFormField(
    controller: controller,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
    decoration: InputDecoration(labelText: label, suffixText: 'TL'),
    validator: _amountValidator,
  );

  Widget _buildEditAccountSection({required bool canLinkUsers}) {
    final existing = widget.existing!;
    return AppFormSection(
      title: 'Durum ve Giriş Hesabı',
      children: [
        if (canLinkUsers)
          _linkedUserPicker()
        else
          Text(
            'Bağlı kullanıcı hesabı: ${existing.hasLogin ? 'var' : 'yok'} (değiştirmek için kullanıcıları görme '
            'izni gerekir).',
            style: AppTypography.helper,
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _isActive,
          onChanged: _submitting ? null : (v) => setState(() => _isActive = v),
          title: const Text('Aktif', style: AppTypography.body),
          subtitle: const Text('Pasif personel mesai ve görev atamalarında listelenmez.', style: AppTypography.helper),
        ),
      ],
    );
  }

  Widget _linkedUserPicker() {
    final usersAsync = ref.watch(orgUsersProvider);
    return usersAsync.when(
      loading: () => const SizedBox(height: 56, child: LoadingState()),
      error: (e, _) => InfoNote(
        'Kullanıcı listesi alınamadı; mevcut bağlantı korunur. (${e is ApiException ? e.message : 'bağlantı hatası'})',
        tone: NoteTone.warning,
      ),
      data: (users) {
        final known = users.any((u) => u.id == _linkedUserId);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _linkedUserId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Bağlı Kullanıcı Hesabı'),
              items: [
                const DropdownMenuItem(value: '', child: Text('— Bağlantı yok —')),
                if (_linkedUserId.isNotEmpty && !known)
                  DropdownMenuItem(value: _linkedUserId, child: const Text('Mevcut bağlı hesap')),
                for (final u in users)
                  DropdownMenuItem(
                    value: u.id,
                    child: Text('${u.fullName} (${u.username})', overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: _submitting ? null : (v) => setState(() => _linkedUserId = v ?? ''),
            ),
            const SizedBox(height: AppSpacing.xs),
            const Text(
              'Bu personeli bir giriş hesabına bağlarsan, o kullanıcı mobil uygulamada "Görevlerim" altında '
              'yalnızca kendisine atanan görevleri görür.',
              style: AppTypography.helper,
            ),
          ],
        );
      },
    );
  }

  Widget _buildLoginSection({
    required bool canLinkUsers,
    required bool canReadAccess,
    required bool canEditAccess,
    required bool canCreateLogin,
  }) {
    // Mevcut hesapta matris yalnızca hesabın GERÇEK rolü/yetkileri okunduysa
    // (ya da hesap bu formda açıldıysa) gösterilir.
    final showMatrix =
        _mode == _LoginMode.create ||
        (_mode == _LoginMode.existing &&
            _existingUserId.isNotEmpty &&
            canReadAccess &&
            !_loadingAccess &&
            _savedRole.isNotEmpty);
    return AppFormSection(
      title: 'Sisteme Giriş ve Yetkiler',
      children: [
        _ModeOption(
          label: 'Giriş hesabı yok',
          selected: _mode == _LoginMode.none,
          onTap: () => _changeMode(_LoginMode.none),
        ),
        if (canLinkUsers)
          _ModeOption(
            label: 'Mevcut hesaba bağla',
            selected: _mode == _LoginMode.existing,
            onTap: () => _changeMode(_LoginMode.existing),
          ),
        if (canCreateLogin)
          _ModeOption(
            label: 'Yeni giriş hesabı aç',
            selected: _mode == _LoginMode.create,
            onTap: () => _changeMode(_LoginMode.create),
          ),
        if (_mode == _LoginMode.none)
          const Text(
            'Bu personel yalnızca puantaj/maaş kaydı olarak tutulur, sisteme giriş yapamaz. İstersen sonradan '
            'personel ekranından hesap açabilirsin.',
            style: AppTypography.helper,
          ),
        if (_mode == _LoginMode.existing) _existingUserPicker(canReadAccess: canReadAccess),
        if (_mode == _LoginMode.create) ...[
          TextFormField(
            controller: _username,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'Kullanıcı Adı *'),
            validator: (v) =>
                _mode == _LoginMode.create && (v == null || v.trim().isEmpty) ? 'Kullanıcı adı zorunludur' : null,
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
            validator: (v) =>
                _mode == _LoginMode.create && (v == null || v.length < 8) ? 'Şifre en az 8 karakter olmalı' : null,
          ),
        ],
        if (_loadingAccess) const Text('Hesabın yetkileri yükleniyor…', style: AppTypography.helper),
        if (_mode == _LoginMode.existing && _accessLoadError != null && !_loadingAccess)
          InfoNote(
            'Hesabın rol ve yetkileri alınamadı ($_accessLoadError). Personel bu hesaba bağlanabilir; yetkiler '
            'değiştirilmez. Yetkileri görmek için tekrar dene.',
            tone: NoteTone.warning,
          ),
        if (_mode == _LoginMode.existing && _accessLoadError != null && !_loadingAccess)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _submitting ? null : () => _selectExisting(_existingUserId, canReadAccess: canReadAccess),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Tekrar Dene'),
            ),
          ),
        if (showMatrix) _matrix(canEditAccess: canEditAccess),
      ],
    );
  }

  Widget _existingUserPicker({required bool canReadAccess}) {
    final usersAsync = ref.watch(orgUsersProvider);
    return usersAsync.when(
      loading: () => const SizedBox(height: 56, child: LoadingState()),
      error: (e, _) => InfoNote(e is ApiException ? e.message : 'Kullanıcı listesi alınamadı.', tone: NoteTone.danger),
      data: (users) {
        final known = [...users, ..._createdUsers.where((c) => !users.any((u) => u.id == c.id))];
        return DropdownButtonFormField<String>(
          key: ValueKey('mevcut-$_existingUserId'),
          initialValue: _existingUserId.isEmpty ? null : _existingUserId,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Giriş Hesabı *'),
          hint: const Text('Hesap seçin'),
          items: [
            for (final u in known)
              DropdownMenuItem(
                value: u.id,
                child: Text('${u.fullName} (${u.username})', overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: _submitting ? null : (v) => _selectExisting(v ?? '', canReadAccess: canReadAccess),
        );
      },
    );
  }

  Widget _matrix({required bool canEditAccess}) {
    final rcAsync = ref.watch(roleCatalogProvider);
    return rcAsync.when(
      loading: () => const SizedBox(height: 72, child: LoadingState()),
      error: (e, _) => InfoNote(
        e is ApiException && e.isForbidden
            ? 'Rolleri görmek için yetkin yok; hesap rolsüz açılamaz.'
            : (e is ApiException ? e.message : 'Roller alınamadı.'),
        tone: NoteTone.danger,
      ),
      data: (rc) => PermissionMatrix(
        roles: _mode == _LoginMode.existing ? rolesWithCurrent(rc.roles, _existingDetail) : rc.roles,
        catalog: rc.catalog,
        value: _access,
        onChanged: (next) => setState(() {
          _access = next;
          _error = null;
        }),
        disabled: _submitting,
        readOnly: !canEditAccess,
      ),
    );
  }
}

class _ModeOption extends StatelessWidget {
  const _ModeOption({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      button: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.control),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 12),
          decoration: BoxDecoration(
            color: selected ? AppColors.gold.withValues(alpha: 0.08) : AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadius.control),
            border: Border.all(color: selected ? AppColors.gold : AppColors.border),
          ),
          child: Row(
            children: [
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                size: 20,
                color: selected ? AppColors.gold : AppColors.textMuted,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: Text(label, style: AppTypography.body)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tarih alanı -- diğer alanlarla aynı dekorasyon (bkz. TaskFormScreen
/// `_DueDateField` deseni).
class _DateField extends StatelessWidget {
  const _DateField({required this.label, required this.value, required this.onChanged});

  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.control),
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: value ?? DateTime.now(),
          firstDate: DateTime(1970),
          lastDate: DateTime(2100),
        );
        if (picked != null) onChanged(picked);
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: value != null
              ? IconButton(
                  tooltip: 'Tarihi temizle',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => onChanged(null),
                )
              : const Icon(Icons.calendar_today_outlined, size: 18),
        ),
        isEmpty: value == null,
        child: value == null ? null : Text(Formatters.date(isoDate(value!)), style: AppTypography.body),
      ),
    );
  }
}
