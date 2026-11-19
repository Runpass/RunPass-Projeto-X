import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'catalog_screen.dart';
import 'edition_cards.dart' show EditionCompactCard;
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

  /// [first]: a pessoa ainda não tem corrida para publicar, então não é "outra".
  Widget addRaceButton({bool first = false}) => OutlinedButton.icon(
    key: const Key('new-post-add-race'),
    onPressed: publishing ? null : addOtherRace,
    style: OutlinedButton.styleFrom(
      visualDensity: VisualDensity.compact,
      textStyle: const TextStyle(fontSize: 13),
    ),
    icon: const Icon(Icons.add_location_alt_outlined, size: 18),
    label: Text(first ? 'Cadastrar corrida' : 'Cadastrar outra corrida'),
  );
  RaceRecord? chosen;
  String query = '';
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
      postImageReference = result['imageReference'] as String;
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
    if (reference == race.participation['medalImageReference']) {
      setState(
        () => message =
            'Escolha uma foto diferente da medalha para a publicação.',
      );
      return;
    }
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
        const SnackBar(content: Text('Publicação feita no feed.')),
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
    appBar: AppBar(title: const Text('Nova publicação')),
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
                  addRaceButton(first: true),
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
            // A jornada começa sempre pela foto: primeiro a foto da corrida, depois a corrida.
            const Text(
              '1. A foto da corrida',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
            const SizedBox(height: 4),
            const Text(
              'Pode ser qualquer foto da sua participação. Ela é separada da foto da medalha.',
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
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const Key('new-post-photo'),
                onPressed: uploading || publishing ? null : pickPhoto,
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 13),
                ),
                icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
                label: Text(
                  uploading ? 'Enviando foto...' : 'Incluir foto da publicação',
                ),
              ),
            ),
            if (message != null && postImageReference == null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(message!, key: const Key('new-post-message')),
              ),
            if (postImageReference != null) ...[
              const SizedBox(height: 16),
              Text(
                chosen == null ? '2. Escolha a corrida' : '2. Corrida',
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 8),
              // Escolhida a corrida, ficam só ela e os botões; "Trocar corrida" reabre a lista.
              if (chosen == null) ...[
                TextField(
                  key: const Key('new-post-search'),
                  decoration: const InputDecoration(
                    hintText: 'Buscar corrida pelo nome',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  textInputAction: TextInputAction.search,
                  onChanged: (value) => setState(() => query = value),
                ),
                const SizedBox(height: 8),
                if (filterRaces(list, query, keep: chosen).isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'Nenhuma corrida sua com esse nome.',
                      key: const Key('new-post-search-empty'),
                      style: TextStyle(color: context.muted),
                    ),
                  ),
                for (final race in filterRaces(list, query))
                  KeyedSubtree(
                    key: Key('new-post-race-${race.participation['id']}'),
                    child: EditionCompactCard(
                      gateway: widget.gateway,
                      // Cartao menor e sem imagem, so nesta tela (data, cidade e distancias).
                      showImage: false,
                      edition:
                          race.edition ??
                          {
                            'id': race.participation['editionId'],
                            'name': race.name,
                          },
                      trailing: Icon(
                        chosen == race
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        key: chosen == race
                            ? const Key('new-post-race-chosen')
                            : null,
                        color: chosen == race ? runPassOrange : context.muted,
                      ),
                      actions: race.participation['publishToFeed'] == true
                          ? Text(
                              'Já no feed: vira mais uma publicação',
                              style: TextStyle(
                                color: context.muted,
                                fontSize: 12.5,
                              ),
                            )
                          : null,
                      onTap: () => setState(() => chosen = race),
                    ),
                  ),
                Align(alignment: Alignment.centerLeft, child: addRaceButton()),
              ] else ...[
                KeyedSubtree(
                  key: Key('new-post-race-${chosen!.participation['id']}'),
                  child: EditionCompactCard(
                    gateway: widget.gateway,
                    showImage: false,
                    edition:
                        chosen!.edition ??
                        {
                          'id': chosen!.participation['editionId'],
                          'name': chosen!.name,
                        },
                    trailing: const Icon(
                      Icons.check_circle,
                      key: Key('new-post-race-chosen'),
                      color: runPassOrange,
                    ),
                    actions: chosen!.participation['publishToFeed'] == true
                        ? Text(
                            'Já no feed: vira mais uma publicação',
                            style: TextStyle(
                              color: context.muted,
                              fontSize: 12.5,
                            ),
                          )
                        : null,
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const Key('new-post-change-race'),
                    onPressed: publishing
                        ? null
                        : () => setState(() => chosen = null),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      textStyle: const TextStyle(fontSize: 12.5),
                    ),
                    icon: const Icon(Icons.swap_horiz_rounded, size: 16),
                    label: const Text('Trocar corrida'),
                  ),
                ),
              ],
            ],
            if (chosen != null && postImageReference != null) ...[
              const SizedBox(height: 16),
              const Text(
                '3. Texto da publicação',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('new-post-text'),
                controller: text,
                maxLength: 500,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Texto da publicação (opcional)',
                ),
              ),
              OutlinedButton.icon(
                key: const Key('new-post-tag'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 13),
                ),
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
                icon: const Icon(Icons.local_offer_outlined, size: 18),
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

/// Minúsculas e sem acento, para a busca pelo nome achar "São" digitando "sao".
String foldName(String text) {
  const from = 'áàâãäéèêëíìîïóòôõöúùûüç';
  const to = 'aaaaaeeeeiiiiooooouuuuc';
  final lower = text.toLowerCase();
  final out = StringBuffer();
  for (final rune in lower.runes) {
    final char = String.fromCharCode(rune);
    final i = from.indexOf(char);
    out.write(i < 0 ? char : to[i]);
  }
  return out.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Corridas cujo nome tem todas as palavras digitadas, em qualquer ordem. A corrida escolhida fica
/// sempre visível, para não sumir da tela enquanto a pessoa digita.
List<RaceRecord> filterRaces(
  List<RaceRecord> races,
  String query, {
  RaceRecord? keep,
}) {
  final words = foldName(query).split(' ').where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return races;
  return [
    for (final race in races)
      if (race == keep || words.every(foldName(race.name).contains)) race,
  ];
}
