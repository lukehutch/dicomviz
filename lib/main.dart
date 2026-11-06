import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'dicom/series.dart';
import 'platform/platform.dart';
import 'platform/pick_folder.dart';
import 'render/transfer_function.dart';
import 'ui/image_view.dart';
import 'ui/tf_panel.dart';
import 'ui/volume_view.dart';

/// Below this width the side panels would leave too little of the view, so
/// the controls move to a floating panel opened from a menu button.
const sidePanelsMinWidth = 1000.0;

/// A folder to open when none is given or saved. Empty unless a demo build
/// sets it with `--dart-define=DICOMVIZ_FOLDER=<path>`.
const _defaultFolder = String.fromEnvironment('DICOMVIZ_FOLDER');

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  // Right-drag pans the view.
  if (kIsWeb) BrowserContextMenu.disableContextMenu();
  if (logFrameTimes) _logFrameTimes();
  runApp(DicomVizApp(
    initialFolder: args.isNotEmpty
        ? args.first
        : lastFolder() ?? (_defaultFolder.isEmpty ? null : _defaultFolder),
  ));
}

/// Prints average build and raster times per second of rendering.
void _logFrameTimes() {
  final times = <FrameTiming>[];
  SchedulerBinding.instance.addTimingsCallback((t) {
    times.addAll(t);
    final span = times.last.timestampInMicroseconds(ui.FramePhase.rasterFinish) -
        times.first.timestampInMicroseconds(ui.FramePhase.buildStart);
    if (span < 1000000) return;
    double avg(Duration Function(FrameTiming) f) =>
        times.map((x) => f(x).inMicroseconds).reduce((a, b) => a + b) / times.length / 1000;
    debugPrint('frames: ${times.length}  build ${avg((x) => x.buildDuration).toStringAsFixed(1)} ms'
        '  raster ${avg((x) => x.rasterDuration).toStringAsFixed(1)} ms');
    times.clear();
  });
}

class DicomVizApp extends StatelessWidget {
  const DicomVizApp({super.key, this.initialFolder});
  final String? initialFolder;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'DICOM Viewer',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.indigo, brightness: Brightness.dark),
          visualDensity: VisualDensity.compact,
        ),
        home: ViewerPage(initialFolder: initialFolder),
      );
}

class ViewerPage extends StatefulWidget {
  const ViewerPage({super.key, this.initialFolder});
  final String? initialFolder;

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  String? _folder;
  List<SeriesInfo> _series = [];
  bool _scanning = false;
  SeriesInfo? _selected;
  String? _error;

  // Volume state.
  VolumeData? _volume;
  ui.Image? _volumeImage;
  TransferFunction? _tf;
  int _tfVersion = 0;
  final _settings = RenderSettings();
  double? _progress;
  String _progressText = '';
  final _viewKey = GlobalKey<VolumeViewState>();

  // 2D state.
  ImageStack? _stack;
  final _stackKey = GlobalKey();

  // Floating panel in the narrow layout.
  bool _panelOpen = true;
  bool _panelShowsRendering = true;

  /// The panel has slid out of view after closing, and is offstage.
  bool _panelSlidOut = false;

  int _loadToken = 0;

  @override
  void initState() {
    super.initState();
    if (widget.initialFolder != null) {
      // The panel opens again below if the folder can't be shown.
      _panelOpen = false;
      listFolder(widget.initialFolder!).then(_openFolder, onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _panelOpen = true;
          _error = 'Could not read folder: $e';
        });
      });
    }
  }

  Future<void> _pickFolder() async {
    final f = await pickFolder(_folder);
    if (f != null) _openFolder(f);
  }

  Future<void> _openFolder(PickedFolder folder) async {
    setState(() {
      _folder = folder.name;
      _scanning = true;
      _series = [];
      _error = null;
    });
    try {
      final s = await scanFiles(folder.files);
      saveLastFolder(folder.name);
      setState(() {
        _series = s;
        _scanning = false;
        if (s.isEmpty) _panelOpen = true;
      });
      if (s.isNotEmpty) _select(s.first);
    } catch (e) {
      setState(() {
        _scanning = false;
        _panelOpen = true;
        _error = 'Could not read folder: $e';
      });
    }
  }

  Future<void> _select(SeriesInfo s) async {
    final token = ++_loadToken;
    setState(() {
      _selected = s;
      _error = null;
      _stack = null;
      _panelOpen = false;
      _progress = 0;
      _progressText = 'Loading';
    });
    try {
      if (s.isVolume) {
        final v = await loadVolume(s, onProgress: (f, t) {
          if (token == _loadToken && mounted) {
            setState(() {
              _progress = f;
              _progressText = t;
            });
          }
        });
        if (token != _loadToken) return;
        setState(() => _progressText = 'Uploading to GPU');
        final img = await imageFromRgba(v.atlas, v.atlasWidth, v.atlasHeight);
        if (token != _loadToken) {
          img.dispose();
          return;
        }
        final old = _volumeImage;
        setState(() {
          _volume = v;
          _volumeImage = img;
          _tf = _defaultTf(v);
          _tfVersion++;
          _progress = null;
        });
        old?.dispose();
      } else {
        final st = await openImageStack(s);
        if (token != _loadToken) return;
        setState(() {
          _stack = st;
          _progress = null;
        });
      }
    } catch (e) {
      if (token != _loadToken) return;
      setState(() {
        _progress = null;
        _error = 'Could not load series: $e';
      });
    }
  }

  TransferFunction _defaultTf(VolumeData v, {int count = 12, double from = -400, double to = 3200}) =>
      TransferFunction.rainbow(
        from: from,
        to: to,
        count: count,
        dataMin: v.minValue,
        dataMax: v.maxValue,
      );

  void _tfChanged() => setState(() => _tfVersion++);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, c) => c.maxWidth >= sidePanelsMinWidth
            ? _wideLayout(theme)
            : _narrowLayout(theme, c),
      ),
    );
  }

  Widget _wideLayout(ThemeData theme) {
    final rendering = _renderingPanel();
    return Row(children: [
      SizedBox(width: 260, child: _seriesPanel(theme)),
      const VerticalDivider(width: 1),
      Expanded(child: _viewer(theme, wide: true)),
      if (rendering != null) ...[
        const VerticalDivider(width: 1),
        SizedBox(width: 330, child: rendering),
      ],
    ]);
  }

  /// The view fills the window. The panel does not block it, so the effect
  /// of a change can be seen while making it.
  Widget _narrowLayout(ThemeData theme, BoxConstraints c) {
    final rendering = _renderingPanel();
    final landscape = c.maxWidth > c.maxHeight;
    final shadeHeight = c.maxHeight * 0.55;
    const panelWidth = 340.0;
    // Slide the 3D view so its center stays in the middle of the part of the
    // window the panel leaves free. Moving it keeps the zoom and fills that part.
    final inset = MediaQuery.paddingOf(context);
    final slide = !_panelOpen || !(_selected?.isVolume ?? false)
        ? Offset.zero
        : landscape
            ? Offset(-(panelWidth + 16 + inset.right) / 2 / c.maxWidth, 0)
            : Offset(0, -(shadeHeight + 16 + inset.bottom) / 2 / c.maxHeight);
    return Stack(children: [
      Positioned.fill(
        child: AnimatedSlide(
          offset: slide,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          // A tap in the view closes the panel; a drag turns the view and
          // leaves it open.
          child: GestureDetector(
            onTap: _panelOpen ? () => setState(() => _panelOpen = false) : null,
            child: _viewer(theme, wide: false),
          ),
        ),
      ),
      // The panel slides in from the bottom, or from the right in landscape,
      // with the view. It takes no input while it slides out, and is
      // offstage once out of view.
      Offstage(
        offstage: !_panelOpen && _panelSlidOut,
        child: SafeArea(
          child: Align(
            alignment: landscape ? Alignment.bottomRight : Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.fromLTRB(8, landscape ? 56 : 8, 8, 8),
              child: IgnorePointer(
                ignoring: !_panelOpen,
                child: AnimatedSlide(
                  offset: _panelOpen
                      ? Offset.zero
                      : (landscape ? const Offset(1.2, 0) : const Offset(0, 1.2)),
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  onEnd: () => setState(() => _panelSlidOut = !_panelOpen),
                  child: SizedBox(
                    width: landscape ? panelWidth : double.infinity,
                    height: landscape ? double.infinity : shadeHeight,
                    child: Material(
                      color: theme.colorScheme.surfaceContainer,
                      elevation: 8,
                      borderRadius: BorderRadius.circular(12),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (rendering != null)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                              child: SegmentedButton<bool>(
                                segments: const [
                                  ButtonSegment(value: false, label: Text('Series')),
                                  ButtonSegment(value: true, label: Text('Rendering')),
                                ],
                                selected: {_panelShowsRendering},
                                showSelectedIcon: false,
                                onSelectionChanged: (s) =>
                                    setState(() => _panelShowsRendering = s.first),
                              ),
                            ),
                          Expanded(
                            child: rendering != null && _panelShowsRendering
                                ? rendering
                                : _seriesPanel(theme),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      SafeArea(
        child: Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: IconButton.filledTonal(
              icon: Icon(_panelOpen ? Icons.close : Icons.menu,
                  semanticLabel: _panelOpen ? 'Hide controls' : 'Show controls'),
              onPressed: () => setState(() => _panelOpen = !_panelOpen),
            ),
          ),
        ),
      ),
    ]);
  }

  /// Controls for the current volume, or null if none is shown.
  Widget? _renderingPanel() {
    final isVolume = _selected?.isVolume ?? false;
    if (!isVolume || _volume == null || _tf == null || _progress != null) return null;
    return TransferFunctionPanel(
      volume: _volume!,
      tf: _tf!,
      settings: _settings,
      onChanged: _tfChanged,
      onReset: (count, from, to) {
        final mode = _tf!.mode;
        setState(() {
          _tf = _defaultTf(_volume!, count: count, from: from, to: to)..mode = mode;
          _tfVersion++;
        });
      },
      onResetView: () => _viewKey.currentState?.resetView(),
    );
  }

  Widget _seriesPanel(ThemeData theme) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: FilledButton.tonalIcon(
              icon: const Icon(Icons.folder_open),
              label: const Text('Open folder…'),
              onPressed: _pickFolder,
            ),
          ),
          if (_folder != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(_folder!, style: theme.textTheme.bodySmall,
                  maxLines: 3, overflow: TextOverflow.ellipsis),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Text('Series', style: theme.textTheme.titleSmall),
          ),
          if (_scanning) const LinearProgressIndicator(),
          Expanded(
            child: ListView(children: [
              for (final s in _series)
                ListTile(
                  selected: identical(s, _selected),
                  leading: Icon(s.isVolume ? Icons.view_in_ar : Icons.image_outlined),
                  title: Text(s.description.isEmpty ? 'Series ${s.seriesNumber}' : s.description),
                  subtitle: Text('${s.modality} · #${s.seriesNumber} · ${s.sizeLabel}'
                      '${s.isVolume ? '' : s.frames > 1 ? ' frames' : ''}'),
                  onTap: () => _select(s),
                ),
            ]),
          ),
        ],
      );

  Widget _viewer(ThemeData theme, {required bool wide}) {
    if (_error != null) {
      return Center(child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)));
    }
    if (_selected == null) {
      return Center(
        child: Text(_scanning ? 'Scanning…' : 'Open a folder containing DICOM files.',
            style: theme.textTheme.bodyLarge),
      );
    }
    if (_progress != null) {
      return Center(
        child: SizedBox(
          width: 320,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            LinearProgressIndicator(value: _progress == 0 ? null : _progress),
            const SizedBox(height: 8),
            Text(_progressText),
          ]),
        ),
      );
    }
    if (_selected!.isVolume && _volume != null && _volumeImage != null && _tf != null) {
      return Stack(children: [
        VolumeView(
          key: _viewKey,
          volume: _volume!,
          volumeImage: _volumeImage!,
          tf: _tf!,
          tfVersion: _tfVersion,
          settings: _settings,
        ),
        if (wide)
          Positioned(
            left: 12,
            bottom: 8,
            child: Text(
              'Left drag: rotate · Right/middle or Shift+drag: pan · '
              'Scroll or Ctrl+drag: zoom · Double-click: reset',
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.white54),
            ),
          ),
      ]);
    }
    if (_stack != null) {
      return ImageStackView(key: _stackKey, stack: _stack!, reserveTopRight: !wide);
    }
    return const SizedBox.shrink();
  }
}
