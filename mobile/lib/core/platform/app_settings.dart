import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Telefonun bu uygulamaya ait ayar sayfasını açar (izinler oradan açılır);
/// açılamazsa false. Testler sahtesini verir.
typedef AppSettingsOpener = Future<bool> Function();

/// MainActivity.kt'deki kanal adıyla BİREBİR aynı.
const _channel = MethodChannel('com.arvendyapi.arvend/app_settings');

Future<bool> openAppSettings() async {
  try {
    return await _channel.invokeMethod<bool>('openAppSettings') ?? false;
  } on PlatformException catch (e) {
    debugPrint('Uygulama ayarları açılamadı: ${e.code}');
    return false;
  } on MissingPluginException {
    // iOS/web: kanal yok.
    return false;
  }
}

final appSettingsOpenerProvider = Provider<AppSettingsOpener>((ref) => openAppSettings);
