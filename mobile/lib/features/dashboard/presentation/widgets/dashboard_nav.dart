import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/app_status_colors.dart';
import '../../data/dashboard_providers.dart';
import '../../domain/dashboard_registry.dart';

/// Sekme kökleri (`/projeler`, `/teklifler`, `/gorevler`) `go` ile dal
/// değiştirir; kayıt ekranları ve Diğer altındaki ekranlar `push` edilir
/// (spec §2 "go"/"push" sütunu).
///
/// `push` edilen ekrandan dönülünce anlık görüntü tazelenir ([openRecordRoute]);
/// ana sayfanın kendi Dikkat listesi (aynı anlık görüntü) hariç.
void openModuleRoute(BuildContext context, ModuleRoute route) {
  if (route.push && !route.path.startsWith('/ana-sayfa')) {
    openRecordRoute(context, route.path);
  } else if (route.push) {
    context.push(route.path);
  } else {
    context.go(route.path);
  }
}

/// Ana sayfa / Dikkat satırından bir KAYIT ekranına (ek iş, ödeme planı
/// kalemi, fatura, aşama, revizyon...) gider; geri dönülünce ana sayfa anlık
/// görüntüsü tazelenir -- orada yapılan bir işlem (ör. gecikmiş kalemi iptal
/// etmek) listede bayat kalmasın. Ana sayfa dalı StatefulShellRoute'ta canlı
/// kaldığı için kendiliğinden yenilenmez. Kapsayıcı `push`'tan ÖNCE alınır
/// (satır bu arada ağaçtan kalkabilir); hızlı işlemlerle aynı desen.
Future<void> openRecordRoute(BuildContext context, String route) async {
  final container = ProviderScope.containerOf(context, listen: false);
  await context.push(route);
  container.invalidate(dashboardProvider);
}

/// Bölüm başlığının sağındaki "Tümü" bağlantısı. Sıkı çizilir (iç boşluk
/// yok, shrinkWrap): varsayılan 48dp TextButton başlığı uzatıp bölümler
/// arası dikey ritmi bozuyor ve metni kartların sağ kenarından içeri
/// itiyordu. En az 48x24dp dokunma alanı korunur.
class HeaderLink extends StatelessWidget {
  const HeaderLink({super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      style: TextButton.styleFrom(
        padding: EdgeInsets.zero,
        minimumSize: const Size(48, 24),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        alignment: Alignment.centerRight,
      ),
      onPressed: onPressed,
      child: Text(label),
    );
  }
}

/// Önem derecesi -> renk (spec §6.4 "Colours"): danger=error,
/// action=warning (mobilde gold bir durum rengi DEĞİLDİR, D7), info=info.
Color severityColor(String severity) => switch (severity) {
  'danger' => AppStatusColors.error,
  'action' => AppStatusColors.warning,
  _ => AppStatusColors.info,
};

/// İşaretli KISA değerin rengi (web `signTone` ile aynı): renk YUVARLANMIŞ
/// değere bakar -- 0,40 gibi bir tutar "0 TL" yazılır, yeşil/kırmızı
/// boyanmaz (işaretsiz sıfır nötr kalır).
Color? signedValueColor(num value) {
  final rounded = value.round();
  if (rounded > 0) return AppStatusColors.success;
  if (rounded < 0) return AppStatusColors.error;
  return null;
}

IconData severityIcon(String severity) => switch (severity) {
  'danger' => Icons.warning_amber_rounded,
  'action' => Icons.fact_check_outlined,
  _ => Icons.hourglass_empty,
};
