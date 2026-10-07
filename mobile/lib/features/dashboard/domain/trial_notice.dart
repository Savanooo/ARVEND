import '../../../core/utils/formatters.dart';
import '../../auth/domain/user.dart';

/// Ana Sayfa deneme süresi uyarısı (ürün kararı 2026-10-07). Erişim
/// OTOMATİK KESİLMEZ -- bu yalnızca bir hatırlatmadır. Kural:
///
/// - Yalnızca firmanın Sahip/Yönetici rolündekiler görür (ödeme/sözleşme
///   kararı onların); diğer roller hiçbir şey görmez.
/// - Bitişe 7 gün ya da daha az kaldığında ve süre dolduğunda.
/// - Kalan gün ve "doldu mu" sunucudan gelir (İstanbul günü, bkz. backend
///   domain.Organization.Trial); burada tarih hesabı yapılmaz.
class TrialNotice {
  const TrialNotice({required this.expired, required this.text});

  final bool expired;
  final String text;
}

/// Uyarının gösterileceği son gün sayısı (bitişe bu kadar ya da daha az).
const kTrialNoticeDays = 7;

TrialNotice? trialNoticeFor(User? user) {
  if (user == null || user.organizationStatus != 'trial') return null;
  if (user.organizationRoleCode != 'owner' && user.organizationRoleCode != 'admin') return null;
  final days = user.trialDaysLeft;
  if (days == null) return null;
  if (user.trialExpired) {
    final endsOn = user.trialEndsOn == null ? '' : ' ${Formatters.date(user.trialEndsOn)} tarihinde';
    return TrialNotice(
      expired: true,
      text: 'Deneme süreniz$endsOn bitti. Devam etmek için ARVEND ile iletişime geçin.',
    );
  }
  if (days > kTrialNoticeDays) return null;
  return TrialNotice(
    expired: false,
    text: days <= 0 ? 'Deneme süreniz bugün bitiyor.' : 'Deneme süreniz $days gün sonra bitiyor.',
  );
}
