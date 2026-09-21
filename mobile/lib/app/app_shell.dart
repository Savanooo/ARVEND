import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/auth/auth_controller.dart';
import '../core/theme/app_colors.dart';

class _BranchTab {
  const _BranchTab(this.item, this.permission);
  final BottomNavigationBarItem item;
  // null = her zaman görünür (Ana Sayfa/Projeler/Diğer).
  final String? permission;
}

// StatefulShellRoute.indexedStack'teki branches sırasıyla BİREBİR eşleşir
// (bkz. app_router.dart) -- burada değişirse ORADA da değişmeli.
const _branchTabs = <_BranchTab>[
  _BranchTab(BottomNavigationBarItem(icon: Icon(Icons.home_outlined), activeIcon: Icon(Icons.home), label: 'Ana Sayfa'), null),
  _BranchTab(
    BottomNavigationBarItem(icon: Icon(Icons.business_outlined), activeIcon: Icon(Icons.business), label: 'Projeler'),
    null,
  ),
  _BranchTab(
    BottomNavigationBarItem(icon: Icon(Icons.description_outlined), activeIcon: Icon(Icons.description), label: 'Teklifler'),
    'offers.read',
  ),
  _BranchTab(
    BottomNavigationBarItem(icon: Icon(Icons.checklist_outlined), activeIcon: Icon(Icons.checklist), label: 'Görevler'),
    'projects.tasks.read',
  ),
  _BranchTab(BottomNavigationBarItem(icon: Icon(Icons.more_horiz), label: 'Diğer'), null),
];

/// Bottom navigation kabuğu: Ana Sayfa/Projeler/Teklifler/Görevler/Diğer.
/// Her sekme `StatefulShellBranch` sayesinde kendi navigation stack'ini
/// korur (bir sekmede detay sayfasına girip diğerine geçip geri dönünce
/// state kaybolmaz).
///
/// RBAC/Project Membership sprint'i: sekmeler kullanıcının izin kümesine
/// göre GİZLENİR (spec: "hide inaccessible nav items at UX level") --
/// owner/admin/legacy_user TÜM izinlere sahip olduğu için hiçbir sekme
/// onlar için gizlenmez. Görünen sekmelerin index'i, branches listesindeki
/// GERÇEK index'ten FARKLI olabileceği için goBranch çağrısı her zaman
/// orijinal (filtrelenmemiş) index'i kullanır.
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    // permissions boşsa (nadir, henüz yüklenmemiş/süper admin bu ekrana
    // hiç gelmez) TÜM sekmeler gösterilir -- backend zaten 403 üretir.
    final visible = user == null || user.permissions.isEmpty
        ? List.generate(_branchTabs.length, (i) => i)
        : [
            for (var i = 0; i < _branchTabs.length; i++)
              if (_branchTabs[i].permission == null || user.hasPermission(_branchTabs[i].permission!)) i,
          ];
    // Aktif dal gizlenmiş bir sekmeye denk geliyorsa (ör. izinler
    // sonradan daraltıldı) BottomNavigationBar'ın currentIndex'i listenin
    // dışına düşmesin diye ilk görünen sekmeye düşer.
    final currentVisibleIndex = visible.indexOf(navigationShell.currentIndex);
    final safeCurrentIndex = currentVisibleIndex >= 0 ? currentVisibleIndex : 0;

    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: BottomNavigationBar(
          currentIndex: safeCurrentIndex,
          onTap: (tappedVisibleIndex) {
            final branchIndex = visible[tappedVisibleIndex];
            navigationShell.goBranch(
              branchIndex,
              initialLocation: branchIndex == navigationShell.currentIndex,
            );
          },
          items: [for (final i in visible) _branchTabs[i].item],
        ),
      ),
    );
  }
}

/// Liste ekranlarının ortak AppBar'ı.
PreferredSizeWidget buildAppBar(String title, {List<Widget>? actions}) {
  return AppBar(title: Text(title), actions: actions);
}

const kScreenPadding = EdgeInsets.all(16);
const kSurfaceBorder = BorderSide(color: AppColors.border);
