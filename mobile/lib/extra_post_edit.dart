import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'catalog_screen.dart' show catalogError;
import 'identity_gateway.dart';
import 'my_races.dart' show MedalPhoto, fetchImageBytes, imageContentType;
import 'profile_photo.dart' show editPhoto, pickAndEditPhoto;
import 'tagged_people.dart' show pickTaggedPeople;

/// Editar uma publicação a mais (outra postagem da mesma corrida): as fotos (a capa e até 4 a mais: ajustar,
/// trocar, remover e incluir) e o texto. Cada mudança de foto grava na hora; o texto, em "Salvar texto".
class ExtraPostEditScreen extends StatefulWidget {
  final IdentityGateway gateway;
  final String postId;
  final int version;
  final String? text;

  /// Pessoas marcadas hoje na publicação (o feed já tem a lista).
  final List<Map<String, dynamic>> tagged;

  /// Escolhe as pessoas marcadas; nulo se desistir. Trocável nos testes.
  final Future<List<Map<String, dynamic>>?> Function(
    BuildContext context,
    IdentityGateway gateway,
    List<Map<String, dynamic>> selected,
  )
  tagPicker;

  /// Escolhe uma foto nova (trocar ou incluir); nulo se desistir. Trocável nos testes.
  final Future<List<int>?> Function(BuildContext context)? photoSelector;

  /// Baixa a foto [index] (0 é a capa) para ajustar. Trocável nos testes.
  final Future<List<int>?> Function(IdentityGateway, String postId, int index)
  photoLoader;

  /// Abre o editor numa foto já escolhida. Trocável nos testes.
  final Future<List<int>?> Function(BuildContext context, List<int> photo)
  photoEditor;
  const ExtraPostEditScreen({
    super.key,
    required this.gateway,
    required this.postId,
    required this.version,
    this.text,
    this.tagged = const [],
    this.tagPicker = pickTaggedPeople,
    this.photoSelector,
    this.photoLoader = loadExtraPostPhoto,
    this.photoEditor = _editPostPhoto,
  });

  @override
  State<ExtraPostEditScreen> createState() => _ExtraPostEditScreenState();
}

Future<List<int>?> _editPostPhoto(BuildContext context, List<int> photo) =>
    editPhoto(context, photo, 'Foto da publicação');

/// Foto [index] (0 é a capa) de uma publicação a mais.
Future<List<int>?> loadExtraPostPhoto(
  IdentityGateway gateway,
  String postId,
  int index,
) async {
  try {
    final link = await gateway.request(
      '/posts/${Uri.encodeComponent(postId)}/image',
      query: index == 0 ? null : {'index': '$index'},
    );
    return await fetchImageBytes(link['url'] as String);
  } on Exception {
    return null;
  }
}

/// Menu de uma foto da publicação, igual em toda edição de post: ajustar, trocar e (nas fotos a mais) remover.
Future<String?> askPostPhotoAction(
  BuildContext context, {
  required bool canRemove,
}) => showModalBottomSheet<String>(
  context: context,
  showDragHandle: true,
  builder: (sheet) => SafeArea(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          key: const Key('post-photo-adjust'),
          leading: const Icon(Icons.crop_rounded),
          title: const Text('Ajustar foto'),
          onTap: () => Navigator.pop(sheet, 'adjust'),
        ),
        ListTile(
          key: const Key('post-photo-replace'),
          leading: const Icon(Icons.photo_library_outlined),
          title: const Text('Trocar foto'),
          onTap: () => Navigator.pop(sheet, 'replace'),
        ),
        if (canRemove)
          ListTile(
            key: const Key('post-photo-remove'),
            leading: const Icon(Icons.delete_outline, color: Colors.red),
            title: const Text(
              'Remover foto',
              style: TextStyle(color: Colors.red),
            ),
            onTap: () => Navigator.pop(sheet, 'remove'),
          ),
      ],
    ),
  ),
);

/// Fotos da publicação na edição, igual em toda tela: a capa e as fotos a mais em miniaturas (tocar abre
/// [askPostPhotoAction]) e "Mais fotos (n de 5)". [hiddenMore]: fotos a mais que existem mas não vieram do
/// servidor (só mostra quantas são).
class PostPhotosEditor extends StatelessWidget {
  final List<Widget> photos;
  final ValueChanged<int> onOpen;
  final VoidCallback? onAdd;
  final bool busy;
  final int hiddenMore;
  static const maxPhotos = 5;
  const PostPhotosEditor({
    super.key,
    required this.photos,
    required this.onOpen,
    this.onAdd,
    this.busy = false,
    this.hiddenMore = 0,
  });

  @override
  Widget build(BuildContext context) => Column(
    key: const Key('post-photos-editor'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Fotos da publicação',
        style: TextStyle(fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 4),
      const Text(
        'Toque numa foto para ajustar, trocar ou remover. A primeira é a capa.',
        style: TextStyle(fontSize: 12.5),
      ),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (var i = 0; i < photos.length; i++)
            InkWell(
              key: Key('post-photo-thumb-$i'),
              onTap: busy ? null : () => onOpen(i),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(width: 88, height: 88, child: photos[i]),
              ),
            ),
          if (hiddenMore > 0) Text('+$hiddenMore fotos'),
          if (onAdd != null && hiddenMore == 0 && photos.length < maxPhotos)
            TextButton.icon(
              key: const Key('post-photo-add'),
              onPressed: busy ? null : onAdd,
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: Text('Mais fotos (${photos.length} de $maxPhotos)'),
            ),
        ],
      ),
    ],
  );
}

class _ExtraPostEditScreenState extends State<ExtraPostEditScreen> {
  late int version = widget.version;
  late final text = TextEditingController(text: widget.text ?? '');
  late List<Map<String, dynamic>> tagged = [...widget.tagged];

  /// Fotos a mais (referências na ordem do carrossel) e os bytes das trocadas aqui, para a miniatura.
  List<String> more = [];
  List<List<int>?> moreBytes = [];
  List<int>? coverBytes;
  int coverRevision = 0;
  bool loading = true, busy = false, refsKnown = true;

  /// Não deu para ler a publicação: o editor fica fechado (gravar sem as fotos atuais apagaria as fotos).
  bool failed = false;
  int count = 1;
  String? message;

  String get base => '/posts/${Uri.encodeComponent(widget.postId)}';

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  Future<void> load() async {
    if (failed && mounted) {
      setState(() {
        failed = false;
        loading = true;
        message = null;
      });
    }
    try {
      final post = await widget.gateway.request(base);
      final refs = [
        for (final r in (post['morePostImageReferences'] as List? ?? const []))
          if (r is String) r,
      ];
      count = (post['postImageCount'] as num?)?.toInt() ?? 1 + refs.length;
      if (post['tagged'] is List) {
        tagged = [
          for (final person in post['tagged'] as List)
            if (person is Map) Map<String, dynamic>.from(person),
        ];
      }
      // Sem as referências (resposta antiga), só mostra quantas são: gravar a lista sem elas apagaria as fotos.
      refsKnown = post['morePostImageReferences'] is List || count <= 1;
      more = refs;
      moreBytes = List.filled(refs.length, null, growable: true);
      if ((post['version'] as num?) != null) {
        version = (post['version'] as num).toInt();
      }
    } on Exception {
      failed = true;
      message = 'Não foi possível abrir a publicação agora.';
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<String?> upload(List<int> bytes) async {
    final type = imageContentType(bytes);
    if (type == null) throw const IdentityIssue('IMAGE_FORMAT_INVALID');
    final result = await widget.gateway.uploadImage(bytes, type);
    if (result['state'] != 'valid') {
      throw IdentityIssue(result['reasonCode'] as String? ?? 'INVALID_IMAGE');
    }
    return result['imageReference'] as String;
  }

  Future<bool> patch(Map<String, dynamic> changes, String done) async {
    final reply = await widget.gateway.request(
      '$base/extra',
      method: 'PATCH',
      body: {'expectedVersion': version, ...changes},
    );
    if ((reply['version'] as num?) != null) {
      version = (reply['version'] as num).toInt();
    }
    message = done;
    return true;
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await action();
    } on IdentityIssue catch (issue) {
      message = catalogError(issue);
    } on Exception {
      message =
          'Não foi possível salvar agora. A publicação anterior foi mantida.';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<List<int>?> pickNew() async {
    final selector = widget.photoSelector;
    return selector != null
        ? selector(context)
        : pickAndEditPhoto(context, title: 'Foto da publicação');
  }

  /// [index] 0 é a capa; 1 a 4, as fotos a mais.
  Future<void> openPhoto(int index) async {
    final action = await askPostPhotoAction(
      context,
      canRemove: index > 0 && refsKnown,
    );
    if (action == null || !mounted) return;
    await run(() async {
      if (action == 'remove') {
        final next = [...more]..removeAt(index - 1);
        await patch({'morePostImageReferences': next}, 'Foto removida.');
        more = next;
        moreBytes = [...moreBytes]..removeAt(index - 1);
        count = 1 + more.length;
        return;
      }
      List<int>? bytes;
      if (action == 'adjust') {
        final current =
            (index == 0 ? coverBytes : moreBytes[index - 1]) ??
            await widget.photoLoader(widget.gateway, widget.postId, index);
        if (current == null) {
          message = 'Não foi possível abrir a foto agora. Tente de novo.';
          return;
        }
        if (!mounted) return;
        bytes = await widget.photoEditor(context, current);
      } else {
        bytes = await pickNew();
      }
      if (bytes == null || !mounted) return;
      final reference = await upload(bytes);
      if (reference == null) return;
      final done = action == 'adjust' ? 'Foto ajustada.' : 'Foto trocada.';
      if (index == 0) {
        await patch({'postImageReference': reference}, done);
        coverBytes = bytes;
        coverRevision++;
      } else {
        final next = [...more]..[index - 1] = reference;
        await patch({'morePostImageReferences': next}, done);
        more = next;
        moreBytes = [...moreBytes]..[index - 1] = bytes;
      }
    });
  }

  Future<void> addPhoto() => run(() async {
    final bytes = await pickNew();
    if (bytes == null || !mounted) return;
    final reference = await upload(bytes);
    if (reference == null) return;
    final next = [...more, reference];
    await patch({'morePostImageReferences': next}, 'Foto incluída.');
    more = next;
    moreBytes = [...moreBytes, bytes];
    count = 1 + more.length;
  });

  /// Marcar pessoas: o mesmo seletor da publicação da corrida; grava na hora.
  Future<void> tagPeople() async {
    final picked = await widget.tagPicker(context, widget.gateway, tagged);
    if (picked == null || !mounted) return;
    await run(() async {
      await patch({
        'taggedUserIds': [for (final p in picked) p['id']],
      }, 'Marcações salvas.');
      tagged = picked;
    });
  }

  Future<void> saveText() => run(() async {
    await patch({
      'postText': text.text.trim().isEmpty ? null : text.text.trim(),
    }, 'Texto da publicação salvo.');
  });

  Widget thumb(int index) {
    final bytes = index == 0 ? coverBytes : moreBytes[index - 1];
    return bytes != null
        ? Image.memory(
            Uint8List.fromList(bytes),
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black12),
          )
        : MedalPhoto(
            key: ValueKey('extra-photo-$index-$coverRevision'),
            gateway: widget.gateway,
            participationId: null,
            endpoint: index == 0 ? '$base/image' : '$base/image?index=$index',
            size: 28,
          );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Editar publicação')),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : failed
        ? Center(
            key: const Key('extra-post-load-failed'),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Não foi possível abrir a publicação agora. Verifique a internet e tente de novo.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    key: const Key('extra-post-retry'),
                    onPressed: load,
                    child: const Text('Tentar de novo'),
                  ),
                ],
              ),
            ),
          )
        : ListView(
            padding: const EdgeInsets.all(20),
            children: [
              PostPhotosEditor(
                photos: [
                  thumb(0),
                  if (refsKnown)
                    for (var i = 1; i <= more.length; i++) thumb(i),
                ],
                hiddenMore: refsKnown ? 0 : count - 1,
                busy: busy,
                onOpen: openPhoto,
                onAdd: addPhoto,
              ),
              const SizedBox(height: 16),
              // Igual à edição da publicação da corrida.
              OutlinedButton.icon(
                key: const Key('tag-people'),
                onPressed: busy ? null : tagPeople,
                icon: const Icon(Icons.local_offer_outlined),
                label: Text(
                  tagged.isEmpty
                      ? 'Marcar pessoas'
                      : 'Marcados: ${tagged.map((p) => '@${p['username']}').join(', ')}',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('extra-post-text'),
                controller: text,
                maxLength: 500,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Texto da publicação',
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: const Key('extra-post-save'),
                  onPressed: busy ? null : saveText,
                  child: const Text('Salvar texto'),
                ),
              ),
              if (busy) const LinearProgressIndicator(),
              if (message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(message!, key: const Key('extra-post-message')),
                ),
            ],
          ),
  );
}
