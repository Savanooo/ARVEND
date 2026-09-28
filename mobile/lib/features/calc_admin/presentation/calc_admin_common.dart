import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/access_notices.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_badge.dart';

/// Diğer sekmesi altındaki taban yol -- rotalar `calc_admin_routes.dart`'ta
/// bu yolun altına (relative) tanımlıdır.
const kCalcAdminBasePath = '/diger/metraj-receteleri';

const kPermCalculationsRead = 'calculations.read';
const kPermCalculationsManage = 'calculations.manage';
const kPermProductsRead = 'products.read';

/// Ekranın izin özeti -- HER ZAMAN katı (fail-closed) `canAccess` ile.
typedef CalcAdminAccess = ({bool canRead, bool canManage, bool canReadProducts});

CalcAdminAccess watchCalcAdminAccess(WidgetRef ref) {
  final user = ref.watch(authControllerProvider).valueOrNull;
  final canRead = user.canAccess(kPermCalculationsRead);
  return (
    canRead: canRead,
    // Yazma izni okuma olmadan anlamsız (web de önce sayfa kapısına bakar).
    canManage: canRead && user.canAccess(kPermCalculationsManage),
    canReadProducts: user.canAccess(kPermProductsRead),
  );
}

/// Web'deki salt-okunur uyarısının birebir metni.
const kCalcReadOnlyMessage =
    'Bu kaydı yalnızca görüntüleyebilirsin; düzenlemek için rolünde "Metraj kataloğunu düzenleme" izni olmalı.';

const kCalcNoAccessMessage =
    'Metraj reçetelerini görüntüleme yetkin yok. Yöneticinden "Metraj kataloğunu görüntüleme/kullanma" iznini isteyebilirsin.';

/// 403'ü (ör. izin oturum açıkken geri alındı) ham backend metni yerine
/// ne yapılması gerektiğini söyleyen bir mesaja çevirir.
String calcAdminErrorMessage(Object error, {bool write = false}) {
  if (error is ApiException) {
    if (error.isForbidden) {
      return write
          ? 'Bu işlem için yetkin yok. Yöneticinden "Metraj kataloğunu düzenleme" iznini isteyebilirsin.'
          : kCalcNoAccessMessage;
    }
    return error.message;
  }
  return 'Beklenmeyen bir hata oluştu.';
}

/// İzin yokken ekran hiç veri çekmez, yalnızca bunu gösterir -- tüm
/// Yönetim ekranlarıyla aynı ortak [NoAccessView].
class CalcNoAccessView extends StatelessWidget {
  const CalcNoAccessView({super.key, this.message = kCalcNoAccessMessage});

  final String message;

  @override
  Widget build(BuildContext context) => NoAccessView(message: message);
}

/// `AsyncStateView`'in bu modüle özel hali: hata/boş durumları da
/// kaydırılabilir olduğu için aşağı çekip yenileme her durumda çalışır;
/// 403 anlaşılır bir yetki mesajına çevrilir.
class CalcRefreshableAsync<T> extends StatelessWidget {
  const CalcRefreshableAsync({super.key, required this.value, required this.onRefresh, required this.builder});

  final AsyncValue<T> value;
  final Future<void> Function() onRefresh;
  final List<Widget> Function(BuildContext context, T data) builder;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: value.when(
        // Yenilemede (bağımlı liste tazelenirken) eldeki veri kalır; gösterge
        // RefreshIndicator'dadır.
        skipLoadingOnRefresh: true,
        skipLoadingOnReload: true,
        data: (d) => ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, 96),
          children: builder(context, d),
        ),
        loading: () => const LoadingState(),
        error: (err, _) => LayoutBuilder(
          builder: (context, constraints) => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              SizedBox(
                height: constraints.maxHeight,
                child: _CalcErrorBody(error: err, onRetry: onRefresh),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CalcErrorBody extends StatelessWidget {
  const _CalcErrorBody({required this.error, required this.onRetry});

  final Object error;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final forbidden = error is ApiException && (error as ApiException).isForbidden;
    if (forbidden) return NoAccessView(message: calcAdminErrorMessage(error));
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: AppColors.danger, size: 40),
            const SizedBox(height: AppSpacing.md),
            Text(
              calcAdminErrorMessage(error),
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textMuted),
            ),
            const SizedBox(height: AppSpacing.lg),
            OutlinedButton(onPressed: onRetry, child: const Text('Tekrar Dene')),
          ],
        ),
      ),
    );
  }
}

/// Sağlayıcıları tazeler ve [wait] bitene kadar bekler: aşağı çekip
/// yenileme göstergesi veri gelene kadar açık kalır (hemen kapanıp eski
/// liste saniyelerce geri bildirim olmadan kalmasın). Hata yutulur; gövde
/// hatayı zaten gösterir.
Future<void> refreshCalc(WidgetRef ref, List<ProviderOrFamily> providers, Future<Object?> Function() wait) async {
  for (final p in providers) {
    ref.invalidate(p);
  }
  try {
    await wait();
  } catch (_) {
    // Gövde hatayı gösterir.
  }
}

/// Aktif/Pasif rozeti -- web `GROUP_STATUS`/`CATEGORY_STATUS`/`ITEM_STATUS`
/// ile aynı etiket ve tonlar.
Widget calcActiveBadge(bool isActive) => isActive
    ? const StatusBadge(label: 'Aktif', tone: StatusTone.success)
    : const StatusBadge(label: 'Pasif', tone: StatusTone.muted);
