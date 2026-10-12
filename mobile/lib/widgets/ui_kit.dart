import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Shared visual language for the cafe app: warm coffee palette, gradients,
/// hand-drawn latte-art illustration, and small reusable display widgets.
class CafePalette {
  static const coffee = Color(0xFF6F4E37);
  static const espresso = Color(0xFF4E3626);
  static const caramel = Color(0xFFC8956C);
  static const cream = Color(0xFFF6F4F1);
  static const latte = Color(0xFFEDE4DA);
  static const mint = Color(0xFF5FAB86);
  static const berry = Color(0xFFB3546E);
  static const sunshine = Color(0xFFF2B251);
  static const sky = Color(0xFF5B8DEF);
  static const peach = Color(0xFFE8845C);
  static const mist = Color(0xFFE4E6EB);
  static const charcoal = Color(0xFF333333);
  static const ivory = Color(0xFFFFFFFF);
}

class CafeGradients {
  static const coffee = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF6F4E37), Color(0xFFA0785A)],
  );
  static const espresso = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF4E3626), Color(0xFF6F4E37)],
  );
  static const sunrise = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFF2B251), Color(0xFFE8845C)],
  );
  static const peach = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFFFB88C), Color(0xFFE8845C)],
  );
  static const mint = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF5FAB86), Color(0xFF8FD0AA)],
  );
  static const berry = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFB3546E), Color(0xFFD98A9E)],
  );
  static const sky = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF5B8DEF), Color(0xFF8FB8F8)],
  );

  /// Stable pick from a seed string so the same category/dish always gets
  /// the same color.
  static LinearGradient forSeed(Object seed) {
    const all = [coffee, sunrise, peach, mint, berry, sky];
    return all[seed.toString().hashCode.abs() % all.length];
  }
}

/// Emoji stand-ins for food/drink art — offline-safe "images" for items
/// without photos.
String categoryEmoji(String category) {
  final c = category.toLowerCase().replaceAll('_', ' ');
  if (c.contains('coffee') || c.contains('espresso') || c.contains('latte')) {
    return '☕';
  }
  if (c.contains('tea') || c.contains('chai')) return '🍵';
  if (c.contains('cold') || c.contains('drink') || c.contains('juice')) {
    return '🥤';
  }
  if (c.contains('shake') || c.contains('smoothie')) return '🥛';
  if (c.contains('farsan') || c.contains('snack') || c.contains('namkeen')) {
    return '🥟';
  }
  if (c.contains('sandwich') || c.contains('toast')) return '🥪';
  if (c.contains('pizza')) return '🍕';
  if (c.contains('burger')) return '🍔';
  if (c.contains('fries') || c.contains('chaat')) return '🍟';
  if (c.contains('dessert') || c.contains('sweet') || c.contains('cake')) {
    return '🍰';
  }
  if (c.contains('ice') || c.contains('kulfi')) return '🍨';
  if (c.contains('main') || c.contains('meal') || c.contains('thali')) {
    return '🍛';
  }
  if (c.contains('bread') || c.contains('bun') || c.contains('bakery')) {
    return '🥐';
  }
  return '🍽️';
}

String dishEmoji(String name, {String category = ''}) {
  final n = name.toLowerCase();
  const keywords = <String, String>{
    'coffee': '☕',
    'espresso': '☕',
    'cappuccino': '☕',
    'latte': '☕',
    'mocha': '☕',
    'cold coffee': '🧊',
    'americano': '☕',
    'chai': '🍵',
    'tea': '🍵',
    'green tea': '🍵',
    'masala': '🍵',
    'juice': '🧃',
    'cola': '🥤',
    'soda': '🥤',
    'lime': '🥤',
    'lemon': '🥤',
    'shake': '🥛',
    'lassi': '🥛',
    'milk': '🥛',
    'samosa': '🥟',
    'kachori': '🥟',
    'dhokla': '🟨',
    'khandvi': '🟨',
    'fafda': '🟨',
    'jalebi': '🍥',
    'gathiya': '🥨',
    'sev': '🥨',
    'khakhra': '🍘',
    'thepla': '🫓',
    'puff': '🥐',
    'sandwich': '🥪',
    'grill': '🥪',
    'toast': '🥪',
    'pizza': '🍕',
    'burger': '🍔',
    'fries': '🍟',
    'pasta': '🍝',
    'noodles': '🍜',
    'dosa': '🥞',
    'idli': '🍚',
    'vada': '🍩',
    'pav': '🍔',
    'bhel': '🥗',
    'chaat': '🥗',
    'pani puri': '🥣',
    'dabeli': '🥙',
    'vada pav': '🍔',
    'cake': '🍰',
    'pastry': '🍰',
    'brownie': '🍫',
    'chocolate': '🍫',
    'ice cream': '🍨',
    'kulfi': '🍨',
    'sweet': '🍬',
    'gulab': '🍡',
    'rasgulla': '🍡',
    'thali': '🍛',
    'curry': '🍛',
    'paneer': '🧆',
    'rice': '🍚',
    'roti': '🫓',
  };
  for (final entry in keywords.entries) {
    if (n.contains(entry.key)) return entry.value;
  }
  return categoryEmoji(category);
}

/// Top-down latte-art illustration: saucer, cup, crema heart, coffee beans.
class LatteArtPainter extends CustomPainter {
  final Color cup;
  final Color crema;
  final Color art;
  final Color bean;
  final bool withBeans;

  LatteArtPainter({
    this.cup = const Color(0xFFFFF8F0),
    this.crema = const Color(0xFFC8956C),
    this.art = const Color(0xFFFFF8F0),
    this.bean = const Color(0xFF4E3626),
    this.withBeans = true,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width * 0.5, size.height * 0.52);
    final radius = math.min(size.width, size.height) * 0.33;

    final saucer = Paint()..color = cup.withValues(alpha: 0.35);
    canvas.drawCircle(center, radius * 1.42, saucer);

    final cupPaint = Paint()..color = cup;
    canvas.drawCircle(center, radius * 1.18, cupPaint);

    final rim = Paint()
      ..color = cup.withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(2, radius * 0.05);
    canvas.drawCircle(center, radius * 1.18, rim);

    final cremaPaint = Paint()..color = crema;
    canvas.drawCircle(center, radius, cremaPaint);

    final ring = Paint()
      ..color = Color.lerp(crema, const Color(0xFF000000), 0.12)!
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.5, radius * 0.06);
    canvas.drawCircle(center, radius * 0.94, ring);

    final heart = Path();
    final hr = radius * 0.52;
    final cy = center.dy - hr * 0.25;
    heart.moveTo(center.dx, cy + hr * 1.05);
    heart.cubicTo(
      center.dx - hr * 1.35,
      cy + hr * 0.1,
      center.dx - hr * 0.85,
      cy - hr * 0.95,
      center.dx,
      cy - hr * 0.35,
    );
    heart.cubicTo(
      center.dx + hr * 0.85,
      cy - hr * 0.95,
      center.dx + hr * 1.35,
      cy + hr * 0.1,
      center.dx,
      cy + hr * 1.05,
    );
    canvas.drawPath(heart, Paint()..color = art);

    if (withBeans) {
      void beanAt(Offset o, double r, double angle) {
        canvas.save();
        canvas.translate(o.dx, o.dy);
        canvas.rotate(angle);
        final p = Paint()..color = bean;
        canvas.drawOval(
            Rect.fromCenter(
                center: Offset.zero, width: r * 2, height: r * 1.35),
            p);
        final crease = Paint()
          ..color = cup.withValues(alpha: 0.85)
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.28
          ..strokeCap = StrokeCap.round;
        canvas.drawArc(
          Rect.fromCenter(center: Offset.zero, width: r * 1.7, height: r * 1.0),
          0.6,
          2.0,
          false,
          crease,
        );
        canvas.restore();
      }

      beanAt(Offset(center.dx - radius * 1.62, center.dy + radius * 0.9),
          radius * 0.22, -0.5);
      beanAt(Offset(center.dx + radius * 1.66, center.dy - radius * 0.7),
          radius * 0.2, 0.7);
    }
  }

  @override
  bool shouldRepaint(covariant LatteArtPainter old) =>
      old.cup != cup ||
      old.crema != crema ||
      old.art != art ||
      old.bean != bean;
}

/// Outline cup-with-steam painter for empty states.
class CupOutlinePainter extends CustomPainter {
  final Color color;

  CupOutlinePainter({this.color = CafePalette.caramel});

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(2, size.width * 0.02)
      ..strokeCap = StrokeCap.round;

    final w = size.width;
    final h = size.height;

    for (var i = 0; i < 3; i++) {
      final x = w * (0.38 + i * 0.12);
      final steam = Path()
        ..moveTo(x, h * 0.30)
        ..cubicTo(x - w * 0.06, h * 0.22, x + w * 0.06, h * 0.16, x, h * 0.08);
      canvas.drawPath(steam, stroke..color = color.withValues(alpha: 0.7));
    }

    final cup = Path()
      ..moveTo(w * 0.25, h * 0.40)
      ..lineTo(w * 0.29, h * 0.72)
      ..arcToPoint(
        Offset(w * 0.61, h * 0.72),
        radius: Radius.circular(w * 0.16),
        clockwise: false,
      )
      ..lineTo(w * 0.65, h * 0.40)
      ..close();
    canvas.drawPath(cup, stroke);

    final handle = Path()
      ..moveTo(w * 0.65, h * 0.46)
      ..arcToPoint(
        Offset(w * 0.78, h * 0.60),
        radius: Radius.circular(w * 0.09),
      )
      ..arcToPoint(
        Offset(w * 0.64, h * 0.66),
        radius: Radius.circular(w * 0.09),
      );
    canvas.drawPath(handle, stroke);

    canvas.drawLine(
        Offset(w * 0.20, h * 0.80), Offset(w * 0.72, h * 0.80), stroke);
  }

  @override
  bool shouldRepaint(covariant CupOutlinePainter old) => old.color != color;
}

/// Gradient hero surface with optional illustration behind content.
class HeroBanner extends StatelessWidget {
  final Gradient gradient;
  final Widget child;
  final Widget? illustration;
  final double? height;
  final EdgeInsetsGeometry padding;
  final BorderRadius? borderRadius;

  const HeroBanner({
    super.key,
    required this.gradient,
    required this.child,
    this.illustration,
    this.height,
    this.padding = const EdgeInsets.all(20),
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    final r = borderRadius ?? BorderRadius.circular(24);
    return Container(
      height: height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: gradient,
        borderRadius: r,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Stack(
        children: [
          if (illustration != null)
            Positioned.fill(child: IgnorePointer(child: illustration!)),
          Padding(padding: padding, child: child),
        ],
      ),
    );
  }
}

/// Small colored icon chip used in cards and quick actions.
class IconChip extends StatelessWidget {
  final IconData icon;
  final Gradient? gradient;
  final Color? color;
  final double size;
  final double iconSize;

  const IconChip({
    super.key,
    required this.icon,
    this.gradient,
    this.color,
    this.size = 44,
    this.iconSize = 22,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: gradient,
        color: color ?? CafePalette.latte,
        borderRadius: BorderRadius.circular(size * 0.32),
        boxShadow: gradient != null
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.10),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ]
            : null,
      ),
      child: Icon(icon, size: iconSize, color: Colors.white),
    );
  }
}

/// Emoji tile used where a photo is missing — gradient panel + big emoji.
class EmojiArtTile extends StatelessWidget {
  final String emoji;
  final Gradient? gradient;
  final double size;
  final double fontSize;

  const EmojiArtTile({
    super.key,
    required this.emoji,
    this.gradient,
    this.size = 84,
    this.fontSize = 38,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: gradient ?? CafeGradients.forSeed(emoji),
        borderRadius: BorderRadius.circular(18),
      ),
      alignment: Alignment.center,
      child: Text(emoji, style: TextStyle(fontSize: fontSize)),
    );
  }
}

class SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;

  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style:
                      text.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: text.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// KPI card with a colored accent — used on dashboards.
class StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Gradient gradient;
  final String? caption;

  const StatCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    required this.gradient,
    this.caption,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.black.withValues(alpha: 0.05)),
      ),
      child: Row(
        children: [
          IconChip(icon: icon, gradient: gradient, size: 42, iconSize: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(value,
                      style: text.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w800)),
                ),
                if (caption != null)
                  Text(caption!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(
                          fontSize: 11,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Tappable quick-action tile: gradient icon + label.
class QuickActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final Gradient gradient;
  final VoidCallback? onTap;
  final String? badge;

  const QuickActionTile({
    super.key,
    required this.icon,
    required this.label,
    required this.gradient,
    this.onTap,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          child: Row(
            children: [
              IconChip(icon: icon, gradient: gradient, size: 40, iconSize: 19),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              if (badge != null)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: gradient.colors.last.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(badge!,
                      style: text.bodySmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: gradient.colors.last)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Friendly empty/error state with the cup illustration.
class EmptyStateArt extends StatelessWidget {
  final String title;
  final String? message;
  final Widget? action;
  final IconData? icon;

  const EmptyStateArt({
    super.key,
    required this.title,
    this.message,
    this.action,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 120,
              height: 110,
              child: CustomPaint(
                painter: CupOutlinePainter(
                  color: scheme.primary.withValues(alpha: 0.55),
                ),
                child: icon == null
                    ? null
                    : Center(
                        child: Icon(icon,
                            size: 22,
                            color: scheme.primary.withValues(alpha: 0.8))),
              ),
            ),
            const SizedBox(height: 14),
            Text(title,
                textAlign: TextAlign.center,
                style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
            if (message != null) ...[
              const SizedBox(height: 6),
              Text(message!,
                  textAlign: TextAlign.center,
                  style:
                      text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            ],
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}
