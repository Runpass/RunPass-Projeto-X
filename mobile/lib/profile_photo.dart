import 'dart:typed_data';

import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'identity_gateway.dart';
import 'my_races.dart' show imageContentType;
import 'runpass_theme.dart';

enum PhotoChoice { camera, gallery, remove }

/// Pergunta de onde vem a foto de perfil; "remover" so aparece quando ja existe uma foto.
Future<PhotoChoice?> askPhotoChoice(
  BuildContext context, {
  bool canRemove = false,
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
