import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/video/anime4k.dart';
import 'package:venera/foundation/video/player_service.dart';
import 'package:venera/utils/translations.dart';

class Anime4kStatusView extends StatelessWidget {
  const Anime4kStatusView({super.key, required this.player});

  final PlayerService player;

  String _label(Anime4kStatus status) {
    return switch (status.state) {
      Anime4kState.off => 'Off'.tl,
      Anime4kState.checking => 'Checking Anime4K render passes...'.tl,
      Anime4kState.inactive =>
        'Inactive: no Anime4K render passes detected'.tl,
      Anime4kState.unknown => 'Unable to verify Anime4K'.tl,
      Anime4kState.playToVerify => 'Play to verify Anime4K'.tl,
      Anime4kState.active when status.hasUpscale =>
        'Active: @n Anime4K render passes (including upscale)'.tlParams({
          'n': status.passCount,
        }),
      Anime4kState.active when status.canUpscale == false =>
        'Active: restore only; output is not over 1.2 times video size'.tl,
      Anime4kState.active =>
        'Active: @n Anime4K render passes (no upscale detected)'.tlParams({
          'n': status.passCount,
        }),
    };
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        player.anime4kStatus, player.anime4kOriginal,
      ]),
      builder: (context, _) {
        final status = player.anime4kStatus.value;
        final original = player.anime4kOriginal.value;
        if (player.anime4kPreset == Anime4kPreset.off && !original) {
          return Text('Off'.tl);
        }
        String size(int? w, int? h) =>
            w == null || h == null ? 'Unknown'.tl : '$w × $h';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(original ? 'Showing original'.tl : _label(status)),
            const SizedBox(height: 4),
            Text(
              'Video: @video · Output: @output · hwdec: @hwdec'.tlParams({
                'video': size(status.videoWidth, status.videoHeight),
                'output': size(status.outputWidth, status.outputHeight),
                'hwdec': status.hwdec?.isNotEmpty == true
                    ? status.hwdec! : 'Unknown'.tl,
              }),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        );
      },
    );
  }
}

class Anime4kPicker extends StatefulWidget {
  const Anime4kPicker({
    super.key,
    required this.player,
    required this.selected,
    required this.onSelected,
  });

  final PlayerService player;
  final Anime4kPreset selected;
  final Future<void> Function(Anime4kPreset) onSelected;

  @override
  State<Anime4kPicker> createState() => _Anime4kPickerState();
}

class _Anime4kPickerState extends State<Anime4kPicker>
    with WidgetsBindingObserver {
  late Anime4kPreset selected = widget.selected;
  bool held = false;
  bool applying = false;
  int? pointer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  void _release() {
    if (!held) {
      return;
    }
    held = false;
    pointer = null;
    unawaited(widget.player.showAnime4kOriginal(false));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _release();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final preset in Anime4kPreset.values)
            OptionRow(
              text: preset.label.tl,
              selected: selected == preset,
              onTap: () async {
                if (applying) {
                  return;
                }
                _release();
                setState(() => applying = true);
                try {
                  await widget.onSelected(preset);
                  if (mounted) {
                    setState(() => selected = widget.player.anime4kPreset);
                  }
                } finally {
                  if (mounted) {
                    setState(() => applying = false);
                  }
                }
              },
            ),
          AppCard(
            padding: const EdgeInsets.all(16),
            child: Anime4kStatusView(player: widget.player),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Listener(
              onPointerDown: (event) {
                if (held || applying || selected == Anime4kPreset.off) {
                  return;
                }
                held = true;
                pointer = event.pointer;
                unawaited(widget.player.showAnime4kOriginal(true));
              },
              onPointerUp: (event) {
                if (event.pointer == pointer) {
                  _release();
                }
              },
              onPointerCancel: (event) {
                if (event.pointer == pointer) {
                  _release();
                }
              },
              child: OutlinedButton(
                onPressed: applying || selected == Anime4kPreset.off
                    ? null : () {},
                child: Text('Hold to show original'.tl),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: Text(
              'The effect is clearest with 720p or lower sources in '
              'fullscreen landscape'.tl,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
