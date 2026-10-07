import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

/// Kaydedilen bir oluşturma/düzenleme formundan çıkış.
///
/// Eskiden formlar `context.go(detay)` çağırıyordu: yığın sıfırlanır ve formu
/// `await context.push(...)` ile açanın Future'ı HİÇ tamamlanmaz (go_router
/// 16'da `pushReplacement` da tamamlamaz). Ana sayfanın hızlı işlemleri bu
/// Future'ı bekleyip kilidi çözer; tamamlanmayınca kilit açık kalıyor, eski
/// dolu form geri gelebiliyor ve ikinci kayıt mükerrer oluşuyordu.
///
/// - Oluşturma: form [result] ile KAPATILIR (açanın `push`'u tamamlanır),
///   ardından yeni kaydın detayı onun üstüne `push` edilir -- detaydan geri,
///   formu açan ekrana döner.
/// - Düzenleme ([isEdit]): detay zaten alttadır (sağlayıcıları tazelenmiş);
///   form yalnızca kapatılır.
///
/// Form yığının kökündeyse (derin bağlantı, kapatılacak bir şey yok) detaya
/// `go`.
void leaveSavedForm(BuildContext context, String detailPath, {required bool isEdit, Object? result}) {
  final router = GoRouter.of(context);
  if (!router.canPop()) {
    router.go(detailPath);
    return;
  }
  router.pop(result);
  if (!isEdit) router.push(detailPath);
}
