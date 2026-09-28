import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Sayfadan çıkışı (AppBar geri oku, Android geri hareketi, alt sayfanın
/// dışına dokunma) iki durumda yakalar:
///
/// - [busy]: çok adımlı bir kayıt sürüyor -- çıkış ENGELLENİR ve kısa bir
///   not gösterilir. Yarıda bırakılan kayıt (ör. hesap açıldı ama personele
///   bağlanmadı) sessizce yarım kalmasın.
/// - [dirty]: kaydedilmemiş değişiklik var -- onay sorulur; "Çık" denirse
///   sayfa kapanır, değişiklikler atılır.
///
/// Aynı sayfada birden çok kapsam olabilir (ör. kullanıcı bilgileri + rol
/// ve yetkiler kartı); onay penceresi yine TEK kez açılır.
class UnsavedChangesScope extends StatelessWidget {
  const UnsavedChangesScope({super.key, required this.child, this.dirty = false, this.busy = false});

  final Widget child;
  final bool dirty;
  final bool busy;

  static bool _asking = false;

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: !dirty && !busy,
      onPopInvokedWithResult: (didPop, result) async {
        // Çıkışı BAŞKA bir kapsam engellediyse de bu geri çağrı çalışır;
        // yalnızca kendi durumu (kayıt / değişiklik) için tepki verir.
        if (didPop) return;
        if (busy) {
          ScaffoldMessenger.maybeOf(context)
            ?..hideCurrentSnackBar()
            ..showSnackBar(
              const SnackBar(content: Text('Kaydediliyor, lütfen bitmesini bekle.'), duration: Duration(seconds: 2)),
            );
          return;
        }
        if (!dirty || _asking) return;
        _asking = true;
        try {
          final leave = await confirmDiscardChanges(context);
          if (leave && context.mounted) Navigator.of(context).pop(result);
        } finally {
          _asking = false;
        }
      },
      child: child,
    );
  }
}

/// "Kaydedilmemiş değişiklikler var" onayı; çıkılacaksa `true`.
Future<bool> confirmDiscardChanges(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Kaydedilmemiş değişiklikler'),
      content: const Text('Kaydedilmemiş değişiklikler var. Çıkmak istiyor musun?'),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Vazgeç')),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: AppColors.danger),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Çık'),
        ),
      ],
    ),
  );
  return ok ?? false;
}
