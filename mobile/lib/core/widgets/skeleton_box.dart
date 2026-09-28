import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Yükleniyor yer tutucusu -- "0" gösterilmez, kutu çizilir (spec §6.7).
/// 1,2 sn'lik yumuşak opaklık nabzı; sistemde animasyonlar kapalıysa
/// (`MediaQuery.disableAnimations`) sabit kalır.
class SkeletonBox extends StatefulWidget {
  const SkeletonBox({super.key, required this.height, this.width, this.radius = 10});

  final double height;
  final double? width;
  final double radius;

  @override
  State<SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<SkeletonBox> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
      _controller.value = 1;
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.45, end: 1).animate(_controller),
      child: Container(
        height: widget.height,
        width: widget.width,
        decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(widget.radius)),
      ),
    );
  }
}
