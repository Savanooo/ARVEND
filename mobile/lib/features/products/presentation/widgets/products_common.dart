import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/auth/auth_controller.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/errors/api_exception.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/access_notices.dart';
import '../../../../core/widgets/app_data_row.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../../../../core/widgets/status_badge.dart';
import '../../domain/price_change.dart';
import '../../domain/price_source.dart';

/// Ürünler / Fiyat Kaynakları / Zam Geçmişi ekranlarının ortak küçük
/// parçaları (web `PriceChangeBits.tsx` karşılığı).

/// İzin kontrolü -- KATI (`canAccess`, fail-closed): kullanıcı yüklenmemişse
/// ya da izin kümesi boşsa erişim YOK. Asıl sınır yine backend'dedir.
bool productsCan(WidgetRef ref, String code) => ref.watch(authControllerProvider).valueOrNull.canAccess(code);

/// Tedarikçi rozeti: "Ulaş", "Demir Profil".
class SourceBadge extends StatelessWidget {
  const SourceBadge({super.key, required this.source, this.name});
  final String source;
  final String? name;

  @override
  Widget build(BuildContext context) => StatusBadge(label: sourceLabels(source, name).short, tone: StatusTone.info);
}

/// "Ulaş listesinde yok" -- ürün kaynağın son başarılı senkronunda görülmedi.
class MissingFromSourceBadge extends StatelessWidget {
  const MissingFromSourceBadge({super.key, required this.source, this.name});
  final String source;
  final String? name;

  @override
  Widget build(BuildContext context) =>
      StatusBadge(label: '${sourceLabels(source, name).short} listesinde yok', tone: StatusTone.danger);
}

/// Zam müşteri için maliyet artışıdır: tehlike tonu; indirim başarı tonu.
/// Renk tek başına taşımaz, metinde her zaman ↑/↓ ya da +/− de vardır.
Color changeToneColor(ChangeTone tone) => switch (tone) {
  ChangeTone.up => AppColors.danger,
  ChangeTone.down => AppColors.success,
  ChangeTone.flat => AppColors.textMuted,
};

/// "↑ %3,25" (zam) / "↓ %2,1" (indirim); yüzde tanımsızsa "—".
class ChangePercentText extends StatelessWidget {
  const ChangePercentText({
    super.key,
    required this.oldPrice,
    required this.newPrice,
    required this.percent,
    this.style,
  });

  final double oldPrice;
  final double newPrice;
  final double? percent;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final tone = changeTone(oldPrice, newPrice);
    return Text(
      formatChangePercent(percent, tone),
      maxLines: 1,
      style: (style ?? AppTypography.body).copyWith(
        color: changeToneColor(tone),
        fontWeight: FontWeight.w700,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

enum NoticeTone { success, danger, info, muted }

/// Kart içi bilgi/uyarı kutusu (web `rounded-md bg-*-soft` kutuları).
class ProductsNotice extends StatelessWidget {
  const ProductsNotice({super.key, required this.text, this.tone = NoticeTone.info, this.trailing});

  final String text;
  final NoticeTone tone;
  final Widget? trailing;

  Color get _color => switch (tone) {
    NoticeTone.success => AppColors.success,
    NoticeTone.danger => AppColors.danger,
    NoticeTone.info => AppColors.info,
    NoticeTone.muted => AppColors.textMuted,
  };

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: tone == NoticeTone.success || tone == NoticeTone.danger,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        decoration: BoxDecoration(
          color: _color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(text, style: AppTypography.metadata.copyWith(color: _color, height: 1.35)),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// Yetkisiz kullanıcıya gösterilen açıklama (çökme/boş ekran yerine) --
/// tüm Yönetim ekranlarıyla aynı ortak görünüm ([NoAccessView]).
class ProductsDeniedView extends StatelessWidget {
  const ProductsDeniedView({super.key, required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => NoAccessView(message: message);
}

const kProductsReadDenied =
    'Ürün kataloğunu görüntüleme yetkin yok. Bu bölüm için rolünde "Ürün kataloğunu görüntüleme" izni olmalı.';
const kProductsManageDenied =
    'Bu işlem için yetkin yok; rolünde "Ürün kataloğunu düzenleme" izni olmalı.';

/// Salt-okunur açıklamaları ([ReadOnlyNotice] ile gösterilir).
const kProductsListReadOnly =
    'Ürünleri yalnızca görüntüleyebilirsin; eklemek veya düzenlemek için rolünde "Ürün kataloğunu düzenleme" '
    'izni olmalı.';
const kProductReadOnly =
    'Bu kaydı yalnızca görüntüleyebilirsin; düzenlemek için rolünde "Ürün kataloğunu düzenleme" izni olmalı.';
const kPriceSourcesReadOnly =
    'Kaynak durumunu yalnızca görüntüleyebilirsin; güncelleme ve kâr oranı ayarları için rolünde "Ürün '
    'kataloğunu düzenleme" izni olmalı.';

/// Ekranı izne göre açar: oturum yüklenirken bekler, izin yoksa açıklama
/// gösterir -- izinsiz kullanıcı için HİÇBİR istek atılmaz.
class ProductsAccessGate extends ConsumerWidget {
  const ProductsAccessGate({
    super.key,
    required this.permission,
    required this.child,
    this.deniedMessage = kProductsReadDenied,
  });

  final String permission;
  final Widget child;
  final String deniedMessage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    if (auth.isLoading && !auth.hasValue) return const LoadingState();
    if (!auth.valueOrNull.canAccess(permission)) return ProductsDeniedView(message: deniedMessage);
    return child;
  }
}

/// Yazma işlemi hatasının metni: 403'te izin açıklaması, diğerlerinde
/// backend'in Türkçe mesajı.
String productsActionError(Object error) {
  if (error is ApiException) return error.isForbidden ? kProductsManageDenied : error.message;
  return 'Beklenmeyen bir hata oluştu.';
}

/// Okuma hatasının metni: 403'te görüntüleme izni açıklaması.
String productsLoadError(Object error) {
  if (error is ApiException) return error.isForbidden ? kProductsReadDenied : error.message;
  return 'Beklenmeyen bir hata oluştu.';
}

/// `AsyncStateView` ile aynı iskelet; yalnızca 403, ham "yetkiniz yok"
/// yerine açıklayıcı izin metnine çevrilir (ekran çökmez).
class ProductsAsyncView<T> extends StatelessWidget {
  const ProductsAsyncView({
    super.key,
    required this.value,
    required this.data,
    this.onRetry,
    this.loading,
  });

  final AsyncValue<T> value;
  final Widget Function(BuildContext context, T data) data;
  final Future<void> Function()? onRetry;
  final Widget? loading;

  @override
  Widget build(BuildContext context) {
    return value.when(
      data: (d) => data(context, d),
      loading: () => loading ?? const LoadingState(),
      error: (err, _) {
        if (err is ApiException && err.isForbidden) return const ProductsDeniedView(message: kProductsReadDenied);
        return ErrorState(error: err, onRetry: onRetry);
      },
    );
  }
}

/// Etiket + değer satırı; değer hiç kesilmez -- kısaysa sağa yaslı aynı
/// satırda, uzunsa etiketin altında sola hizalı (ortak `AppDataRow`
/// çok satırlı düzeni; sağa yaslı çok satırlı paragraf okunmuyordu).
class ProductInfoRow extends StatelessWidget {
  const ProductInfoRow({super.key, required this.label, required this.value, this.valueStyle});
  final String label;
  final String value;
  final TextStyle? valueStyle;

  @override
  Widget build(BuildContext context) =>
      AppDataRow(label: label, value: value, valueStyle: valueStyle, multiline: true);
}

/// Kaynağın sitesine dış bağlantı (yalnızca https -- çağıran
/// [isSafeSiteUrl] ile süzer).
class SiteLink extends StatelessWidget {
  const SiteLink({super.key, required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              siteHost(url),
              style: AppTypography.helper.copyWith(color: AppColors.gold, fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.open_in_new, size: 13, color: AppColors.gold),
          ],
        ),
      ),
    );
  }
}

/// Başlıklı kart gövdesi -- web `CardHeader` + `CardBody` düzeni.
class ProductsSectionCard extends StatelessWidget {
  const ProductsSectionCard({super.key, required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.md),
            child: Row(
              children: [
                Expanded(child: Text(title, style: AppTypography.cardTitle)),
                if (trailing != null) ...[const SizedBox(width: AppSpacing.sm), trailing!],
              ],
            ),
          ),
          const Divider(),
          Padding(padding: const EdgeInsets.all(AppSpacing.lg), child: child),
        ],
      ),
    );
  }
}
