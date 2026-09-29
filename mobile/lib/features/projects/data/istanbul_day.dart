import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// "Bugün" sağlayıcılarının ortak gövdesi (Planlama gecikmeleri, ödeme planı/
/// fatura vade ipuçları): İstanbul gününü döndürür ve gün DEĞİŞİNCE
/// sağlayıcıyı kendisi yeniler -- izleyen ekranlar "Gecikti"/gün sayılarını
/// yeniden hesaplar. Aksi halde değer uygulama süreci boyunca ilk okunduğu
/// günde donuyordu (Pazartesi açılıp arka planda kalan uygulama Perşembe
/// günü dünkü aşamayı "gecikmedi" gösteriyordu).
///
/// İki tetik:
/// - Önplandayken İstanbul gece yarısı: zamanlayıcı.
/// - Arka plandan dönüş: cihaz uyurken zamanlayıcı ilerlemeyebilir; dönüşte
///   gün değiştiyse yenilenir.
///
/// [today], `now` için İstanbul gününü (UTC 00:00 işaretli takvim günü)
/// veren saf fonksiyondur; [clock] yalnızca testte değiştirilir.
DateTime trackIstanbulDay(
  Ref ref,
  DateTime Function(DateTime now) today, {
  DateTime Function() clock = DateTime.now,
}) {
  final now = clock();
  final value = today(now);
  final nextMidnight = DateTime.utc(value.year, value.month, value.day + 1).subtract(const Duration(hours: 3));
  var wait = nextMidnight.difference(now.toUtc()) + const Duration(seconds: 1);
  if (wait.isNegative) wait = const Duration(seconds: 1);
  final timer = Timer(wait, ref.invalidateSelf);
  AppLifecycleListener? listener;
  try {
    listener = AppLifecycleListener(
      onResume: () {
        if (today(clock()) != value) ref.invalidateSelf();
      },
    );
  } catch (_) {
    // Widget binding'i olmayan saf birim testlerinde dinleyici kurulamaz;
    // zamanlayıcı yine çalışır.
    listener = null;
  }
  ref.onDispose(() {
    timer.cancel();
    listener?.dispose();
  });
  return value;
}
