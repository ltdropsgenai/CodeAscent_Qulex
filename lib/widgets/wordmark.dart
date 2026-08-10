import 'package:flutter/material.dart';
import '../theme.dart';

/// The "Qbit" wordmark: serif cream letters with a coral accent slash over the Q
/// (echoes the CodeAscent / Lexicon brand-slash motif).
class Wordmark extends StatelessWidget {
  final double size;
  const Wordmark({super.key, this.size = 30});

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Text('Qbit',
            style: QType.serif(size: size, color: QColors.cream, weight: FontWeight.w600)),
        Positioned(
          left: size * 0.40,
          top: size * 0.02,
          child: Transform.rotate(
            angle: -0.9,
            child: Container(
              width: size * 0.44,
              height: size * 0.085,
              decoration: BoxDecoration(
                color: QColors.coral,
                borderRadius: BorderRadius.circular(size * 0.05),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
