import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_shell.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_list_card.dart';
import '../../../core/widgets/app_section_header.dart';
import '../../access/access_routes.dart';
import '../../auth/domain/user.dart';
import '../../calc_admin/calc_admin_routes.dart';
import '../../cost_codes/cost_codes_routes.dart';
import '../../employees/employees_routes.dart';
import '../../products/products_routes.dart';
import '../../settings/settings_routes.dart';
import '../../suppliers/suppliers_routes.dart';

/// Modüllerin `*_routes.dart` dosyalarındaki menü tanımlarının ortak tipi.
typedef MenuEntry = ({String label, IconData icon, String route, String permission});

/// "Yönetim" bölümünün izne bağlı öğeleri -- web `/admin/**` sayfalarının
/// mobil karşılıkları, iki alt başlık altında. Her öğe KATI `canAccess`
/// ile süzülür (fail-closed; Kullanıcılar ve Roller & Yetkiler ayrıca kaba
/// rol admin ister). Zam Geçmişi ve Fiyat Kaynakları Ürünler ekranından
/// açılır (web menüsüyle aynı), ayrı öğe değildir.
const List<MenuEntry> kCatalogMenuEntries = [
  ...productsMenuEntries, // Ürünler
  ...suppliersMenuEntries, // Tedarikçiler
  ...costCodesMenuEntries, // Maliyet Kodları
  ...calcAdminMenuEntries, // Metraj Reçeteleri
];

const List<MenuEntry> kTeamMenuEntries = [
  ...employeesMenuEntries, // Personel
  ...accessMenuEntries, // Kullanıcılar, Roller & Yetkiler
  // Firmadaki herkese zil + telefon bildirimi.
  (label: 'Duyuru Gönder', icon: Icons.campaign_outlined, route: '/diger/duyuru', permission: 'organization.users.manage'),
];

/// Katalog + Ekip, menüdeki sırasıyla.
const List<MenuEntry> kManagementMenuEntries = [...kCatalogMenuEntries, ...kTeamMenuEntries];

/// "Ayarlar" alt başlığının izne bağlı öğeleri (Firma Ayarları'ndan sonra;
/// Firma Ayarları bu listede DEĞİL, bkz. aşağıdaki yorum).
const List<MenuEntry> kManagementSettingsEntries = [...settingsMenuEntries];

class OtherMenuScreen extends ConsumerWidget {
  const OtherMenuScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    // RBAC/Project Membership sprint'i: permissions boşsa (nadir, henüz
    // yüklenmemiş) HİÇBİR öğe izin kontrolüyle gizlenmez -- backend zaten
    // 403 üretir, burada yalnızca UX'tir (spec: "hide inaccessible nav
    // items"). owner/admin/legacy_user TÜM izinlere sahip olduğu için bu
    // kontroller onlar için hiçbir zaman bir şey gizlemez.
    final noPermissionData = user == null || user.permissions.isEmpty;
    bool canSee(String code) => noPermissionData || user.hasPermission(code);

    final toolItems = [
      if (canSee('customers.read'))
        _MenuItem(
          icon: Icons.people_outline,
          label: 'Müşteriler',
          onTap: () => context.push('/diger/musteriler'),
        ),
      if (canSee('calculations.read'))
        _MenuItem(
          icon: Icons.straighten_outlined,
          label: 'Metraj Hesaplama',
          onTap: () => context.push('/diger/metraj'),
        ),
      if (canSee('attendance.read'))
        _MenuItem(
          icon: Icons.access_time_outlined,
          label: 'Mesai',
          onTap: () => context.push('/diger/mesai'),
        ),
    ];

    final accountItems = [
      _MenuItem(
        icon: Icons.person_outline,
        label: 'Profil',
        onTap: () => context.push('/diger/profil'),
      ),
      if (canSee('notifications.read'))
        _MenuItem(
          icon: Icons.notifications_outlined,
          label: 'Bildirimler',
          onTap: () => context.push('/diger/bildirimler'),
        ),
      _MenuItem(
        icon: Icons.lightbulb_outline,
        label: 'Öneri Gönder',
        onTap: () => context.push('/diger/oneri'),
      ),
      _MenuItem(
        icon: Icons.info_outline,
        label: 'Hakkında',
        onTap: () => context.push('/diger/hakkinda'),
      ),
    ];

    _MenuItem fromEntry(MenuEntry e) => _MenuItem(icon: e.icon, label: e.label, onTap: () => context.push(e.route));

    // Yönetim ekranları İş Araçları'nın aksine KATI `canAccess` ile
    // süzülür: izin kümesi boşsa/yüklenmemişse hiçbiri görünmez (web
    // lib/nav.ts ile aynı karar). Her ekran ayrıca kendi iznini denetler.
    //
    // Firma Ayarları backend'de requireAdmin arkasındadır (bkz. router.go:
    // /organization/settings/*) -- kullanici rolüne 403 ile sonuçlanacak
    // bir ekranı göstermemek için yalnızca admin'e gösterilir (Super Admin
    // mobilde bu ekranı kullanmaz, bkz. MOBILE_BACKEND_GAPS.md - platform
    // yönetimi web'e özeldir). BİLİNÇLİ OLARAK `user.role` (kaba platform/
    // kiracı ekseni) kontrol edilir, `hasPermission` (ince RBAC ekseni)
    // DEĞİL -- backend'in kendisi bu ucu requireAdmin ile korur, perm()
    // ile DEĞİL, bu yüzden mobil kontrol GERÇEK sunucu davranışını birebir
    // yansıtır. app_router.dart'taki super_admin yönlendirmesi sayesinde
    // super_admin zaten bu ekrana hiç gelmez -- ama `role == admin` yanlışça
    // `hasPermission(...)`'a "düzeltilmeye" çalışılırsa DİKKAT: bu ekranın
    // gerçek koruması RBAC izin kodu DEĞİL, kaba admin rolüdür.
    final catalogItems = [
      for (final e in kCatalogMenuEntries)
        if (user.canAccess(e.permission)) fromEntry(e),
    ];
    final teamItems = [
      for (final e in kTeamMenuEntries)
        if (user.canAccess(e.permission)) fromEntry(e),
    ];
    final settingsItems = [
      if (user?.role == UserRole.admin)
        _MenuItem(
          icon: Icons.apartment_outlined,
          label: 'Firma Ayarları',
          onTap: () => context.push('/diger/firma-ayarlari'),
        ),
      for (final e in kManagementSettingsEntries)
        if (user.canAccess(e.permission)) fromEntry(e),
    ];
    final managementGroups = [
      if (catalogItems.isNotEmpty) ('KATALOG', catalogItems),
      if (teamItems.isNotEmpty) ('EKİP', teamItems),
      if (settingsItems.isNotEmpty) ('AYARLAR', settingsItems),
    ];

    // Sıra: İş Araçları -> Yönetim -> Hesap (hesap öğeleri sonda; sahibin en
    // çok kullandığı yönetim girişleri kaydırmanın dibinde kalmasın).
    return Scaffold(
      appBar: buildAppBar('Diğer'),
      body: ListView(
        padding: kScreenPadding,
        children: [
          if (toolItems.isNotEmpty) ...[
            const AppSectionHeader(title: 'İş Araçları'),
            const SizedBox(height: AppSpacing.sm),
            for (final item in toolItems) _MenuTile(item: item),
            const SizedBox(height: AppSpacing.md),
          ],
          if (managementGroups.isNotEmpty) ...[
            const AppSectionHeader(title: 'Yönetim'),
            for (final (title, items) in managementGroups) ...[
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.sm),
                child: Text(title, style: AppTypography.overline),
              ),
              for (final item in items) _MenuTile(item: item),
            ],
            const SizedBox(height: AppSpacing.md),
          ],
          const AppSectionHeader(title: 'Hesap'),
          const SizedBox(height: AppSpacing.sm),
          for (final item in accountItems) _MenuTile(item: item),
        ],
      ),
    );
  }
}

class _MenuItem {
  const _MenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
}

class _MenuTile extends StatelessWidget {
  const _MenuTile({required this.item});
  final _MenuItem item;

  @override
  Widget build(BuildContext context) {
    return AppListCard(
      title: item.label,
      leading: Icon(item.icon, color: AppColors.gold),
      trailing: const Icon(Icons.chevron_right, color: AppColors.textMuted),
      onTap: item.onTap,
    );
  }
}
