import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/dashboard/presentation/widgets/shortcuts_grid.dart';

/// Özet alınamadığında gösterilen kısayollar: "Mesai" yalnızca maaş izni
/// olan kişiye de görünür (payroll.* attendance.*'tan ayrı bir izin); o
/// kişide adı menüdeki ve ekrandaki gibi "Maaş"tır.

User _user(Set<String> permissions) => User(
      id: 'u1',
      username: 'u',
      fullName: 'U',
      role: UserRole.kullanici,
      isActive: true,
      mustChangePassword: false,
      onboardingCompleted: true,
      onboardingStep: 'completed',
      permissions: permissions,
    );

Future<void> _pump(WidgetTester tester, User user) =>
    tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: ShortcutsGrid(user: user)))));

void main() {
  testWidgets('yalnızca payroll.read: kısayol var, adı menüdeki ve ekrandaki gibi "Maaş"', (tester) async {
    await _pump(tester, _user({'projects.read', 'payroll.read'}));
    expect(find.text('Maaş'), findsOneWidget);
    expect(find.text('Mesai'), findsNothing);
  });

  testWidgets('puantaj ve maaş izni: kısayolun adı "Mesai"', (tester) async {
    await _pump(tester, _user({'attendance.read', 'payroll.read'}));
    expect(find.text('Mesai'), findsOneWidget);
    expect(find.text('Maaş'), findsNothing);
  });

  testWidgets('attendance.read: Mesai kısayolu var', (tester) async {
    await _pump(tester, _user({'attendance.read'}));
    expect(find.text('Mesai'), findsOneWidget);
  });

  testWidgets('ikisi de yoksa Mesai kısayolu yok', (tester) async {
    await _pump(tester, _user({'projects.read'}));
    expect(find.text('Mesai'), findsNothing);
    expect(find.text('Maaş'), findsNothing);
  });
}
