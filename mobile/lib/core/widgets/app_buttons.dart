import 'package:flutter/material.dart';

/// Standart birincil aksiyon butonu -- form gönderimlerinde tekrarlanan
/// "yükleniyor mu, düz metin mi" dallanmasını (bkz. offer/subcontract/vb.
/// formları) tek yerde toplar. Görsel stil global `ElevatedButtonTheme`den
/// (bkz. AppTheme) gelir, burada YENİDEN tanımlanmaz.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.loading = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: loading ? null : onPressed,
      child: loading
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
            )
          : icon == null
              ? Text(label)
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  // Dar alanda (yan yana iki düğme, büyük yazı) etiket
                  // satırı taşırmak yerine "…" ile kısalır.
                  children: [
                    Icon(icon, size: 18),
                    const SizedBox(width: 8),
                    Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  ],
                ),
    );
  }
}

class SecondaryButton extends StatelessWidget {
  const SecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.loading = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: loading ? null : onPressed,
      child: loading
          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5))
          : icon == null
              ? Text(label)
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  // Dar alanda (yan yana iki düğme, büyük yazı) etiket
                  // satırı taşırmak yerine "…" ile kısalır.
                  children: [
                    Icon(icon, size: 18),
                    const SizedBox(width: 8),
                    Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  ],
                ),
    );
  }
}
