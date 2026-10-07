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
import '../../employees/data/employees_providers.dart';
import '../../employees/domain/employee_record.dart';
import '../../employees/domain/person_name.dart';
import '../data/access_providers.dart';
import '../domain/access_models.dart';
import 'widgets/access_state_views.dart';

/// "Personel Kaydı" seçicisinde "yeni kayıt aç" seçeneğinin değeri
/// (diğer değerler personel kimlikleri).
const kNewEmployeeChoice = '';

/// Yeni kullanıcı (giriş hesabı) -- web `/admin/kullanicilar/yeni`.
/// Organizasyon rolü BİLİNÇLİ OLARAK boş başlar: en yetkili rol sessizce
/// varsayılan seçilirse forma dokunmadan kaydeden biri istemeden fazladan
/// bir Sahip oluşturabilir. Rol listesi okunur (roles.read), hesap açılır
/// (users.manage) -- biri eksikse form gösterilmez.
///
/// Kişi = tek kayıt: hesap açılırken kişi Personel'e de eklenir (varsayılan
/// açık) ya da mevcut bir personel kaydına bağlanır. Aynı adlı bağlantısız
/// personel varsa önceden seçili gelir -- sahada "batu" hesabı ile
/// "Batuhan İnci" personeli ayrı kalmış, görev bildirimi kimseye gitmemişti.
class UserFormScreen extends ConsumerStatefulWidget {
  const UserFormScreen({super.key});

  @override
  ConsumerState<UserFormScreen> createState() => _UserFormScreenState();
}

class _UserFormScreenState extends ConsumerState<UserFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _fullNameController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  String? _roleCode;
  bool _obscure = true;
  bool _submitting = false;
  String? _error;

  // Personel kaydı
  bool _createEmployee = true;

  /// Yöneticinin seçimi: null = dokunulmadı (ada göre varsayılan),
  /// [kNewEmployeeChoice] = yeni kayıt, diğerleri = bağlanacak personel.
  String? _employeeChoice;

  @override
  void initState() {
    super.initState();
    // Ad değişince aynı adlı personel eşleşmesi yeniden hesaplanır.
    _fullNameController.addListener(_onNameChanged);
  }

  void _onNameChanged() => setState(() {});

  @override
  void dispose() {
    _fullNameController.removeListener(_onNameChanged);
    _fullNameController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit({required _PersonnelChoice personnel}) async {
    // Rol dahil tüm eksikler aynı anda, alanlarının altında gösterilir.
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    // Kayıt sürerken ekran kapanabilir: liste yine tazelensin.
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      final created = await container
          .read(accessRepositoryProvider)
          .createUser(
            username: _usernameController.text.trim(),
            password: _passwordController.text,
            fullName: _fullNameController.text.trim(),
            organizationRoleCode: _roleCode!,
            createEmployee: personnel.createEmployee,
            employeeId: personnel.employeeId,
            linkSameName: personnel.linkSameName,
          );
      container.invalidate(orgUsersProvider);
      // Personel kaydı açıldı/bağlandı: personel listeleri ve seçiciler.
      invalidateEmployeesWith(container.invalidate, id: created.employeeLink?.employeeId);
      if (!mounted) return;
      final note = created.employeeLink?.message ?? '';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(note.isEmpty ? 'Kullanıcı oluşturuldu.' : 'Kullanıcı oluşturuldu. $note')));
      context.pop();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(authControllerProvider).valueOrNull;
    if (!me.canAccess('organization.users.manage') || !me.canAccess('organization.roles.read')) {
      return const AppPageScaffold(
        title: Text('Yeni Kullanıcı'),
        body: NoAccessView(
          message:
              'Kullanıcı eklemek için rolünde "Kullanıcıları düzenleme" ve "Rolleri görüntüleme" '
              'izinleri olmalı (yalnızca Sahip/Yönetici).',
        ),
      );
    }
    final rolesAsync = ref.watch(organizationRolesProvider);
    return AppPageScaffold(
      title: const Text('Yeni Kullanıcı'),
      body: GuardedAsyncView<List<OrganizationRole>>(
        value: rolesAsync,
        onRetry: () async => ref.invalidate(organizationRolesProvider),
        data: (context, roles) => UnsavedChangesScope(busy: _submitting, child: _form(roles)),
      ),
    );
  }

  Widget _form(List<OrganizationRole> roles) {
    final me = ref.watch(authControllerProvider).valueOrNull;
    // Personel kaydı açmak/bağlamak "Personeli düzenleme" ister (backend
    // izin yoksa adımı atlar); listeyi okumak "Personeli görüntüleme".
    final canManageEmployees = me.canAccess('employees.manage');
    final canListEmployees = canManageEmployees && me.canAccess('employees.read');
    final employeesAsync = canListEmployees && _createEmployee ? ref.watch(employeesListProvider('aktif')) : null;
    final personnel = _personnelChoice(
      canManage: canManageEmployees,
      unlinked: employeesAsync?.valueOrNull?.where((e) => !e.hasLogin).toList(),
    );

    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          AppFormSection(
            title: 'Hesap Bilgileri',
            children: [
              TextFormField(
                controller: _fullNameController,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Ad Soyad *'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Ad soyad zorunludur' : null,
              ),
              TextFormField(
                controller: _usernameController,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: 'Kullanıcı Adı *'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Kullanıcı adı zorunludur' : null,
              ),
              TextFormField(
                controller: _passwordController,
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
          ),
          AppFormSection(
            title: 'Organizasyon Rolü',
            children: [
              DropdownButtonFormField<String>(
                initialValue: _roleCode,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Rol *'),
                hint: const Text('Rol seçin'),
                validator: (v) => v == null ? 'Rol seçmelisin' : null,
                items: [
                  for (final r in roles)
                    DropdownMenuItem(
                      value: r.code,
                      child: Text(r.name, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) => setState(() {
                  _roleCode = v;
                  _error = null;
                }),
              ),
              const Text(
                'Sahip/Yönetici tüm projeleri koşulsuz görür. Proje Yöneticisi/Finans/Saha yalnızca atandıkları '
                'projelere erişir. Kişiye özel yetkileri hesap açıldıktan sonra kullanıcının sayfasından '
                'ayarlayabilirsin.',
                style: AppTypography.helper,
              ),
            ],
          ),
          if (canManageEmployees) _personnelSection(employeesAsync, personnel),
          if (_error != null) ...[Text(_error!, style: AppTypography.error), const SizedBox(height: AppSpacing.md)],
          // Düğme hep etkin: eksikler (rol dahil) basınca alanların
          // altında söylenir -- sebepsiz pasif düğme yanlış sinyal veriyordu.
          PrimaryButton(
            label: 'Kullanıcı Oluştur',
            icon: Icons.person_add_alt_1_outlined,
            loading: _submitting,
            onPressed: () => _submit(personnel: personnel),
          ),
        ],
      ),
    );
  }

  /// Formun personel kararı -> `POST /users` alanları. [unlinked] null =
  /// liste bilinmiyor (yükleniyor/hata/izin yok): seçim yapılamaz, backend
  /// varsayılanı uygular (yeni kayıt ya da aynı adlı tek kayda bağla).
  _PersonnelChoice _personnelChoice({required bool canManage, required List<EmployeeRecord>? unlinked}) {
    if (!canManage) return const _PersonnelChoice();
    if (!_createEmployee) return const _PersonnelChoice(createEmployee: false);
    if (unlinked == null) return const _PersonnelChoice();
    final name = _fullNameController.text;
    final matches = [
      for (final e in unlinked)
        if (samePersonName(e.fullName, name)) e,
    ];
    final ids = {for (final e in unlinked) e.id};
    var choice = _employeeChoice;
    // Seçilen kayıt artık listede değilse (başkası bağladı) seçim düşer.
    if (choice != null && choice != kNewEmployeeChoice && !ids.contains(choice)) choice = null;
    // Dokunulmadıysa: aynı adlı TEK kayıt önceden seçili (sunucu
    // varsayılanıyla aynı); birden çoksa yönetici seçmeli; yoksa yeni.
    choice ??= switch (matches.length) {
      0 => kNewEmployeeChoice,
      1 => matches.first.id,
      _ => null,
    };
    return _PersonnelChoice(
      unlinked: unlinked,
      matches: matches,
      selected: choice,
      createEmployee: choice == kNewEmployeeChoice ? true : null,
      // Liste görüldü ve yönetici "yeni kayıt" dedi: sunucu aynı adlıya
      // kendiliğinden bağlamasın (aynı adı taşıyan başka bir kişi).
      linkSameName: choice == kNewEmployeeChoice ? false : null,
      employeeId: (choice == null || choice == kNewEmployeeChoice) ? null : choice,
    );
  }

  Widget _personnelSection(AsyncValue<List<EmployeeRecord>>? employeesAsync, _PersonnelChoice personnel) {
    final unlinked = personnel.unlinked;
    final matches = personnel.matches;
    // Aynı adlılar başta, sonra diğer bağlantısız personel (ada göre).
    final ordered = unlinked == null
        ? const <EmployeeRecord>[]
        : [
            ...matches,
            ...unlinked.where((e) => !matches.contains(e)).toList()..sort((a, b) => a.fullName.compareTo(b.fullName)),
          ];
    final selected = personnel.selected;
    String? helper;
    if (selected == kNewEmployeeChoice) {
      helper = matches.isEmpty
          ? 'Bugünün tarihiyle, ücretsiz bir personel kaydı açılır; ücreti Personel ekranından girebilirsin.'
          : 'Aynı adlı personel kaydı var ama yeni kayıt açılacak -- yalnızca farklı bir kişiyse seç.';
    } else if (selected != null) {
      helper = matches.any((e) => e.id == selected)
          ? 'Aynı adlı personel kaydı var; hesap ona bağlanır, ikinci kayıt açılmaz.'
          : 'Hesap seçilen personel kaydına bağlanır.';
    }

    return AppFormSection(
      title: 'Personel Kaydı',
      children: [
        SwitchListTile(
          key: const ValueKey('personel-kaydi-anahtari'),
          contentPadding: EdgeInsets.zero,
          value: _createEmployee,
          onChanged: _submitting
              ? null
              : (v) => setState(() {
                  _createEmployee = v;
                  _error = null;
                }),
          title: const Text('Personel kaydı da oluştur', style: AppTypography.body),
          subtitle: const Text(
            'Kişi görev atanabilsin, mesai ve maaş listelerinde görünsün diye Personel\'e de eklenir.',
            style: AppTypography.helper,
          ),
        ),
        if (_createEmployee && employeesAsync != null)
          if (unlinked != null)
            DropdownButtonFormField<String>(
              key: ValueKey('personel-secimi-$selected'),
              initialValue: selected,
              isExpanded: true,
              decoration: InputDecoration(labelText: 'Personel kaydı', helperText: helper, helperMaxLines: 3),
              hint: const Text('Hangi kayıt?'),
              validator: (_) => personnel.selected == null
                  ? 'Aynı adlı birden çok personel var; hangisi olduğunu seç ya da yeni kayıt aç.'
                  : null,
              items: [
                const DropdownMenuItem(value: kNewEmployeeChoice, child: Text('Yeni personel kaydı oluştur')),
                for (final e in ordered)
                  DropdownMenuItem(
                    value: e.id,
                    child: Text(
                      'Bağla: ${[e.fullName, if (e.position.isNotEmpty) e.position].join(' · ')}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: _submitting
                  ? null
                  : (v) => setState(() {
                      _employeeChoice = v;
                      _error = null;
                    }),
            )
          else if (employeesAsync.hasError)
            const InfoNote(
              'Personel listesi alınamadı. Kayıt yine de açılır: aynı adlı tek bağlantısız personel varsa hesap '
              'ona bağlanır, yoksa yeni personel kaydı oluşturulur.',
              tone: NoteTone.warning,
            )
          else
            const LinearProgressIndicator(minHeight: 2),
        if (_createEmployee && employeesAsync == null)
          const Text(
            'Aynı adlı tek bağlantısız personel varsa hesap ona bağlanır; yoksa yeni personel kaydı oluşturulur.',
            style: AppTypography.helper,
          ),
        if (_createEmployee && matches.length == 1 && selected == matches.first.id)
          InfoNote('"${matches.first.fullName}" personel kaydı bu hesaba bağlanacak.', tone: NoteTone.success),
      ],
    );
  }
}

/// "Personel Kaydı" bölümünün kararı ve onun `POST /users` alanları
/// (null alan gönderilmez = backend varsayılanı).
class _PersonnelChoice {
  const _PersonnelChoice({
    this.unlinked,
    this.matches = const [],
    this.selected,
    this.createEmployee,
    this.employeeId,
    this.linkSameName,
  });

  final List<EmployeeRecord>? unlinked;
  final List<EmployeeRecord> matches;
  final String? selected;
  final bool? createEmployee;
  final String? employeeId;
  final bool? linkSameName;
}
