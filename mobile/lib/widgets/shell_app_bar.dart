import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../services/api_client.dart';
import '../services/offline/offline.dart';
import '../state/tenant_state.dart';
import 'ui_kit.dart';

/// Compact "Sat, 10 Oct" label used as the shells' app-bar subtitle.
String shellDateLabel() => DateFormat('EEE, d MMM').format(DateTime.now());

/// Subtitle line for the shells: the cafe's display name when branding is
/// known ("Bean House Cafe · Sat, 10 Oct"), otherwise the plain date.
///
/// Reads the branding from [TenantState] inside the build so the bar
/// re-arms whenever it loads; a missing provider (widget tests, bare
/// `MaterialApp`) simply falls back to [subtitle] on its own.
String shellSubtitle(BuildContext context, String? subtitle) {
  final brand = tenantStateOf(context)?.displayName;
  if (brand == null || brand.isEmpty) return subtitle ?? '';
  if (subtitle == null || subtitle.isEmpty) return brand;
  return '$brand · $subtitle';
}

/// Branded header for the owner and staff shells: a café badge, the current
/// view title (large, animated, and pinned to its real size so it never
/// collapses into "0"-looking glyphs on web) over a small warm subtitle, the
/// signed-in user's identity chip, and a logout action.
///
/// It is also the app's offline HUD: a slim banner appears under the toolbar
/// when the device is offline (or still holding queued ops), showing the
/// pending-sync count. The banner is wired to [OfflineQueue] +
/// [ConnectivityMonitor], which flush the queue when connectivity returns.
class ShellAppBar extends StatefulWidget implements PreferredSizeWidget {
  const ShellAppBar({
    super.key,
    required this.title,
    required this.userName,
    required this.onLogout,
    this.subtitle,
    this.onAsk,
    this.actions,
  });

  /// Total height (toolbar + 1px hairline below it) when no banner shows.
  static const double kHeight = 66;

  /// Height of the offline / pending-sync banner strip.
  static const double kBannerHeight = 30;

  final String title;
  final String userName;
  final VoidCallback onLogout;

  /// Small secondary line under the title (date, cafe name, …).
  final String? subtitle;

  /// When set, shows the AI-assistant entry point in the app bar.
  final VoidCallback? onAsk;

  /// Additional action widgets to show in the app bar.
  final List<Widget>? actions;

  /// Reserves room for the banner: the strip only *renders* when there is
  /// something to say, but the space is always budgeted so the Scaffold
  /// never has to relayout when connectivity flips.
  @override
  Size get preferredSize => const Size.fromHeight(kHeight - 1 + kBannerHeight);

  @override
  State<ShellAppBar> createState() => _ShellAppBarState();
}

class _ShellAppBarState extends State<ShellAppBar> {
  ApiClient? _api;
  bool _showBanner = false;

  @override
  void initState() {
    super.initState();
    // Bind the offline queue to the shared API client (token included) so
    // reconnect flushes do not need a BuildContext. Falls back gracefully
    // when no Provider is present (widget tests).
    try {
      final api = context.read<ApiClient>();
      _api = api;
      OfflineQueue.instance.bind(api);
    } catch (_) {
      // No ApiClient in this tree (e.g. unit test) — banner still works.
    }
    OfflineQueue.instance.init();
    unawaited(ConnectivityMonitor.instance.start(onOnline: _flushQueue));
    ConnectivityMonitor.instance.isOnline.addListener(_recomputeBanner);
    OfflineQueue.instance.pendingCount.addListener(_recomputeBanner);
    _recomputeBanner();
  }

  @override
  void dispose() {
    ConnectivityMonitor.instance.isOnline.removeListener(_recomputeBanner);
    OfflineQueue.instance.pendingCount.removeListener(_recomputeBanner);
    super.dispose();
  }

  void _recomputeBanner() {
    if (!mounted) return;
    final visible = !ConnectivityMonitor.instance.isOnline.value ||
        OfflineQueue.instance.pendingCount.value > 0;
    if (visible != _showBanner) {
      setState(() => _showBanner = visible);
    }
  }

  void _flushQueue() {
    final api = _api;
    if (api == null) return;
    unawaited(_syncNow(api));
  }

  /// Replay the queue, then refresh the offline menu snapshot from
  /// `GET /sync/pull` (best effort — the queue is what matters).
  Future<void> _syncNow(ApiClient api) async {
    try {
      await OfflineQueue.instance.flush(api);
    } catch (_) {
      // Never let a sync failure escape into the UI.
    }
    try {
      final pull = await api.syncPull();
      final menu = pull['menu'];
      if (menu is List) {
        await MenuCache.saveJson(menu);
      }
    } catch (_) {
      // Offline again or pull unsupported — keep the previous snapshot.
    }
  }

  String get _initial => widget.userName.isEmpty
      ? '?'
      : widget.userName.substring(0, 1).toUpperCase();

  Widget _banner(BuildContext context, ColorScheme scheme) {
    final online = ConnectivityMonitor.instance.isOnline.value;
    final pending = OfflineQueue.instance.pendingCount.value;
    final icon = online ? Icons.cloud_sync_rounded : Icons.cloud_off_rounded;
    final label = online
        ? (pending == 1
            ? '1 order waiting to sync — tap to retry'
            : '$pending orders waiting to sync — tap to retry')
        : (pending > 0
            ? 'Offline — $pending order(s) queued, will sync automatically'
            : 'Offline — new orders are saved and sync automatically');
    final background =
        online ? scheme.tertiaryContainer : scheme.errorContainer;
    final foreground =
        online ? scheme.onTertiaryContainer : scheme.onErrorContainer;
    return Material(
      color: background,
      child: InkWell(
        onTap: online ? _flushQueue : null,
        child: SizedBox(
          height: ShellAppBar.kBannerHeight,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 15, color: foreground),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final baseTitle = Theme.of(context).appBarTheme.titleTextStyle ??
        Theme.of(context).textTheme.titleLarge;
    // Big and unmistakably readable — and we pin the scale so aggressive
    // browser text scaling can't shrink it into a blur of "0"s on web.
    final titleStyle =
        baseTitle?.copyWith(fontSize: 26, fontWeight: FontWeight.w800);
    final subtitleStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
          fontSize: 12.5,
          height: 1.15,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.1,
          color: CafePalette.coffee.withValues(alpha: 0.9),
        );
    // Cafe name + date, or just the date when no branding is loaded yet.
    final subtitle = shellSubtitle(context, widget.subtitle);

    return AppBar(
      toolbarHeight: ShellAppBar.kHeight - 1,
      // Soft warm wash that fades down into the surface colour.
      // NB: the fade-out stop must be cream-at-alpha-0 — interpolating
      // towards `Colors.transparent` (transparent *black*) would tint the
      // bottom of the bar grey.
      flexibleSpace: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFFF0E7DC), // warm latte
              Color(0xFFF6F4F1), // cream
              Color(0x00F6F4F1), // cream, fully transparent
            ],
            stops: [0, 0.62, 1],
          ),
        ),
      ),
      // Hairline (or the offline / pending-sync banner) under the toolbar.
      bottom: PreferredSize(
        preferredSize:
            Size.fromHeight(_showBanner ? ShellAppBar.kBannerHeight : 1),
        child: _showBanner
            ? _banner(context, scheme)
            : Container(
                height: 1,
                color: Colors.black.withValues(alpha: 0.06),
              ),
      ),
      titleSpacing: 16,
      title: Row(
        children: [
          // Café brand badge.
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              gradient: CafeGradients.coffee,
              boxShadow: [
                BoxShadow(
                  color: CafePalette.espresso.withValues(alpha: 0.35),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: const Icon(Icons.local_cafe_rounded,
                size: 19, color: Colors.white),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              switchInCurve: Curves.easeOut,
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: SlideTransition(
                  position:
                      Tween(begin: const Offset(0, 0.15), end: Offset.zero)
                          .animate(anim),
                  child: child,
                ),
              ),
              child: Column(
                key: ValueKey(widget.title),
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: titleStyle,
                    textScaler: TextScaler.noScaling,
                  ),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: subtitleStyle,
                      textScaler: TextScaler.noScaling,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
      actions: [
        if (widget.actions != null) ...widget.actions!,
        // Signed-in identity: gradient initial + full name, so the avatar's
        // single letter is always in context (no lone "O" read as "0").
        Container(
          height: 36,
          padding: const EdgeInsets.only(left: 4, right: 10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: CafePalette.latte),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [CafePalette.coffee, CafePalette.caramel],
                  ),
                ),
                child: Text(
                  _initial,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                    color: Colors.white,
                  ),
                  textScaler: TextScaler.noScaling,
                ),
              ),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  widget.userName,
                  style: Theme.of(context).textTheme.labelLarge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 4),
        if (widget.onAsk != null)
          IconButton(
            tooltip: 'Ask the assistant',
            icon: const Icon(Icons.auto_awesome_outlined),
            onPressed: widget.onAsk,
          ),
        IconButton(
          tooltip: 'Log out (${widget.userName})',
          icon: const Icon(Icons.logout_rounded),
          onPressed: widget.onLogout,
        ),
        const SizedBox(width: 4),
      ],
    );
  }
}
