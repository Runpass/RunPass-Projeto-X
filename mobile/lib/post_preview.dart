import 'dart:typed_data' show Uint8List;

import 'package:flutter/material.dart';

import 'friends.dart' show ProfileAvatar;
import 'runpass_theme.dart';

/// O que aparece na prévia da publicação: o mesmo que vai para o Feed.
class PostPreviewData {
  final String authorName;
  final String username;
  final String raceName;

  /// "10 km · 58:23", só o que a pessoa informou.
  final String details;
  final String? text;

  /// Usuários marcados (sem o @).
  final List<String> tagged;

  /// Foto da publicação já escolhida; sem ela, mostra um espaço reservado.
  final List<int>? photo;
  const PostPreviewData({
    required this.authorName,
    required this.username,
    required this.raceName,
    this.details = '',
    this.text,
    this.tagged = const [],
    this.photo,
  });
}

/// Mostra como a publicação vai ficar no Feed e pergunta se confirma. Devolve verdadeiro só se a pessoa
/// confirmar; "Voltar e editar" (ou fechar) não publica nada.
Future<bool> confirmPostPreview(
  BuildContext context,
  PostPreviewData data,
) async {
  final confirmed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // A prévia rola; os dois botões ficam sempre à vista, embaixo.
            Flexible(
              child: SingleChildScrollView(
                key: const Key('post-preview'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Prévia da publicação',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 20,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'É assim que a publicação vai aparecer no Feed. Confira antes de confirmar.',
                      style: TextStyle(color: sheet.muted),
                    ),
                    const SizedBox(height: 12),
                    Card(
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ListTile(
                            leading: const ProfileAvatar(radius: 20),
                            title: Text(
                              data.authorName,
                              key: const Key('post-preview-author'),
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            subtitle: Text(
                              data.username.isEmpty
                                  ? 'concluiu ${data.raceName}'
                                  : '@${data.username} · concluiu ${data.raceName}',
                            ),
                          ),
                          AspectRatio(
                            aspectRatio: 16 / 10,
                            child: data.photo == null
                                ? ColoredBox(
                                    color: sheet.panel,
                                    child: Center(
                                      child: Icon(
                                        Icons.image_outlined,
                                        size: 48,
                                        color: sheet.muted,
                                      ),
                                    ),
                                  )
                                : Image.memory(
                                    Uint8List.fromList(data.photo!),
                                    key: const Key('post-preview-photo'),
                                    fit: BoxFit.cover,
                                    // Foto que o aparelho não consegue mostrar na prévia: segue o espaço reservado.
                                    errorBuilder: (context, error, stack) =>
                                        ColoredBox(
                                          color: sheet.panel,
                                          child: Center(
                                            child: Icon(
                                              Icons.image_outlined,
                                              size: 48,
                                              color: sheet.muted,
                                            ),
                                          ),
                                        ),
                                  ),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  data.raceName,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 16,
                                  ),
                                ),
                                if (data.details.isNotEmpty)
                                  Text(
                                    data.details,
                                    key: const Key('post-preview-details'),
                                    style: TextStyle(color: sheet.muted),
                                  ),
                                if ((data.text ?? '').trim().isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    data.text!.trim(),
                                    key: const Key('post-preview-text'),
                                  ),
                                ],
                                if (data.tagged.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    'Com ${data.tagged.map((u) => '@$u').join(', ')}',
                                    key: const Key('post-preview-tagged'),
                                    style: TextStyle(color: sheet.muted),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              key: const Key('post-preview-confirm'),
              onPressed: () => Navigator.pop(sheet, true),
              child: const Text('Confirmar e publicar'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              key: const Key('post-preview-back'),
              onPressed: () => Navigator.pop(sheet, false),
              child: const Text('Voltar e editar'),
            ),
          ],
        ),
      ),
    ),
  );
  return confirmed == true;
}
