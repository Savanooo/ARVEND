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
import '../../ai_images/data/ai_images_providers.dart' show aiImagesAvailableProvider;
import '../../ai_images/domain/ai_studio.dart' show kAiStudioRoute, kAiStudioTitle;
import '../../attendance/domain/attendance_access.dart';
import '../../calc_admin/calc_admin_routes.dart';
import '../../chat/data/chat_providers.dart' show canUseChat;
import '../../chat/domain/chat_message.dart' show kChatRoute;
import '../../chat/presentation/chat_entry.dart';
import '../../onboarding/presentation/organization_settings_screen.dart' show kPermOrganizationSettingsRead;
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
      // Yapay Zekâ Stüdyo: en üstte (sahibin isteği: ayrı bir menü). KATI:
      // izin + sunucuda anahtar (aiImagesAvailableProvider) -- her görsel
      // firmaya para yazar, izni olmayan durumu hiç sormaz.
      if (ref.watch(aiImagesAvailableProvider))
        _MenuItem(
          icon: Icons.auto_awesome_outlined,
          label: kAiStudioTitle,
          onTap: () => context.push(kAiStudioRoute),
        ),
      // Firma Grubu (backend 0077): firmanın tek grup sohbeti -- en çok
      // açılacak araç, ilk sırada ve okunmamış sayısıyla. İzin KATI
      // denetlenir (canUseChat): izinsiz istek rozet için 403 üretirdi.
      if (canUseChat(user))
        _MenuItem(
          icon: Icons.forum_outlined,
          label: 'Firma Grubu',
          onTap: () => context.push(kChatRoute),
          badge: const ChatUnreadPill(),
        ),
      // Herkes masraf girer (backend 0066); genel (projesiz) ve projeli
      // masraflar tek yerde (backend 0068). Finans okuma izni olan herkesinkini,
      // olmayan kendi girdiklerini görür.
      // Onaylayıcı (masraf girme izni olmasa da) karar vereceği masrafları
      // burada görür (backend 0076: GET /expenses onaylayıcı kapsamı).
      if (canSee('projects.expenses.create') || canSee('projects.expenses.approve'))
        _MenuItem(
          icon: Icons.receipt_long_outlined,
          label: 'Masraflar',
          onTap: () => context.push('/diger/masraflar'),
        ),
      // Taşeronlar (backend 0069): firma geneli taşeron kartları ve ödemeleri.
      if (canSee('organization.suppliers.read'))
        _MenuItem(
          icon: Icons.engineering_outlined,
          label: 'Taşeronlar',
          onTap: () => context.push('/diger/taseronlar'),
        ),
      // Stok Takibi (backend 0072): depolar, malzemeler, giriş/çıkış, SKT.
      if (canSee('inventory.read'))
        _MenuItem(
          icon: Icons.warehouse_outlined,
          label: 'Stok Takibi',
          onTap: () => context.push('/diger/stok'),
        ),
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
      // Maaş izni (payroll.read) puantaj izninden ayrıdır: yalnızca maaş
      // verilmiş kişi (ör. muhasebe) de bu ekrana girer (eskiden menü
      // attendance.read istiyordu, maaşa hiçbir yerden ulaşılamıyordu).
      if (canOpenAttendanceScreen(user))
        _MenuItem(
          icon: Icons.access_time_outlined,
          label: attendanceEntryLabel(user),
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
    // Firma Ayarları backend'de requireAdmin + organization.settings.read
    // (kaydetmek .manage) arkasındadır (bkz. router.go settingsRoutes).
    // `canAccess` ikisini birden denetler: bu izin Yönetici'ye kilitlidir,
    // kaba rol admin de gerekir (bkz. kAdminRoleOnlyPermissions). Eskiden
    // yalnızca role bakılıyordu: görüntüleme izni alınmış Yönetici menüde
    // girişi görüp hata ekranına düşüyordu. Super Admin mobilde bu ekranı
    // kullanmaz (app_router.dart yönlendirmesi).
    final catalogItems = [
      for (final e in kCatalogMenuEntries)
        if (user.canAccess(e.permission)) fromEntry(e),
    ];
    final teamItems = [
      for (final e in kTeamMenuEntries)
        if (user.canAccess(e.permission)) fromEntry(e),
    ];
    final settingsItems = [
      if (user.canAccess(kPermOrganizationSettingsRead))
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
    this.badge,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// Ok işaretinin solunda (ör. Firma Grubu'nun okunmamış sayısı).
  final Widget? badge;
}

class _MenuTile extends StatelessWidget {
  const _MenuTile({required this.item});
  final _MenuItem item;

  @override
  Widget build(BuildContext context) {
    const chevron = Icon(Icons.chevron_right, color: AppColors.textMuted);
    return AppListCard(
      title: item.label,
      leading: Icon(item.icon, color: AppColors.gold),
      trailing: item.badge == null
          ? chevron
          : Row(mainAxisSize: MainAxisSize.min, children: [item.badge!, const SizedBox(width: AppSpacing.xs), chevron]),
      onTap: item.onTap,
    );
  }
}
