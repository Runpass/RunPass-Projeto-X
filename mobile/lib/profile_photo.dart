import 'dart:io';
import 'dart:typed_data';

import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import 'identity_gateway.dart';
import 'my_races.dart' show imageContentType;
import 'runpass_theme.dart';

enum PhotoChoice { camera, gallery, web, remove }

/// Pergunta de onde vem a foto de perfil; "remover" so aparece quando ja existe uma foto.
Future<PhotoChoice?> askPhotoChoice(
  BuildContext context, {
  bool canRemove = false,
  bool allowWeb = false,
}) => showModalBottomSheet<PhotoChoice>(
  context: context,
  showDragHandle: true,
  builder: (sheet) => SafeArea(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          key: const Key('photo-camera'),
          leading: const Icon(Icons.photo_camera_outlined),
          title: const Text('Tirar uma foto'),
          onTap: () => Navigator.pop(sheet, PhotoChoice.camera),
        ),
        ListTile(
          key: const Key('photo-gallery'),
          leading: const Icon(Icons.photo_library_outlined),
          title: const Text('Escolher da galeria'),
          onTap: () => Navigator.pop(sheet, PhotoChoice.gallery),
        ),
        if (allowWeb)
          ListTile(
            key: const Key('photo-web'),
            leading: const Icon(Icons.public),
            title: const Text('Buscar na internet'),
            subtitle: const Text('Procure a imagem e cole o link dela'),
            onTap: () => Navigator.pop(sheet, PhotoChoice.web),
          ),
        if (canRemove)
          ListTile(
            key: const Key('photo-remove'),
            leading: const Icon(Icons.delete_outline, color: Colors.red),
            title: const Text(
              'Remover foto',
              style: TextStyle(color: Colors.red),
            ),
            onTap: () => Navigator.pop(sheet, PhotoChoice.remove),
          ),
      ],
    ),
  ),
);

/// Camera ou galeria e depois um recorte quadrado (circular na tela). Devolve os bytes
/// recortados, ou nulo se a pessoa desistir em qualquer etapa.
typedef ProfilePhotoPicker = Future<List<int>?> Function(
  BuildContext context,
  PhotoChoice choice,
);

Future<List<int>?> pickProfilePhoto(BuildContext context, PhotoChoice choice) =>
    _pick(context, choice, banner: false);

/// Imagem do banner do perfil: recorte retangular (largo).
Future<List<int>?> pickBannerPhoto(BuildContext context, PhotoChoice choice) =>
    _pick(context, choice, banner: true);

Future<List<int>?> _pick(
  BuildContext context,
  PhotoChoice choice, {
  required bool banner,
}) async {
  final file = await ImagePicker().pickImage(
    source: choice == PhotoChoice.camera
        ? ImageSource.camera
        : ImageSource.gallery,
    maxWidth: 1600,
    maxHeight: 1600,
    imageQuality: 88,
    requestFullMetadata: false,
    preferredCameraDevice: CameraDevice.front,
  );
  final bytes = await file?.readAsBytes();
  if (bytes == null || !context.mounted) return null;
  return Navigator.of(context).push<List<int>>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => ProfilePhotoCropScreen(image: bytes, banner: banner),
    ),
  );
}

/// Baixa uma imagem pelo link (só https, até 8 MB, só JPEG ou PNG). Troque nos testes.
typedef ImageLinkFetcher = Future<List<int>> Function(String url);

const maxWebImageBytes = 8 * 1024 * 1024;

Future<List<int>> fetchImageFromLink(String link) async {
  final uri = Uri.tryParse(link.trim());
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
    throw const IdentityIssue('IMAGE_LINK_INVALID');
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client
        .getUrl(uri)
        .timeout(const Duration(seconds: 10));
    final response = await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw const IdentityIssue('IMAGE_NOT_VALID');
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > maxWebImageBytes) {
        throw const IdentityIssue('IMAGE_SIZE_INVALID');
      }
    }
    if (imageContentType(bytes) == null) {
      throw const IdentityIssue('IMAGE_TYPE_INVALID');
    }
    return bytes;
  } finally {
    client.close(force: true);
  }
}

/// Endereço de uma busca de imagens na internet para o nome da corrida (abre no navegador).
Uri webImageSearchUri(String query) => Uri.https('www.google.com', '/search', {
  'tbm': 'isch',
  'q': '${query.trim()} banner corrida',
});

/// Banner da internet: a pessoa procura a imagem no navegador, cola o link e o app baixa e recorta.
/// A equipe só publica depois de conferir o crédito e a autorização do organizador.
Future<List<int>?> pickBannerFromWeb(
  BuildContext context, {
  String query = '',
  ImageLinkFetcher fetcher = fetchImageFromLink,
}) async {
  final bytes = await showDialog<List<int>>(
    context: context,
    builder: (dialog) => _WebImageDialog(query: query, fetcher: fetcher),
  );
  if (bytes == null || !context.mounted) return null;
  return Navigator.of(context).push<List<int>>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => ProfilePhotoCropScreen(
        image: Uint8List.fromList(bytes),
        banner: true,
      ),
    ),
  );
}

class _WebImageDialog extends StatefulWidget {
  final String query;
  final ImageLinkFetcher fetcher;
  const _WebImageDialog({required this.query, required this.fetcher});

  @override
  State<_WebImageDialog> createState() => _WebImageDialogState();
}

class _WebImageDialogState extends State<_WebImageDialog> {
  final link = TextEditingController();
  bool loading = false;
  String? error;

  @override
  void dispose() {
    link.dispose();
    super.dispose();
  }

  Future<void> use() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final bytes = await widget.fetcher(link.text.trim());
      if (mounted) Navigator.pop(context, bytes);
    } on Object catch (problem) {
      if (mounted) {
        setState(() {
          loading = false;
          error =
              problem is IdentityIssue && problem.code == 'IMAGE_LINK_INVALID'
              ? 'Cole o link da imagem, começando com https://'
              : photoError(problem);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Banner da internet'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '1. Procure a imagem no navegador. 2. Copie o link da imagem (toque e segure nela). 3. Cole aqui.',
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('web-image-search'),
            onPressed: () => launchUrl(
              webImageSearchUri(widget.query),
              mode: LaunchMode.externalApplication,
            ),
            icon: const Icon(Icons.search_rounded),
            label: const Text('Procurar no navegador'),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('web-image-link'),
            controller: link,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Link da imagem (https://...)',
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(error!, key: const Key('web-image-error')),
            ),
          const SizedBox(height: 8),
          const Text(
            'A imagem só é publicada se a equipe aprovar, com o crédito e a autorização do organizador.',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: loading ? null : () => Navigator.pop(context),
        child: const Text('Cancelar'),
      ),
      FilledButton(
        key: const Key('web-image-use'),
        onPressed: loading ? null : use,
        child: Text(loading ? 'Baixando...' : 'Usar esta imagem'),
      ),
    ],
  );
}

/// Envia a foto e devolve a referencia aceita; falha se a imagem nao passar na validacao.
Future<String> uploadProfilePhoto(
  IdentityGateway gateway,
  List<int> bytes,
) async {
  final type = imageContentType(bytes);
  if (type == null) throw const IdentityIssue('IMAGE_TYPE_INVALID');
  final result = await gateway.uploadImage(bytes, type);
  final reference = result['imageReference'];
  if (result['state'] != 'valid' || reference is! String) {
    throw const IdentityIssue('IMAGE_NOT_VALID');
  }
  return reference;
}

String photoError(Object error) => error is IdentityIssue
    ? switch (error.code) {
        'IMAGE_TYPE_INVALID' => 'Escolha uma foto JPEG ou PNG.',
        'IMAGE_NOT_VALID' => 'A foto não foi aceita. Escolha outra imagem.',
        'IMAGE_SIZE_INVALID' => 'A foto é grande demais. Escolha outra.',
        'IMAGE_LINK_INVALID' => 'Cole o link da imagem, começando com https://',
        _ => 'Não foi possível enviar a foto. Verifique a internet e tente de novo.',
      }
    : 'Não foi possível usar a câmera ou a galeria. Confira a permissão do app nos Ajustes do celular.';

class ProfilePhotoCropScreen extends StatefulWidget {
  final Uint8List image;
  final bool banner;
  final String? title;
  final String? instructions;
  const ProfilePhotoCropScreen({
    super.key,
    required this.image,
    this.banner = false,
    this.title,
    this.instructions,
  });

  @override
  State<ProfilePhotoCropScreen> createState() => _ProfilePhotoCropScreenState();
}

class _ProfilePhotoCropScreenState extends State<ProfilePhotoCropScreen> {
  final controller = CropController();
  bool busy = false;

  void done(CropResult result) {
    if (!mounted) return;
    switch (result) {
      case CropSuccess(:final croppedImage):
        Navigator.of(context).pop<List<int>>(croppedImage);
      case CropFailure():
        setState(() => busy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Não foi possível recortar a foto. Tente de novo.'),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      title: Text(
        widget.title ?? (widget.banner ? 'Recortar banner' : 'Recortar foto'),
      ),
    ),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              widget.instructions ??
                  (widget.banner
                      ? 'Arraste e use dois dedos para ampliar. A parte dentro do quadro será o banner.'
                      : 'Arraste e use dois dedos para ampliar. Deixe só o rosto dentro do círculo.'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
          ),
          Expanded(
            child: Crop(
              image: widget.image,
              controller: controller,
              aspectRatio: widget.banner ? 16 / 7 : 1,
              withCircleUi: !widget.banner,
              interactive: true,
              fixCropRect: true,
              baseColor: Colors.black,
              maskColor: Colors.black.withValues(alpha: 0.6),
              onCropped: done,
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    key: const Key('crop-cancel'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                    ),
                    onPressed: busy ? null : () => Navigator.of(context).pop(),
                    child: const Text('Cancelar'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    key: const Key('crop-confirm'),
                    style: FilledButton.styleFrom(
                      backgroundColor: runPassOrange,
                    ),
                    onPressed: busy
                        ? null
                        : () {
                            setState(() => busy = true);
                            controller.crop();
                          },
                    child: Text(busy ? 'Aguarde…' : 'Usar esta foto'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// Recorte da foto da medalha/corrida: arrastar, ampliar com dois dedos e escolher a proporção.
/// "Livre" deixa o quadro ser redimensionado pelas bordas; as demais fixam a proporção do quadro.
class RacePhotoCropScreen extends StatefulWidget {
  final Uint8List image;
  const RacePhotoCropScreen({super.key, required this.image});

  /// Proporções oferecidas (largura / altura); `null` é o recorte livre.
  static const aspects = <(String, double?)>[
    ('Livre', null),
    ('1:1', 1),
    ('4:3', 4 / 3),
    ('3:4', 3 / 4),
    ('16:9', 16 / 9),
  ];

  @override
  State<RacePhotoCropScreen> createState() => _RacePhotoCropScreenState();
}

class _RacePhotoCropScreenState extends State<RacePhotoCropScreen> {
  final controller = CropController();
  int selected = 2; // 4:3: boa para foto de medalha
  bool busy = false;

  double? get aspect => RacePhotoCropScreen.aspects[selected].$2;

  void done(CropResult result) {
    if (!mounted) return;
    switch (result) {
      case CropSuccess(:final croppedImage):
        Navigator.of(context).pop<List<int>>(croppedImage);
      case CropFailure():
        setState(() => busy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Não foi possível recortar a foto. Tente de novo.'),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      title: const Text('Ajustar foto'),
    ),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              aspect == null
                  ? 'Arraste as bordas do quadro para escolher o tamanho e mova a foto com o dedo.'
                  : 'Arraste a foto e use dois dedos para ampliar. A parte dentro do quadro será a foto.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
          ),
          Expanded(
            child: Crop(
              // Trocar a proporção recria o quadro do zero (a foto volta inteira).
              key: ValueKey(selected),
              image: widget.image,
              controller: controller,
              aspectRatio: aspect,
              interactive: true,
              fixCropRect: aspect != null,
              baseColor: Colors.black,
              maskColor: Colors.black.withValues(alpha: 0.6),
              onCropped: done,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Wrap(
              spacing: 8,
              children: [
                for (final (index, option)
                    in RacePhotoCropScreen.aspects.indexed)
                  ChoiceChip(
                    key: Key('crop-aspect-$index'),
                    label: Text(option.$1),
                    selected: selected == index,
                    onSelected: busy
                        ? null
                        : (_) => setState(() => selected = index),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    key: const Key('crop-cancel'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                    ),
                    onPressed: busy ? null : () => Navigator.of(context).pop(),
                    child: const Text('Cancelar'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    key: const Key('crop-confirm'),
                    style: FilledButton.styleFrom(
                      backgroundColor: runPassOrange,
                    ),
                    onPressed: busy
                        ? null
                        : () {
                            setState(() => busy = true);
                            controller.crop();
                          },
                    child: Text(busy ? 'Aguarde…' : 'Usar esta foto'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
