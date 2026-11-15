import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hiobuy_scanner/hiobuy_scanner.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DemoApp());
}

class DemoApp extends StatelessWidget {
  const DemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HIOBuy Scanner',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.teal, brightness: Brightness.dark, useMaterial3: true),
      home: const ScanPage(),
    );
  }
}

/// Region used by the demo: a wide band, the natural shape for 1D labels.
const _band = Rect.fromLTRB(0.06, 0.26, 0.94, 0.50);

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  late final ScannerController _controller = ScannerController(
    // Whole frame, 1080p: point roughly at a label from arm's length; the code
    // nearest the centre is picked.
    config: const ScannerConfig(
      resolution: ScanResolution.fhd1080,
      feedback: ScanFeedback(vibrate: true, beep: true),
    ),
  );
  StreamSubscription<ScanResult>? _sub;
  Timer? _statsTimer;
  Timer? _flashTimer;

  final List<ScanResult> _history = [];
  ScannerStats _stats = const ScannerStats();
  ScanResult? _last;
  bool _flash = false;
  Offset? _focusPoint;
  String? _startError;

  ScannerConfig get _config => _controller.config;

  @override
  void initState() {
    super.initState();
    _sub = _controller.results.listen(_onResult);
    _statsTimer = Timer.periodic(const Duration(milliseconds: 500), (_) => _refreshStats());
    _start();
  }

  @override
  void dispose() {
    _statsTimer?.cancel();
    _flashTimer?.cancel();
    _sub?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() => _startError = null);
    try {
      await _controller.start();
    } on ScannerException catch (e) {
      if (mounted) setState(() => _startError = e.code);
    }
  }

  void _onResult(ScanResult r) {
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 180), () {
      if (mounted) setState(() => _flash = false);
    });
    setState(() {
      _last = r;
      _history.add(r);
      _flash = true;
    });
  }

  Future<void> _refreshStats() async {
    if (!_controller.state.value.isCameraActive) return;
    final s = await _controller.getStats();
    if (mounted) setState(() => _stats = s);
  }

  Future<void> _apply(ScannerConfig config) async {
    await _controller.updateConfig(config);
    if (mounted) setState(() {});
  }

  Future<void> _setMode(ScanMode mode) async {
    await _apply(_config.copyWith(mode: mode));
    await _controller.resume();
  }

  void _clear() {
    setState(() {
      _history.clear();
      _last = null;
    });
    _controller.resetDedupe();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: ValueListenableBuilder<ScannerState>(
        valueListenable: _controller.state,
        builder: (context, state, _) {
          return Stack(
            fit: StackFit.expand,
            children: [
              ScannerView(
                controller: _controller,
                onTapFocus: _showFocus,
                placeholder: _Placeholder(state: state, error: _startError, controller: _controller, onRetry: _start),
              ),
              if (_focusPoint != null) _FocusRing(point: _focusPoint!),
              IgnorePointer(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 80),
                  decoration: BoxDecoration(
                    border: Border.all(color: _flash ? Colors.greenAccent : Colors.transparent, width: 8),
                  ),
                ),
              ),
              SafeArea(
                child: Column(
                  children: [
                    _topBar(state),
                    const Spacer(),
                    _bottomPanel(state),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showFocus(Offset p) {
    setState(() => _focusPoint = p);
    Timer(const Duration(milliseconds: 700), () {
      if (mounted && _focusPoint == p) setState(() => _focusPoint = null);
    });
  }

  Widget _topBar(ScannerState state) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          SegmentedButton<ScanMode>(
            showSelectedIcon: false,
            style: SegmentedButton.styleFrom(
              backgroundColor: Colors.black54,
              visualDensity: VisualDensity.compact,
            ),
            segments: const [
              ButtonSegment(value: ScanMode.single, label: Text('单次')),
              ButtonSegment(value: ScanMode.continuous, label: Text('连续')),
            ],
            selected: {_config.mode},
            onSelectionChanged: (s) => _setMode(s.first),
          ),
          const Spacer(),
          IconButton.filledTonal(
            tooltip: '条码格式与设置',
            onPressed: _openSettings,
            icon: const Icon(Icons.tune),
          ),
          IconButton.filledTonal(
            tooltip: '手电筒',
            onPressed: state.hasTorch && state.isCameraActive ? _controller.toggleTorch : null,
            icon: Icon(state.torchOn ? Icons.flashlight_on : Icons.flashlight_off),
          ),
        ],
      ),
    );
  }

  Widget _bottomPanel(ScannerState state) {
    final single = _config.mode == ScanMode.single;
    final waiting = single && state.status == ScannerStatus.paused && state.pauseLevel == PauseLevel.results;
    final paused = state.status == ScannerStatus.paused && !waiting;
    final last = _last;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.all(8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.72), borderRadius: BorderRadius.circular(12)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  last?.value ?? '将相机对着条码即可',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: last == null ? Colors.white54 : Colors.white,
                  ),
                ),
              ),
              if (last != null)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Chip(label: Text(last.format.name), visualDensity: VisualDensity.compact),
                ),
            ],
          ),
          if (last != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '本次  帧→结果 ${_ms(last.timings.nativeTotalMs)} · 解码 ${_ms(last.timings.decodeMs)} · 到 Dart ${_ms(last.timings.dartDeliveryMs)}',
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
            ),
          const SizedBox(height: 8),
          _statsGrid(state),
          const SizedBox(height: 8),
          Row(
            children: [
              if (waiting)
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _controller.resume,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('继续扫描'),
                  ),
                )
              else
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: !state.isCameraActive
                        ? _start
                        : paused
                            ? _controller.resume
                            : () => _controller.pause(PauseLevel.analysis),
                    icon: Icon(!state.isCameraActive || paused ? Icons.play_arrow : Icons.pause),
                    label: Text(!state.isCameraActive ? '启动相机' : (paused ? '恢复' : '暂停')),
                  ),
                ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: '停止相机（下次为热启动）',
                onPressed: state.isCameraActive ? _controller.stop : null,
                icon: const Icon(Icons.stop),
              ),
              IconButton.filledTonal(
                tooltip: '扫描记录',
                onPressed: _openHistory,
                icon: Badge(
                  isLabelVisible: _history.isNotEmpty,
                  label: Text('${_history.length}'),
                  child: const Icon(Icons.list_alt),
                ),
              ),
              IconButton.filledTonal(tooltip: '清空统计', onPressed: _clear, icon: const Icon(Icons.delete_outline)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statsGrid(ScannerState state) {
    final total = _percentiles(_history.map((r) => r.timings.nativeTotalMs));
    final decode = _percentiles(_history.map((r) => r.timings.decodeMs));
    final dart = _percentiles(_history.map((r) => r.timings.dartDeliveryMs));
    final startup = state.startup;
    final cells = <(String, String)>[
      ('扫码次数', '${_history.length}'),
      ('重复过滤', '${_stats.duplicatesSuppressed}'),
      ('区域外', '${_stats.outsideRegion}'),
      ('帧→结果 P50/P95', total),
      ('解码 P50/P95', decode),
      ('到 Dart P50/P95', dart),
      (
        startup == null ? '相机启动' : (startup.warm ? '热启动 会话/首帧' : '冷启动 会话/首帧'),
        startup == null ? '–' : '${_ms(startup.sessionReadyMs)} / ${_ms(startup.firstFrameMs)}',
      ),
      ('分析帧数', _stats.framesAnalyzed == 0 ? '–' : '${_stats.framesAnalyzed}'),
      ('忙时丢弃', '${_stats.droppedWhileBusy}'),
    ];
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 2.9,
      padding: EdgeInsets.zero,
      children: [
        for (final (label, value) in cells)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(label, style: const TextStyle(fontSize: 11, color: Colors.white60)),
              Text(
                value,
                style: const TextStyle(fontSize: 14, fontFeatures: [FontFeature.tabularFigures()]),
              ),
            ],
          ),
      ],
    );
  }

  static String _ms(double? v) => v == null ? '–' : '${v.toStringAsFixed(v < 10 ? 1 : 0)}ms';

  /// "P50/P95" over the non-null samples.
  static String _percentiles(Iterable<double?> samples) {
    final v = samples.whereType<double>().toList()..sort();
    if (v.isEmpty) return '–';
    double p(double q) => v[((v.length - 1) * q).round()];
    return '${p(0.5).toStringAsFixed(0)} / ${p(0.95).toStringAsFixed(0)}ms';
  }

  void _openSettings() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) {
          Future<void> apply(ScannerConfig c) async {
            await _apply(c);
            setSheet(() {});
          }

          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('条码格式', style: Theme.of(context).textTheme.titleSmall),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final f in BarcodeFormat.values)
                        FilterChip(
                          label: Text(f.name),
                          selected: _config.formats.contains(f),
                          onSelected: (on) {
                            final next = {..._config.formats};
                            on ? next.add(f) : next.remove(f);
                            if (next.isNotEmpty) apply(_config.copyWith(formats: next));
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text('分析分辨率', style: Theme.of(context).textTheme.titleSmall),
                  SegmentedButton<ScanResolution>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: ScanResolution.sd540, label: Text('540p')),
                      ButtonSegment(value: ScanResolution.hd720, label: Text('720p')),
                      ButtonSegment(value: ScanResolution.fhd1080, label: Text('1080p')),
                    ],
                    selected: {_config.resolution},
                    onSelectionChanged: (s) => apply(_config.copyWith(resolution: s.first)),
                  ),
                  const SizedBox(height: 12),
                  Text('去重窗口 ${_config.dedupeWindow.inMilliseconds} ms', style: Theme.of(context).textTheme.titleSmall),
                  Slider(
                    value: _config.dedupeWindow.inMilliseconds.toDouble(),
                    max: 5000,
                    divisions: 20,
                    onChanged: (v) => apply(_config.copyWith(dedupeWindow: Duration(milliseconds: v.round()))),
                  ),
                  Text(
                    '变焦 ${_config.zoom == null ? '自动' : '${_config.zoom!.toStringAsFixed(1)}x'}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  Slider(
                    value: _config.zoom ?? 0.9,
                    min: 0.9,
                    max: 4,
                    divisions: 31,
                    onChanged: (v) => apply(v < 1 ? _config.copyWith(clearZoom: true) : _config.copyWith(zoom: v)),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('自动变焦（仅 Android）'),
                    subtitle: const Text('条码太小时自动放大'),
                    value: _config.autoZoom,
                    onChanged: (on) => apply(_config.copyWith(autoZoom: on)),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('两帧确认（仅 Android）'),
                    subtitle: const Text('连续两帧结果一致才上报，防误读'),
                    value: _config.confirmations > 1,
                    onChanged: (on) => apply(_config.copyWith(confirmations: on ? 2 : 1)),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('限定扫描区域'),
                    value: _config.scanRegion != null,
                    onChanged: (on) =>
                        apply(on ? _config.copyWith(scanRegion: _band) : _config.copyWith(clearScanRegion: true)),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('震动反馈'),
                    value: _config.feedback.vibrate,
                    onChanged: (on) =>
                        apply(_config.copyWith(feedback: ScanFeedback(vibrate: on, beep: _config.feedback.beep))),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('提示音'),
                    value: _config.feedback.beep,
                    onChanged: (on) =>
                        apply(_config.copyWith(feedback: ScanFeedback(vibrate: _config.feedback.vibrate, beep: on))),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _openHistory() {
    final items = _history.reversed.toList();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.7,
          child: Column(
            children: [
              ListTile(
                title: Text('扫描记录（${items.length}）'),
                trailing: TextButton.icon(
                  onPressed: items.isEmpty ? null : _copyCsv,
                  icon: const Icon(Icons.copy),
                  label: const Text('复制 CSV'),
                ),
              ),
              Expanded(
                child: items.isEmpty
                    ? const Center(child: Text('暂无记录'))
                    : ListView.separated(
                        itemCount: items.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final r = items[i];
                          final t = r.timestamp;
                          String two(int n) => n.toString().padLeft(2, '0');
                          return ListTile(
                            dense: true,
                            title: Text(r.value),
                            subtitle: Text(
                              '${r.format.name} · ${two(t.hour)}:${two(t.minute)}:${two(t.second)} · '
                              '帧→结果 ${_ms(r.timings.nativeTotalMs)} · 解码 ${_ms(r.timings.decodeMs)}',
                            ),
                            trailing: Text('#${items.length - i}'),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _copyCsv() async {
    final b = StringBuffer('index,timestamp,platform,format,value,frame_age_ms,decode_ms,native_total_ms,dart_delivery_ms\n');
    for (var i = 0; i < _history.length; i++) {
      final r = _history[i];
      String n(double? v) => v?.toStringAsFixed(2) ?? '';
      final value = '"${r.value.replaceAll('"', '""')}"';
      b.writeln(
        '${i + 1},${r.timestamp.toIso8601String()},${r.platform},${r.format.name},$value,'
        '${n(r.timings.frameAgeMs)},${n(r.timings.decodeMs)},${n(r.timings.nativeTotalMs)},${n(r.timings.dartDeliveryMs)}',
      );
    }
    await Clipboard.setData(ClipboardData(text: b.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已复制 ${_history.length} 条记录')));
  }
}

class _FocusRing extends StatelessWidget {
  const _FocusRing({required this.point});

  final Offset point;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Align(
        alignment: Alignment(point.dx * 2 - 1, point.dy * 2 - 1),
        child: Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.amberAccent, width: 2),
          ),
        ),
      ),
    );
  }
}

/// Shown instead of the preview while the camera is not active.
class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.state, required this.error, required this.controller, required this.onRetry});

  final ScannerState state;
  final String? error;
  final ScannerController controller;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (state.status == ScannerStatus.starting) {
      return const Center(child: CircularProgressIndicator());
    }
    final denied = error == ScannerException.permissionDenied;
    final String message;
    if (denied) {
      message = state.permission == CameraPermission.restricted ? '此设备限制了相机使用' : '需要相机权限才能扫码';
    } else if (state.status == ScannerStatus.error) {
      message = '相机启动失败：${state.error?.message ?? error ?? ''}';
    } else {
      message = '相机已停止';
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 0, 32, 160),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(denied ? Icons.no_photography : Icons.videocam_off, size: 48, color: Colors.white54),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            if (denied && state.permission != CameraPermission.denied)
              FilledButton(onPressed: controller.openAppSettings, child: const Text('打开系统设置')),
            TextButton(onPressed: onRetry, child: Text(denied ? '重新检查权限' : '重试')),
          ],
        ),
      ),
    );
  }
}
