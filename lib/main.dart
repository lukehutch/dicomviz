import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'dicom/series.dart';
import 'render/transfer_function.dart';
import 'ui/image_view.dart';
import 'ui/tf_panel.dart';
import 'ui/volume_view.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.environment['DICOMVIZ_PERF'] != null) _logFrameTimes();
  runApp(DicomVizApp(initialFolder: args.isNotEmpty ? args.first : _lastFolder()));
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
    stdout.writeln('frames: ${times.length}  build ${avg((x) => x.buildDuration).toStringAsFixed(1)} ms'
        '  raster ${avg((x) => x.rasterDuration).toStringAsFixed(1)} ms');
    times.clear();
  });
}

/// The last opened folder is kept in ~/.config/dicomviz/last_folder.
File get _lastFolderFile {
  final config = Platform.environment['XDG_CONFIG_HOME'] ??
      '${Platform.environment['HOME']}/.config';
  return File('$config/dicomviz/last_folder');
}

String? _lastFolder() {
  try {
    final p = _lastFolderFile.readAsStringSync().trim();
    return p.isNotEmpty && Directory(p).existsSync() ? p : null;
  } catch (_) {
    return null;
  }
}

void _saveLastFolder(String p) {
  try {
    _lastFolderFile
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(p);
  } catch (_) {}
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

  int _loadToken = 0;

  @override
  void initState() {
    super.initState();
    if (widget.initialFolder != null) _openFolder(widget.initialFolder!);
  }

  Future<void> _pickFolder() async {
    final p = await getDirectoryPath(initialDirectory: _folder);
    if (p != null) _openFolder(p);
  }

  Future<void> _openFolder(String p) async {
    setState(() {
      _folder = p;
      _scanning = true;
      _series = [];
      _error = null;
    });
    try {
      final s = await scanFolder(p);
      _saveLastFolder(p);
      setState(() {
        _series = s;
        _scanning = false;
      });
      if (s.isNotEmpty) _select(s.first);
    } catch (e) {
      setState(() {
        _scanning = false;
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
    final isVolume = _selected?.isVolume ?? false;
    return Scaffold(
      body: Row(children: [
        SizedBox(width: 260, child: _seriesPanel(theme)),
        const VerticalDivider(width: 1),
        Expanded(child: _viewer(theme)),
        if (isVolume && _volume != null && _tf != null && _progress == null) ...[
          const VerticalDivider(width: 1),
          SizedBox(
            width: 330,
            child: TransferFunctionPanel(
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
            ),
          ),
        ],
      ]),
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

  Widget _viewer(ThemeData theme) {
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
    if (_stack != null) return ImageStackView(stack: _stack!);
    return const SizedBox.shrink();
  }
}
