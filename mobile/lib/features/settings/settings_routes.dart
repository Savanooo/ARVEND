import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'presentation/smtp_settings_screen.dart';

/// E-posta (SMTP) ayarları rotası -- `/diger` dalının ALTINA (relative)
/// eklenir: tam yol `/diger/eposta-ayarlari`. `/diger/firma-ayarlari`
/// (Firma Ayarları, `/organization/settings`) ile karıştırılmamalı.
final List<RouteBase> settingsRoutes = [
  GoRoute(path: 'eposta-ayarlari', builder: (context, state) => const SmtpSettingsScreen()),
];

/// Diğer menüsü girdisi (label, icon, route, permission). `permission` katı
/// `canAccess` ile kontrol edilmeli -- `organization.settings.*` Yönetici'ye
/// kilitlidir (kaba rol admin de gerekir). Menüde "Yönetim" bölümüne aittir.
const settingsMenuEntries = <({String label, IconData icon, String route, String permission})>[
  (
    label: 'E-posta Ayarları',
    icon: Icons.mail_outline,
    route: '/diger/eposta-ayarlari',
    permission: 'organization.settings.read',
  ),
];
