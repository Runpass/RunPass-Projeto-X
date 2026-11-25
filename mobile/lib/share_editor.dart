import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'post_card.dart';
import 'runpass_theme.dart';

/// Tela "Compartilhar": a pessoa vê a imagem e escolhe onde ficam as informações, a medalha e o ícone.
/// Devolve o [ShareStyle] escolhido ao voltar com "Compartilhar" (nulo se sair sem enviar).
class ShareEditorScreen extends StatefulWidget {
  final String title;
  final String distance;
  final String time;
  final String pace;
  final Uint8List? photoBytes;
  final Uint8List? medalBytes;
  const ShareEditorScreen({
    super.key,
    required this.title,
    required this.distance,
    required this.time,
    required this.pace,
    this.photoBytes,
    this.medalBytes,
  });

  @override
  State<ShareEditorScreen> createState() => _ShareEditorScreenState();
}

class _ShareEditorScreenState extends State<ShareEditorScreen> {
  static const _corners = {
    ShareCorner.topLeft: 'Cima esquerda',
    ShareCorner.topRight: 'Cima direita',
    ShareCorner.bottomLeft: 'Baixo esquerda',
    ShareCorner.bottomRight: 'Baixo direita',
  };
  static const _stickers = {
    ShareSticker.none: 'Nenhum',
    ShareSticker.star: 'Estrela',
    ShareSticker.trophy: 'Troféu',
    ShareSticker.flag: 'Bandeira',
    ShareSticker.fire: 'Fogo',
  };

  ShareInfoLayout info = ShareInfoLayout.bands;
  ShareCorner? medalCorner;
  ShareSticker sticker = ShareSticker.none;
  ShareCorner stickerCorner = ShareCorner.topRight;
  Uint8List? preview;
  int _request = 0;

  ShareStyle get style => ShareStyle(
    info: info,
    medalCorner: medalCorner,
    sticker: sticker,
    stickerCorner: stickerCorner,
  );

  @override
  void initState() {
    super.initState();
    render();
  }

  /// Monta a prévia com as escolhas atuais. Só a última chamada vale (a pessoa pode trocar várias vezes).
  Future<void> render() async {
    final mine = ++_request;
    final bytes = await shareCardBuilder(
      title: widget.title,
      distance: widget.distance,
      time: widget.time,
      pace: widget.pace,
      photoBytes: widget.photoBytes,
      style: style,
      medalBytes: widget.medalBytes,
    );
    if (mounted && mine == _request) setState(() => preview = bytes);
  }

  void change(VoidCallback update) {
    setState(update);
    render();
  }

  @override
  Widget build(BuildContext context) {
    final hasMedal = widget.medalBytes != null;
    final muted = context.muted;
    return Scaffold(
      appBar: AppBar(title: const Text('Compartilhar')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 520),
                child: preview == null
                    ? const SizedBox(
                        height: 200,
                        child: Center(child: CircularProgressIndicator()),
                      )
                    : Image.memory(
                        preview!,
                        key: const Key('share-preview'),
                        gaplessPlayback: true,
                        fit: BoxFit.contain,
                        errorBuilder: (_, _, _) => const SizedBox(
                          height: 200,
                          child: Center(
                            child: Text(
                              'Não foi possível montar a prévia. Você ainda pode compartilhar.',
                            ),
                          ),
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Informações',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            SegmentedButton<ShareInfoLayout>(
              key: const Key('share-info'),
              segments: const [
                ButtonSegment(
                  value: ShareInfoLayout.bands,
                  label: Text('Faixas'),
                ),
                ButtonSegment(
                  value: ShareInfoLayout.overlay,
                  label: Text('Sobre a foto'),
                ),
              ],
              selected: {info},
              onSelectionChanged: (choice) => change(() => info = choice.first),
            ),
            const SizedBox(height: 20),
            const Text(
              'Medalha',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  key: const Key('share-medal-none'),
                  label: const Text('Nenhuma'),
                  selected: medalCorner == null,
                  onSelected: (_) => change(() => medalCorner = null),
                ),
                for (final entry in _corners.entries)
                  ChoiceChip(
                    key: Key('share-medal-${entry.key.name}'),
                    label: Text(entry.value),
                    selected: medalCorner == entry.key,
                    onSelected: hasMedal
                        ? (_) => change(() => medalCorner = entry.key)
                        : null,
                  ),
              ],
            ),
            if (!hasMedal)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Esta corrida não tem foto da medalha.',
                  style: TextStyle(fontSize: 12, color: muted),
                ),
              ),
            const SizedBox(height: 20),
            const Text('Ícone', style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final entry in _stickers.entries)
                  ChoiceChip(
                    key: Key('share-sticker-${entry.key.name}'),
                    label: Text(entry.value),
                    selected: sticker == entry.key,
                    onSelected: (_) => change(() => sticker = entry.key),
                  ),
              ],
            ),
            if (sticker != ShareSticker.none) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final entry in _corners.entries)
                    ChoiceChip(
                      key: Key('share-sticker-corner-${entry.key.name}'),
                      label: Text(entry.value),
                      selected: stickerCorner == entry.key,
                      onSelected: (_) =>
                          change(() => stickerCorner = entry.key),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Text(
              'A imagem é uma foto estática (PNG), aceita pelo Instagram, pelo Facebook e pelas mensagens. '
              'Ícones animados não entram nela.',
              style: TextStyle(fontSize: 12, color: muted),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              key: const Key('share-send'),
              onPressed: () => Navigator.of(context).pop(style),
              icon: const Icon(Icons.ios_share),
              label: const Text('Compartilhar'),
            ),
          ],
        ),
      ),
    );
  }
}
