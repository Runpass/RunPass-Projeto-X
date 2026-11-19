import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'catalog_screen.dart';
import 'duration_field.dart';
import 'identity_gateway.dart';
import 'post_preview.dart';
import 'profile_photo.dart' show PhotoZoomScreen;

/// Dados da minha participação, informados junto do pedido de cadastro de uma corrida que ainda não existe.
/// Ficam guardados com o pedido e o app os aplica sozinho quando a equipe aprova: a pessoa não preenche de novo.
/// Devolve o mapa (`participation` do pedido) ou nulo se voltar. A avaliação (8 notas) é obrigatória para enviar.
class PendingParticipationScreen extends StatefulWidget {
  final IdentityGateway gateway;

  /// Nome da corrida, só para mostrar no título.
  final String raceName;

  /// Distância informada no pedido ("5 km"), só para a prévia da publicação.
  final String? distanceLabel;

  /// Escolhe a foto da publicação; nulo se desistir. Trocável nos testes (galeria e recorte não rodam lá).
  final Future<List<int>?> Function(BuildContext context)? postPhotoSelector;
  const PendingParticipationScreen({
    super.key,
    required this.gateway,
    required this.raceName,
    this.distanceLabel,
    this.postPhotoSelector,
  });

  @override
  State<PendingParticipationScreen> createState() =>
      _PendingParticipationScreenState();
}

class _PendingParticipationScreenState
    extends State<PendingParticipationScreen> {
  final time = TextEditingController();
  final pace = TextEditingController();
  final placement = TextEditingController();
  final bib = TextEditingController();
  final comment = TextEditingController();
  final postText = TextEditingController();
  final ratings = <String, int>{
    for (final c in [
      'organization',
      'course',
      'kit',
      'medal',
      'hydration',
      'facilities',
      'safety',
      'valueForMoney',
    ])
      c: 0,
  };
  bool publish = false, uploadingPost = false;
  String? postImageReference, message;
  List<int>? postBytes; // só para a prévia

  @override
  void dispose() {
    time.dispose();
    pace.dispose();
    placement.dispose();
    bib.dispose();
    comment.dispose();
    postText.dispose();
    super.dispose();
  }

  bool get ratingsComplete => ratings.values.every((v) => v >= 1);
  bool get ratingsEmpty => ratings.values.every((v) => v == 0);

  Future<void> pickPostPhoto() async {
    setState(() {
      uploadingPost = true;
      message = null;
    });
    try {
      List<int>? bytes;
      if (widget.postPhotoSelector != null) {
        bytes = await widget.postPhotoSelector!(context);
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
      postBytes = bytes;
    } on IdentityIssue catch (issue) {
      if (mounted) message = catalogError(issue);
    } on Exception {
      if (mounted) {
        message = 'O app não conseguiu abrir ou ler a foto escolhida. Tente de novo ou escolha outra.';
      }
    } finally {
      if (mounted) setState(() => uploadingPost = false);
    }
  }

  /// Monta o mapa no formato do pedido; devolve nulo (com a mensagem) se algo faltar ou estiver inválido.
  Map<String, dynamic>? collect() {
    final seconds = parseDuration(time.text);
    final paceSeconds = parsePace(pace.text);
    if (paceSeconds == -1) {
      message = 'O pace deve ser em minutos e segundos por km, como 5:30.';
      return null;
    }
    final place = placement.text.trim().isEmpty
        ? null
        : int.tryParse(placement.text.trim());
    if (seconds == -1 ||
        (placement.text.trim().isNotEmpty && (place == null || place < 1))) {
      message = 'O tempo deve ser como 1:30:00 e a colocação um número inteiro maior que zero.';
      return null;
    }
    // Avaliação opcional: as 8 notas ou nenhuma (avalia depois).
    if (!ratingsComplete && !ratingsEmpty) {
      message = 'Dê nota aos 8 critérios ou deixe todos em branco para avaliar depois.';
      return null;
    }
    if (publish && postImageReference == null) {
      message = 'Para publicar no feed, escolha a foto da publicação (outra foto, separada da medalha).';
      return null;
    }
    return {
      'timeSeconds': ?seconds,
      'paceSecondsPerKm': ?paceSeconds,
      'placement': ?place,
      if (bib.text.trim().isNotEmpty) 'bibNumber': bib.text.trim(),
      if (ratingsComplete) 'ratings': Map<String, int>.from(ratings),
      if (ratingsComplete && comment.text.trim().isNotEmpty)
        'comment': comment.text.trim(),
      'publishToFeed': publish,
      if (publish) 'postImageReference': postImageReference,
      if (publish && postText.text.trim().isNotEmpty)
        'postText': postText.text.trim(),
    };
  }

  Future<void> save() async {
    final data = collect();
    if (data == null) {
      setState(() {});
      return;
    }
    // Vai publicar no feed: mostra a prévia e só envia o cadastro se a pessoa confirmar.
    if (publish) {
      final profile = navProfileOf(widget.gateway);
      final seconds = parseDuration(time.text);
      final confirmed = await confirmPostPreview(
        context,
        PostPreviewData(
          authorName: (profile?['displayName'] as String?) ?? 'Você',
          username: (profile?['username'] as String?) ?? '',
          raceName: widget.raceName,
          details: [
            if (widget.distanceLabel != null) widget.distanceLabel!,
            if (seconds is int && seconds > 0) formatDuration(seconds),
          ].join(' · '),
          text: postText.text,
          photo: postBytes,
        ),
      );
      if (!confirmed || !mounted) return;
    }
    Navigator.of(context).pop(data);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Minha participação')),
    body: ListView(
      key: const Key('pending-participation-form'),
      padding: const EdgeInsets.all(20),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        Text(
          widget.raceName,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
        ),
        const SizedBox(height: 4),
        const Text(
          'A corrida ainda será aprovada pela equipe. Preencha agora: os dados ficam guardados (só você vê) e, quando a corrida for aprovada, a sua participação é concluída sozinha, sem você voltar a preencher.',
        ),
        const SizedBox(height: 16),
        DurationField(controller: time),
        const SizedBox(height: 8),
        TextField(
          key: const Key('pending-pace'),
          controller: pace,
          keyboardType: TextInputType.datetime,
          decoration: const InputDecoration(
            labelText: 'Pace (opcional)',
            hintText: 'Ex.: 5:30',
            suffixText: 'min/km',
          ),
        ),
        TextField(
          key: const Key('pending-placement'),
          controller: placement,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Colocação (opcional)'),
        ),
        TextField(
          key: const Key('pending-bib'),
          controller: bib,
          maxLength: 40,
          decoration: const InputDecoration(
            labelText: 'Número de peito (opcional)',
          ),
        ),
        const Divider(height: 32),
        const Text(
          'Avaliação (opcional)',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        const Text(
          'Dê nota aos 8 critérios ou deixe em branco e avalie depois.',
          key: Key('rating-optional-hint'),
        ),
        SameRatingPicker(
          onPick: (n) => setState(() {
            for (final key in ratings.keys.toList()) {
              ratings[key] = n;
            }
          }),
        ),
        for (final (key, label, icon) in criteriaList)
          RatingInput(
            label: label,
            icon: icon,
            value: ratings[key] ?? 0,
            onChanged: (value) => setState(() => ratings[key] = value),
          ),
        TextField(
          key: const Key('pending-comment'),
          controller: comment,
          maxLength: 2000,
          decoration: const InputDecoration(labelText: 'Comentário (opcional)'),
        ),
        CheckboxListTile(
          key: const Key('pending-publish'),
          value: publish,
          onChanged: (value) => setState(() => publish = value ?? false),
          title: const Text('Publicar esta conquista no feed'),
        ),
        if (publish) ...[
          OutlinedButton.icon(
            key: const Key('pending-post-photo'),
            onPressed: uploadingPost ? null : pickPostPhoto,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: Text(
              uploadingPost ? 'Enviando foto...' : 'Incluir foto da publicação',
            ),
          ),
          if (postImageReference != null)
            const Text(
              'Foto da publicação enviada (separada da medalha).',
              key: Key('pending-post-ok'),
            ),
          TextField(
            key: const Key('pending-post-text'),
            controller: postText,
            maxLength: 500,
            decoration: const InputDecoration(
              labelText: 'Texto da publicação (opcional)',
            ),
          ),
        ],
        if (message != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(message!, key: const Key('pending-message')),
          ),
        const SizedBox(height: 12),
        FilledButton(
          key: const Key('pending-save'),
          onPressed: uploadingPost ? null : save,
          child: const Text('Guardar e enviar o cadastro'),
        ),
      ],
    ),
  );
}

/// Os oito critérios da avaliação, na mesma ordem da tela da corrida.
const criteriaList = [
  ('organization', 'Organização', Icons.groups_outlined),
  ('course', 'Percurso', Icons.alt_route),
  ('kit', 'Kit', Icons.card_giftcard),
  ('medal', 'Medalha', Icons.workspace_premium_outlined),
  ('hydration', 'Hidratação', Icons.water_drop_outlined),
  ('facilities', 'Estrutura', Icons.wc_outlined),
  ('safety', 'Segurança', Icons.health_and_safety_outlined),
  ('valueForMoney', 'Custo-benefício', Icons.savings_outlined),
];
