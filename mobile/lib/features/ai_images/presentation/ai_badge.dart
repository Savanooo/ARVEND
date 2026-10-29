import 'package:flutter/material.dart';

import '../../../core/utils/formatters.dart';
import '../../projects/domain/project.dart';

/// "Yapay zekâ" rozeti: ızgarada ve galeride üretilmiş görseli gerçek şantiye
/// fotoğrafından ayırır. Fotoğrafın üstünde de okunsun diye dolu mor zemin,
/// beyaz yazı (durum renkleri -- yeşil/mavi/gri -- aşama rozetinde kullanılıyor,
/// karışmasın).
class AiBadge extends StatelessWidget {
  const AiBadge({super.key});

  static const color = Color(0xFF6D28D9);

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('ai-badge'),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome, size: 11, color: Colors.white),
          SizedBox(width: 3),
          Text(
            'Yapay zekâ',
            style: TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

/// Galeri açıklaması: "Yapay zekâ ile üretildi · kaynak: 12.10.2026".
/// Kaynak tarihi yoksa (kaynaksız üretim ya da eski sunucu) yalnızca ilk kısım.
String aiCaption(ProjectPhotoAi ai) {
  final source = ai.sourceDate;
  if (source == null || source.isEmpty) return 'Yapay zekâ ile üretildi';
  return 'Yapay zekâ ile üretildi · kaynak: ${Formatters.date(source)}';
}
