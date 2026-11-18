import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'catalog_screen.dart';
import 'medal_scan.dart' show MedalScanScreen, pickMedalPhotoPath;
import 'identity_gateway.dart';
import 'profile_photo.dart' show PhotoZoomScreen;
import 'tagged_people.dart';
import 'runpass_theme.dart';

/// Nova postagem (o "+" da Home): publica no feed uma corrida que eu já concluí (também mais de uma vez,
/// com outras fotos), com uma foto própria (qualquer foto, separada da foto da medalha) e um texto. A corrida pode ser outra:
/// "Adicionar outra corrida" usa o mesmo fluxo da medalha (corrida do catálogo ou pedido de cadastro) e, ao voltar,
/// ela aparece na lista para publicar.
class NewPostScreen extends StatefulWidget {
  final IdentityGateway gateway;

  /// Escolhe a foto da postagem; nulo se desistir. Trocável nos testes (a galeria e o recorte não rodam lá).
  final Future<List<int>?> Function(BuildContext context)? photoSelector;

  /// Adiciona outra corrida (foto da medalha, catálogo ou pedido de cadastro). Devolve o resultado do fluxo da
  /// medalha (`'request'` quando virou pedido) ou nulo se a pessoa desistir. Trocável nos testes.
  final Future<Object?> Function(BuildContext context)? addRace;
  const NewPostScreen({
    super.key,
    required this.gateway,
    this.photoSelector,
    this.addRace,
  });

  @override
  State<NewPostScreen> createState() => _NewPostScreenState();
}

class _NewPostScreenState extends State<NewPostScreen> {
  late Future<List<RaceRecord>> races = loadPublishable();

  /// Todas as corridas que concluí: a ainda não publicada ganha a publicação dela; a já publicada ganha mais
  /// uma (outra foto da mesma corrida), sem pedir medalha.
  Future<List<RaceRecord>> loadPublishable() => loadMyRaces(widget.gateway);

  /// Corrida que não está na lista: usa o fluxo da medalha (escolhe no catálogo ou pede o cadastro).
  Future<void> addOtherRace() async {
    Object? result;
    if (widget.addRace != null) {
      result = await widget.addRace!(context);
    } else {
      final path = await pickMedalPhotoPath(context);
      if (path == null || !mounted) return;
      result = await Navigator.of(context).push<Object?>(
        MaterialPageRoute<Object?>(
          builder: (_) =>
              MedalScanScreen(gateway: widget.gateway, photoPath: path),
        ),
      );
    }
    if (!mounted || result == null) return;
    setState(() {
      races = loadPublishable();
      message = result == 'request'
          ? 'Pedido de cadastro enviado. Quando a equipe aprovar a corrida, ela aparece aqui para publicar.'
          : null;
    });
  }

  Widget addRaceButton() => OutlinedButton.icon(
    key: const Key('new-post-add-race'),
    onPressed: publishing ? null : addOtherRace,
    icon: const Icon(Icons.add_location_alt_outlined),
    label: const Text('Adicionar outra corrida (do catálogo ou não)'),
  );
  RaceRecord? chosen;
  String? postImageReference, message;
  List<int>? preview;
  bool uploading = false, publishing = false;
  List<Map<String, dynamic>> tagged = [];
  final text = TextEditingController();

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  Future<void> pickPhoto() async {
    setState(() {
      uploading = true;
      message = null;
    });
    try {
      List<int>? bytes;
      if (widget.photoSelector != null) {
        bytes = await widget.photoSelector!(context);
      } else {
        final file = await ImagePicker().pickImage(
          source: ImageSource.gallery,
          maxWidth: 2800,
          maxHeight: 2800,
          imageQuality: 88,
          requestFullMetadata: false,
        );
        final original = await file?.readAsBytes();
        if (original == null || !mounted) return;
        bytes = await Navigator.of(context).push<List<int>>(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (_) => PhotoZoomScreen(image: original),
          ),
        );
      }
      if (bytes == null) return;
      final type = imageContentType(bytes);
      if (type == null) throw const IdentityIssue('IMAGE_FORMAT_INVALID');
      final result = await widget.gateway.uploadImage(bytes, type);
      if (result['state'] != 'valid') {
        throw IdentityIssue(result['reasonCode'] as String? ?? 'INVALID_IMAGE');
      }
      final reference = result['imageReference'] as String;
      if (reference == chosen?.participation['medalImageReference']) {
        message = 'Escolha uma foto diferente da medalha para a postagem.';
        return;
      }
      postImageReference = reference;
      preview = bytes;
    } on IdentityIssue catch (issue) {
      if (mounted) message = catalogError(issue);
    } on Exception {
      if (mounted) {
        message = 'O app não conseguiu abrir ou ler a foto escolhida. Tente de novo ou escolha outra.';
      }
    } finally {
      if (mounted) setState(() => uploading = false);
    }
  }

  Future<void> publish() async {
    final race = chosen;
    final reference = postImageReference;
    if (race == null || reference == null || publishing) return;
    setState(() {
      publishing = true;
      message = null;
    });
    try {
      final already = race.participation['publishToFeed'] == true;
      await widget.gateway.request(
        already
            ? '/posts'
            : '/participations/${Uri.encodeComponent(race.participation['id'] as String)}/publish',
        method: 'POST',
        body: {
          if (already)
            'participationId': race.participation['id']
          else
            'expectedVersion': race.participation['version'],
          'postImageReference': reference,
          if (text.text.trim().isNotEmpty) 'postText': text.text.trim(),
          if (tagged.isNotEmpty)
            'taggedUserIds': [for (final p in tagged) p['id']],
        },
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Postagem publicada no feed.')),
      );
      Navigator.of(context).pop(true);
    } on IdentityIssue catch (issue) {
      if (mounted) {
        message = issue.code == 'ALREADY_PUBLISHED'
            ? 'Esta corrida já está publicada no feed.'
            : catalogError(issue);
      }
    } on Exception {
      if (mounted) {
        message =
            'Sem conexão com o servidor. Verifique a internet e tente de novo.';
      }
    } finally {
      if (mounted) setState(() => publishing = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Nova postagem')),
    body: FutureBuilder<List<RaceRecord>>(
      future: races,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return loadMessage(loadError(snapshot.error!));
        }
        final list = snapshot.data!;
        if (list.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Você não tem corrida concluída para publicar. Adicione a corrida (do catálogo ou não) com a foto da medalha e ela aparece aqui.',
                    key: const Key('new-post-empty'),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: context.muted),
                  ),
                  const SizedBox(height: 12),
                  addRaceButton(),
                  if (message != null) ...[
                    const SizedBox(height: 8),
                    Text(message!, key: const Key('new-post-message')),
                  ],
                ],
              ),
            ),
          );
        }
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              '1. Escolha a corrida',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
            const SizedBox(height: 8),
            for (final race in list)
              Card(
                key: Key('new-post-race-${race.participation['id']}'),
                color: chosen == race
                    ? Theme.of(context).colorScheme.primaryContainer
                    : null,
                child: ListTile(
                  leading: Icon(
                    chosen == race ? Icons.check_circle : Icons.directions_run,
                    color: runPassOrange,
                  ),
                  title: Text(race.name),
                  subtitle: Text(
                    [
                      if (race.date != null) displayDate(race.date!),
                      if (race.place.isNotEmpty) race.place,
                      if (race.participation['publishToFeed'] == true)
                        'já no feed: vira mais uma publicação',
                    ].join(' · '),
                  ),
                  onTap: () => setState(() {
                    chosen = race;
                    postImageReference =
                        null; // a foto vale para a corrida escolhida
                    preview = null;
                  }),
                ),
              ),
            Align(alignment: Alignment.centerLeft, child: addRaceButton()),
            if (chosen != null) ...[
              const SizedBox(height: 16),
              const Text(
                '2. Foto e texto da postagem',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
              ),
              const SizedBox(height: 8),
              const Text(
                'Pode ser qualquer foto. Ela é separada da foto da medalha.',
              ),
              const SizedBox(height: 8),
              if (preview != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.memory(
                    Uint8List.fromList(preview!),
                    key: const Key('new-post-preview'),
                    height: 200,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
              OutlinedButton.icon(
                key: const Key('new-post-photo'),
                onPressed: uploading || publishing ? null : pickPhoto,
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: Text(
                  uploading
                      ? 'Enviando foto...'
                      : (postImageReference == null
                            ? 'Escolher a foto da postagem'
                            : 'Trocar a foto'),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('new-post-text'),
                controller: text,
                maxLength: 500,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Texto da postagem (opcional)',
                ),
              ),
              OutlinedButton.icon(
                key: const Key('new-post-tag'),
                onPressed: publishing
                    ? null
                    : () async {
                        final picked = await pickTaggedPeople(
                          context,
                          widget.gateway,
                          tagged,
                        );
                        if (picked != null && mounted) {
                          setState(() => tagged = picked);
                        }
                      },
                icon: const Icon(Icons.local_offer_outlined),
                label: Text(
                  tagged.isEmpty
                      ? 'Marcar pessoas'
                      : 'Marcados: ${tagged.map((p) => '@${p['username']}').join(', ')}',
                ),
              ),
              const SizedBox(height: 8),
              if (message != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(message!, key: const Key('new-post-message')),
                ),
              FilledButton.icon(
                key: const Key('new-post-publish'),
                onPressed: postImageReference == null || publishing
                    ? null
                    : publish,
                icon: const Icon(Icons.send_rounded),
                label: Text(publishing ? 'Publicando...' : 'Publicar no feed'),
              ),
            ],
          ],
        );
      },
    ),
  );
}
