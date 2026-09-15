import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/theme/app_colors.dart';

/// Bottom navigation kabuğu: Ana Sayfa/Projeler/Teklifler/Görevler/Diğer.
/// Her sekme `StatefulShellBranch` sayesinde kendi navigation stack'ini
/// korur (bir sekmede detay sayfasına girip diğerine geçip geri dönünce
/// state kaybolmaz).
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: navigationShell.currentIndex,
        onTap: (index) => navigationShell.goBranch(
          index,
          initialLocation: index == navigationShell.currentIndex,
        ),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home_outlined), activeIcon: Icon(Icons.home), label: 'Ana Sayfa'),
          BottomNavigationBarItem(
              icon: Icon(Icons.business_outlined), activeIcon: Icon(Icons.business), label: 'Projeler'),
          BottomNavigationBarItem(
              icon: Icon(Icons.description_outlined), activeIcon: Icon(Icons.description), label: 'Teklifler'),
          BottomNavigationBarItem(
              icon: Icon(Icons.checklist_outlined), activeIcon: Icon(Icons.checklist), label: 'Görevler'),
          BottomNavigationBarItem(icon: Icon(Icons.more_horiz), label: 'Diğer'),
        ],
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
