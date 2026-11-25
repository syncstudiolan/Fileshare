import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Thumbnail decode policy shared by Android, iPhone, Windows and macOS.
///
/// The feed is a lazily built sliver, so this widget is only mounted for the
/// currently visible card or a tiny cache margin. During a fling, decode
/// at most 88 physical pixels; do not start a high-res decode for cards the
/// user flies past. Once scrolling has been idle for 140 ms, upgrade only
/// thumbnails that are *still mounted*. Full originals are loaded by the
/// tap-to-open viewer, never by the scrolling dashboard.
class DashboardThumbnail extends StatefulWidget {
  const DashboardThumbnail({
    super.key,
    required this.path,
    required this.scrolling,
    this.fallbackIcon = Icons.image_not_supported_outlined,
  });
  final String path;
  final ValueListenable<bool> scrolling;
  final IconData fallbackIcon;

  @override
  State<DashboardThumbnail> createState() => _DashboardThumbnailState();
}

class _DashboardThumbnailState extends State<DashboardThumbnail> {
  Timer? _idleTimer;
  bool _sharp = false;

  @override
  void initState() {
    super.initState();
    widget.scrolling.addListener(_scrollChanged);
    _scrollChanged();
  }

  @override
  void didUpdateWidget(DashboardThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrolling != widget.scrolling) {
      oldWidget.scrolling.removeListener(_scrollChanged);
      widget.scrolling.addListener(_scrollChanged);
    }
    if (oldWidget.path != widget.path) _sharp = false;
    _scrollChanged();
  }

  void _scrollChanged() {
    _idleTimer?.cancel();
    if (_sharp || widget.scrolling.value) return;
    // A fling starts/cancels this timer with no heavy disk/image work.
    _idleTimer = Timer(const Duration(milliseconds: 140), () {
      if (!mounted || widget.scrolling.value) return;
      setState(() => _sharp = true);
    });
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    widget.scrolling.removeListener(_scrollChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(12),
    child: Image.file(
      File(widget.path),
      fit: BoxFit.cover,
      cacheWidth: _sharp ? 240 : 88,
      filterQuality: FilterQuality.low,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => Center(
        child: Icon(widget.fallbackIcon, color: Colors.white70, size: 34)),
    ),
  );
}
