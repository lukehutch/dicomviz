import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../dicom/series.dart';
import '../render/transfer_function.dart';
import 'volume_view.dart';

/// Controls for the transfer function and rendering settings.
class TransferFunctionPanel extends StatelessWidget {
  const TransferFunctionPanel({
    super.key,
    required this.volume,
    required this.tf,
    required this.settings,
    required this.onChanged,
    required this.onReset,
    required this.onResetView,
  });

  final VolumeData volume;
  final TransferFunction tf;
  final RenderSettings settings;

  /// Called after [tf] was modified in place.
  final VoidCallback onChanged;

  /// Rebuild default bands with the given count and range.
  final void Function(int count, double from, double to) onReset;
  final VoidCallback onResetView;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lo = volume.minValue, hi = volume.maxValue;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('Rendering', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        SegmentedButton<RenderMode>(
          segments: const [
            ButtonSegment(value: RenderMode.surfaces, label: Text('Level sets')),
            ButtonSegment(value: RenderMode.volume, label: Text('Volume')),
          ],
          selected: {tf.mode},
          onSelectionChanged: (s) {
            tf.mode = s.first;
            onChanged();
          },
        ),
        Row(children: [
          const Text('Lighting'),
          const Spacer(),
          Switch(
            value: settings.shading,
            onChanged: (v) {
              settings.shading = v;
              settings.changed();
            },
          ),
        ]),
        Row(children: [
          const Text('Step'),
          Expanded(
            child: Slider(
              value: settings.stepVoxels,
              min: 0.25,
              max: 2,
              divisions: 7,
              label: '${settings.stepVoxels} voxel',
              onChanged: (v) {
                settings.stepVoxels = v;
                settings.changed();
              },
            ),
          ),
          SizedBox(width: 64, child: Text('${settings.stepVoxels} vox')),
        ]),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            icon: const Icon(Icons.center_focus_strong),
            label: const Text('Reset view'),
            onPressed: onResetView,
          ),
        ),
        const Divider(height: 24),
        Text('Visible densities', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        SizedBox(height: 90, child: _Histogram(volume: volume, tf: tf)),
        // The slider uses the same scale as the histogram: the GPU's 8-bit
        // codes, which give most of the width to tissue and bone.
        RangeSlider(
          values: RangeValues(volume.map.encode(tf.showMin).clamp(0, 255),
              volume.map.encode(tf.showMax).clamp(0, 255)),
          min: 0,
          max: 255,
          onChanged: (r) {
            tf.showMin = r.start <= 0 ? lo : volume.map.decode(r.start);
            tf.showMax = r.end >= 255 ? hi : volume.map.decode(r.end);
            onChanged();
          },
        ),
        Row(children: [
          Expanded(child: _NumberField(
            label: 'Hide below',
            value: tf.showMin,
            onSubmitted: (v) {
              tf.showMin = v.clamp(lo, tf.showMax);
              onChanged();
            },
          )),
          const SizedBox(width: 8),
          Expanded(child: _NumberField(
            label: 'Hide above',
            value: tf.showMax,
            onSubmitted: (v) {
              tf.showMax = v.clamp(tf.showMin, hi);
              onChanged();
            },
          )),
        ]),
        const Divider(height: 24),
        Row(children: [
          Text('Density bands', style: theme.textTheme.titleSmall),
          const Spacer(),
          TextButton(
            onPressed: () => _editBands(context),
            child: const Text('Edit bands…'),
          ),
        ]),
        Text(
          tf.mode == RenderMode.surfaces
              ? 'Opacity of the surface at each band\'s lower edge.'
              : 'Opacity per ${volumeOpacityDepth.round()} voxels of depth within each band.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        for (final b in tf.bands.reversed) _bandRow(context, b),
      ],
    );
  }

  Widget _bandRow(BuildContext context, Band b) {
    final hidden = !b.enabled || b.hi <= tf.showMin || b.lo >= tf.showMax;
    return Opacity(
      opacity: hidden ? 0.45 : 1,
      child: Row(children: [
        SizedBox(
          width: 28,
          child: Checkbox(
            value: b.enabled,
            visualDensity: VisualDensity.compact,
            onChanged: (v) {
              b.enabled = v ?? true;
              onChanged();
            },
          ),
        ),
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: b.color,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 92,
          child: Text('${b.lo.round()}–${b.hi.round()}',
              style: Theme.of(context).textTheme.bodySmall),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: b.color,
              thumbColor: b.color,
              trackHeight: 3,
              overlayShape: SliderComponentShape.noOverlay,
            ),
            child: Slider(
              value: b.opacity,
              onChanged: (v) {
                b.opacity = v;
                onChanged();
              },
            ),
          ),
        ),
        SizedBox(
          width: 34,
          child: Text(b.opacity.toStringAsFixed(2),
              style: Theme.of(context).textTheme.bodySmall),
        ),
      ]),
    );
  }

  Future<void> _editBands(BuildContext context) async {
    var count = tf.bands.length;
    var from = tf.bands.first.lo;
    var to = from + count * (tf.bands.first.hi - tf.bands.first.lo);
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Density bands'),
        content: SizedBox(
          width: 320,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _NumberField(label: 'Number of bands', value: count.toDouble(),
                onChanged: (v) => count = v.round().clamp(1, 32)),
            const SizedBox(height: 8),
            _NumberField(label: 'First band starts at', value: from,
                onChanged: (v) => from = v),
            const SizedBox(height: 8),
            _NumberField(label: 'Banding ends at', value: to,
                onChanged: (v) => to = v),
            const SizedBox(height: 8),
            Text('Bands have equal width between the two values; the last band '
                'also covers everything above. Colors and opacities are reset.',
                style: Theme.of(ctx).textTheme.bodySmall),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Apply')),
        ],
      ),
    );
    if (result == true && to > from) onReset(count, from, to);
  }
}

class _NumberField extends StatefulWidget {
  const _NumberField({required this.label, required this.value, this.onSubmitted, this.onChanged});
  final String label;
  final double value;
  final ValueChanged<double>? onSubmitted;
  final ValueChanged<double>? onChanged;

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final _c = TextEditingController(text: widget.value.round().toString());
  final _focus = FocusNode();

  @override
  void didUpdateWidget(_NumberField old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && old.value != widget.value) {
      _c.text = widget.value.round().toString();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: _c,
        focusNode: _focus,
        decoration: InputDecoration(labelText: widget.label, isDense: true,
            border: const OutlineInputBorder()),
        keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
        onChanged: (s) {
          final v = double.tryParse(s);
          if (v != null) widget.onChanged?.call(v);
        },
        onSubmitted: (s) {
          final v = double.tryParse(s);
          if (v != null) widget.onSubmitted?.call(v);
        },
      );
}

/// Log-scale histogram of densities, colored by band, with hidden ranges
/// dimmed.
class _Histogram extends StatelessWidget {
  const _Histogram({required this.volume, required this.tf});
  final VolumeData volume;
  final TransferFunction tf;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.infinite,
        painter: _HistogramPainter(volume, tf,
            Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.25)),
      );
}

class _HistogramPainter extends CustomPainter {
  _HistogramPainter(this.volume, this.tf, this.neutral);
  final VolumeData volume;
  final TransferFunction tf;
  final Color neutral;

  @override
  void paint(Canvas canvas, Size size) {
    // x axis uses the 8-bit code scale (see DensityMap).
    final lo = volume.minValue, hi = volume.maxValue;
    final map = volume.map;
    double xOf(double v) => map.encode(v) / 255 * size.width;
    final h = volume.histogram;
    var maxLog = 0.0;
    for (final c in h) {
      maxLog = math.max(maxLog, math.log(c + 1));
    }
    if (maxLog == 0) return;
    final paint = Paint();
    for (var c = 0; c < 256; c++) {
      final v0 = c == 0 ? lo : map.decode(c - 0.5);
      final v1 = c == 255 ? hi : map.decode(c + 0.5);
      final mid = map.decode(c.toDouble());
      final hgt = math.log(h[c] + 1) / maxLog * size.height;
      Color color = neutral;
      for (final b in tf.bands) {
        if (mid >= b.lo && mid <= b.hi) {
          if (b.enabled) color = b.color;
          break;
        }
      }
      if (mid < tf.showMin || mid > tf.showMax) color = neutral;
      paint.color = color;
      canvas.drawRect(
          Rect.fromLTRB(xOf(v0), size.height - hgt, math.max(xOf(v1), xOf(v0) + 1), size.height),
          paint);
    }
    // Shade hidden ranges.
    final shade = Paint()..color = Colors.black.withValues(alpha: 0.35);
    canvas.drawRect(Rect.fromLTRB(0, 0, xOf(tf.showMin), size.height), shade);
    canvas.drawRect(Rect.fromLTRB(xOf(tf.showMax), 0, size.width, size.height), shade);
  }

  @override
  bool shouldRepaint(_HistogramPainter old) => true;
}
