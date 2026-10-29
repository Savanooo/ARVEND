import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/chat_providers.dart';

/// Firma Grubu fotoğrafı tam ekran: iki parmakla yakınlaştırma. Bayt küçük
/// resimle aynı sağlayıcıdan (önbellekten) gelir, ikinci kez inmez.
class ChatPhotoViewer extends ConsumerWidget {
  const ChatPhotoViewer({super.key, required this.messageId, required this.title, this.subtitle = ''});

  final String messageId;
  final String title;
  final String subtitle;

  static Future<void> open(BuildContext context, {required String messageId, required String title, String subtitle = ''}) =>
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ChatPhotoViewer(messageId: messageId, title: title, subtitle: subtitle),
      ));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = ref.watch(chatPhotoBytesProvider(messageId));
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 16)),
            if (subtitle.isNotEmpty)
              Text(subtitle, maxLines: 1, style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ],
        ),
      ),
      body: bytes.when(
        data: (b) => InteractiveViewer(
          maxScale: 5,
          child: Center(child: Image.memory(b, fit: BoxFit.contain, gaplessPlayback: true)),
        ),
        loading: () => const Center(child: CircularProgressIndicator(color: Colors.white)),
        error: (_, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.broken_image_outlined, color: Colors.white70, size: 40),
              const SizedBox(height: 12),
              const Text('Fotoğraf yüklenemedi', style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 12),
              OutlinedButton(
                style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
                onPressed: () => ref.invalidate(chatPhotoBytesProvider(messageId)),
                child: const Text('Tekrar Dene'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
