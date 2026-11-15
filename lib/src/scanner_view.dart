import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'scanner_controller.dart';
import 'types.dart';

/// Native camera preview for a [ScannerController].
///
/// Android renders the CameraX preview into a texture; iOS embeds an
/// `AVCaptureVideoPreviewLayer`. Frames never pass through Dart. The preview
/// always fills the view, cropping as needed.
class ScannerView extends StatefulWidget {
  const ScannerView({
    super.key,
    required this.controller,
    this.tapToFocus = true,
    this.showScanRegion = true,
    this.highlightResults = true,
    this.overlay,
    this.placeholder,
    this.onTapFocus,
  });

  final ScannerController controller;
  final bool tapToFocus;

  /// Outlines [ScannerConfig.scanRegion] when one is set.
  final bool showScanRegion;

  /// Briefly outlines each reported barcode where it was found, so the
  /// operator sees which one was picked.
  final bool highlightResults;

  /// Maps a rectangle in the upright camera image (fractions 0–1) to pixels in
  /// a view showing that image with centre-crop scaling.
  static Rect imageRectToView(Rect box, Size imageSize, Size viewSize) {
    if (imageSize.isEmpty || viewSize.isEmpty) {
      return Rect.fromLTRB(
        box.left * viewSize.width,
        box.top * viewSize.height,
        box.right * viewSize.width,
        box.bottom * viewSize.height,
      );
    }
    final scale = (viewSize.width / imageSize.width) > (viewSize.height / imageSize.height)
        ? viewSize.width / imageSize.width
        : viewSize.height / imageSize.height;
    final shownW = imageSize.width * scale;
    final shownH = imageSize.height * scale;
    final dx = (shownW - viewSize.width) / 2;
    final dy = (shownH - viewSize.height) / 2;
    return Rect.fromLTRB(
      box.left * shownW - dx,
      box.top * shownH - dy,
      box.right * shownW - dx,
      box.bottom * shownH - dy,
    );
  }

  /// Drawn above the preview and below the tap layer.
  final Widget? overlay;

  /// Shown while the camera is not active.
  final Widget? placeholder;

  /// Called with the tap position (fractions of the view) after focusing.
  final ValueChanged<Offset>? onTapFocus;

  @override
  State<ScannerView> createState() => _ScannerViewState();
}

class _ScannerViewState extends State<ScannerView> {
  Size? _reported;
  StreamSubscription<ScanResult>? _resultSub;
  Timer? _highlightTimer;
  Rect? _highlight;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  void _listen() {
    _resultSub?.cancel();
    _resultSub = widget.controller.isDisposed ? null : widget.controller.results.listen(_onResult);
  }

  void _onResult(ScanResult r) {
    if (!widget.highlightResults || r.boundingBox == null || !mounted) return;
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _highlight = null);
    });
    setState(() => _highlight = r.boundingBox);
  }

  @override
  void dispose() {
    _resultSub?.cancel();
    _highlightTimer?.cancel();
    super.dispose();
  }

  void _reportSize(Size size) {
    if (_reported == size) return;
    _reported = size;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !widget.controller.isDisposed) widget.controller.attachViewSize(size);
    });
  }

  @override
  void didUpdateWidget(ScannerView old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      _reported = null;
      _highlight = null;
      _listen();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final size = constraints.biggest;
      if (size.isFinite) _reportSize(size);
      return ValueListenableBuilder<ScannerState>(
        valueListenable: widget.controller.state,
        builder: (context, state, _) {
          final region = widget.controller.config.scanRegion;
          return ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: Colors.black),
                if (state.isCameraActive) _preview(state) else if (widget.placeholder != null) widget.placeholder!,
                if (widget.showScanRegion && region != null)
                  IgnorePointer(child: CustomPaint(painter: _RegionPainter(region))),
                if (_highlight != null && state.isCameraActive)
                  IgnorePointer(
                    child: CustomPaint(
                      painter: _HighlightPainter(
                        ScannerView.imageRectToView(_highlight!, state.previewSize ?? Size.zero, size),
                      ),
                    ),
                  ),
                if (widget.overlay != null) widget.overlay!,
                if (widget.tapToFocus)
                  GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTapUp: (d) {
                      if (size.isEmpty) return;
                      final p = Offset(d.localPosition.dx / size.width, d.localPosition.dy / size.height);
                      widget.controller.focusAt(p);
                      widget.onTapFocus?.call(p);
                    },
                  ),
              ],
            ),
          );
        },
      );
    });
  }

  Widget _preview(ScannerState state) {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return const UiKitView(
        viewType: 'hiobuy_scanner/preview',
        creationParamsCodec: StandardMessageCodec(),
        hitTestBehavior: PlatformViewHitTestBehavior.transparent,
      );
    }
    final id = state.textureId;
    final ps = state.previewSize;
    if (id == null || ps == null || ps.isEmpty) return const SizedBox.shrink();
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(width: ps.width, height: ps.height, child: Texture(textureId: id)),
    );
  }
}

class _RegionPainter extends CustomPainter {
  _RegionPainter(this.region);

  final Rect region;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTRB(
      region.left * size.width,
      region.top * size.height,
      region.right * size.width,
      region.bottom * size.height,
    );
    final shade = Paint()..color = const Color(0x73000000);
    canvas.drawPath(
      Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & size), Path()..addRect(r)),
      shade,
    );
    canvas.drawRect(
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0xFFFFFFFF),
    );
  }

  @override
  bool shouldRepaint(_RegionPainter old) => old.region != region;
}

class _HighlightPainter extends CustomPainter {
  _HighlightPainter(this.rect);

  final Rect rect;

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(rect.inflate(6), const Radius.circular(8));
    canvas.drawRRect(r, Paint()..color = const Color(0x3300E676));
    canvas.drawRRect(
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = const Color(0xFF00E676),
    );
  }

  @override
  bool shouldRepaint(_HighlightPainter old) => old.rect != rect;
}
