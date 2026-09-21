import 'package:flutter/material.dart';

/// Uygulama bilinçli olarak DÜZ/kenarlıklı bir görünüm kullanır
/// (kartlarda elevation:0 + border, bkz. AppTheme) -- gölge yalnızca
/// gerçekten "yüzen" öğeler (sabit alt aksiyon çubuğu, bottom sheet üst
/// kenarı gibi) için, tek ve çok hafif bir tonda kullanılır. Ekranlara
/// rastgele/ağır gölge değerleri EKLENMEZ.
abstract final class AppShadows {
  static const subtle = [
    BoxShadow(color: Color(0x14111827), blurRadius: 16, offset: Offset(0, -2)),
  ];
}
