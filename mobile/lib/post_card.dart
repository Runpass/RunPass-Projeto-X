import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'catalog_screen.dart'
    show EditionScreen, ParticipationDraftScreen, catalogError;
import 'friends.dart';
import 'identity_gateway.dart';
import 'my_races.dart';
import 'tagged_people.dart';
import 'undo_delete.dart' show deleteWithUndo, pendingDeletions;
import 'runpass_theme.dart';

/// Um cartao do Inicio. Vem de uma publicacao (`/feed`, `/posts/{id}`) ou de uma corrida
/// concluida da propria pessoa que ainda nao esta no feed.
class FeedEntry {
  final String? postId;
  final String author, username, title;
  final String? comment, place;
  final DateTime? publishedAt;
  final RaceRecord race;
  final bool mine;
  final Map? authorProfile;
  final Map? lastComment;
  final List<Map<String, dynamic>> tagged;
  int likes, comments;
  bool liked;

  /// Publicação extra (outra foto da mesma corrida): foto, edição e remoção são da publicação, não da
  /// participação.
  final bool extra;
  final int? version;

  FeedEntry({
    required this.postId,
    required this.author,
    required this.username,
    required this.title,
    required this.race,
    required this.mine,
    this.authorProfile,
    this.lastComment,
    this.tagged = const [],
    this.comment,
    this.place,
    this.publishedAt,
    this.likes = 0,
    this.comments = 0,
    this.liked = false,
    this.extra = false,
    this.version,
  });

  /// Endereço da foto: a da publicação extra, a da publicação ou a da medalha.
  String? get photoEndpoint {
    if (extra && postId != null) {
      return '/posts/${Uri.encodeComponent(postId!)}/image';
    }
    final id = race.participation['id'] as String?;
    if (id == null) return null;
    return '/participations/${Uri.encodeComponent(id)}/${race.hasPostImage ? 'post-image' : 'image'}';
  }
}

/// Monta o cartao a partir de uma publicacao da API.
FeedEntry entryFromPost(
  Map<String, dynamic> post,
  Map<String, dynamic>? edition,
  String? myId,
) {
  final participation = Map<String, dynamic>.from(
    post['participation'] as Map? ?? const {},
  );
  final author = Map<String, dynamic>.from(post['author'] as Map? ?? const {});
  participation['hasPostImage'] = post['hasPostImage'] == true;
  final race = RaceRecord(participation, edition);
  return FeedEntry(
    postId: post['id'] as String?,
    author: author['displayName'] as String? ?? 'Corredor',
    username: author['username'] as String? ?? '',
    title: race.name,
    comment: post['comment'] as String?,
    place: race.place.isEmpty ? null : race.place,
    publishedAt: DateTime.tryParse(post['publishedAt'] as String? ?? ''),
    race: race,
    mine: myId != null && author['id'] == myId,
    authorProfile: author,
    lastComment: post['lastComment'] as Map?,
    tagged: [
      for (final person in (post['tagged'] as List? ?? const []))
        Map<String, dynamic>.from(person as Map),
    ],
    likes: (post['likeCount'] as num?)?.toInt() ?? 0,
    comments: (post['commentCount'] as num?)?.toInt() ?? 0,
    liked: post['likedByMe'] == true,
    extra: post['extra'] == true,
    version: (post['version'] as num?)?.toInt(),
  );
}

/// Proporção do quadro da foto no feed, como no Instagram: a da própria foto, entre 4:5 (retrato) e
/// 1,91:1 (paisagem). Assim a foto aparece inteira, sem faixas pretas; só passa disso é que corta.
const double postPhotoMinRatio = 4 / 5;
const double postPhotoMaxRatio = 1.91;
double postPhotoFrameRatio(double? aspect) =>
    (aspect ?? postPhotoMinRatio).clamp(postPhotoMinRatio, postPhotoMaxRatio);

/// Proporção já descoberta de cada foto (por endereço e versão), para o quadro não pular ao rolar o feed.
final Map<String, double> _postPhotoAspects = {};

/// Abre a folha de compartilhamento do sistema. Trocavel nos testes.
typedef ShareFunction = Future<ShareResult> Function(ShareParams params);
ShareFunction shareFunction = (params) => SharePlus.instance.share(params);

/// Monta a imagem da publicacao para compartilhar. Trocavel nos testes.
typedef ShareCardBuilder = Future<Uint8List> Function({
  required String title,
  required String line,
  Uint8List? photoBytes,
});
ShareCardBuilder shareCardBuilder = buildShareCard;

const double _cardSide = 1080;
// Nome da corrida em cima, a foto de ponta a ponta no meio (na proporção dela) e, embaixo, só as
// informações e a marca.
const double _cardHeaderHeight = 190;
const double _cardFooterHeight = 260;

/// Carrega um asset de imagem (ex. a logo da marca) como ui.Image, para desenhar no canvas.
Future<ui.Image?> _loadAssetImage(String path) async {
  try {
    final bytes = await rootBundle.load(path);
    final codec = await ui.instantiateImageCodec(bytes.buffer.asUint8List());
    return (await codec.getNextFrame()).image;
  } on Object {
    return null;
  }
}

/// Parte da imagem de origem que preenche o retângulo de destino sem distorcer, cortando o excesso
/// (sem faixas pretas).
Rect _coverSrcRect(ui.Image image, Rect dst) {
  final srcAspect = image.width / image.height;
  final dstAspect = dst.width / dst.height;
  if (srcAspect > dstAspect) {
    final w = image.height * dstAspect;
    return Rect.fromLTWH((image.width - w) / 2, 0, w, image.height.toDouble());
  }
  final h = image.width / dstAspect;
  return Rect.fromLTWH(0, (image.height - h) / 2, image.width.toDouble(), h);
}

/// Imagem para compartilhar: o nome da corrida em cima, a foto de ponta a ponta (sem faixas pretas, no
/// quadro da própria proporção dela, de 4:5 a 1,91:1) e, embaixo, só as informações (km, tempo, pace) e o
/// logo. Sem curtir, comentar, marcar nem compartilhar, e sem o nome de quem publicou. Garante que o
/// compartilhamento sempre leve uma imagem, que é o que Instagram e Facebook aceitam.
Future<Uint8List> buildShareCard({
  required String title,
  required String line,
  Uint8List? photoBytes,
}) async {
  ui.Image? photo;
  if (photoBytes != null) {
    try {
      final codec = await ui.instantiateImageCodec(photoBytes);
      photo = (await codec.getNextFrame()).image;
    } on Object {
      photo = null;
    }
  }
  // Altura da foto: a da própria proporção (de 4:5 a 1,91:1); sem foto, 4:5.
  final ratio = postPhotoFrameRatio(
    photo == null ? null : photo.width / photo.height,
  );
  final photoHeight = (_cardSide / ratio).roundToDouble();
  final totalHeight = _cardHeaderHeight + photoHeight + _cardFooterHeight;

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, _cardSide, totalHeight));

  void bg(Rect rect) => canvas.drawRect(
    rect,
    Paint()
      ..shader = ui.Gradient.linear(
        rect.topLeft,
        rect.bottomRight,
        [runPassNavy, const Color(0xff5a2a1c), runPassOrange],
        // ui.Gradient.linear (ao contrario do LinearGradient do widget) exige
        // colorStops explicito quando ha mais de 2 cores, senao lanca
        // ArgumentError sempre que chamado.
        const [0.0, 0.5, 1.0],
      ),
  );

  void text(
    String value,
    double y,
    double size, {
    FontWeight weight = FontWeight.w700,
    Color color = Colors.white,
    int maxLines = 2,
    String? family,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
          fontSize: size,
          fontWeight: weight,
          color: color,
          fontFamily: family,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      maxLines: maxLines,
      ellipsis: '…',
    )..layout(maxWidth: _cardSide - 160);
    painter.paint(canvas, Offset((_cardSide - painter.width) / 2, y));
  }

  // Cabeçalho: só o nome da corrida.
  bg(const Rect.fromLTWH(0, 0, _cardSide, _cardHeaderHeight));
  text(title, 34, 56, weight: FontWeight.w900);

  // Foto de ponta a ponta; sem foto, usa um marcador no lugar.
  final photoRect = Rect.fromLTWH(0, _cardHeaderHeight, _cardSide, photoHeight);
  if (photo != null) {
    canvas.drawImageRect(
      photo,
      _coverSrcRect(photo, photoRect),
      photoRect,
      Paint()..filterQuality = FilterQuality.high,
    );
  } else {
    bg(photoRect);
    text(
      String.fromCharCode(Icons.emoji_events.codePoint),
      photoRect.top + photoRect.height / 2 - 130,
      260,
      color: runPassGold,
      family: Icons.emoji_events.fontFamily,
      maxLines: 1,
    );
  }

  // Rodapé: as informações da corrida (quando houver) e o logo.
  final footerTop = _cardHeaderHeight + photoHeight;
  bg(Rect.fromLTWH(0, footerTop, _cardSide, _cardFooterHeight));
  if (line.isNotEmpty) {
    text(
      line,
      footerTop + 40,
      48,
      weight: FontWeight.w700,
      color: runPassGold,
      maxLines: 1,
    );
  }
  // Logo da marca (versao clara, p/ contrastar com o fundo escuro); sem o
  // asset carregar por algum motivo, cai para o texto "+1Pódio".
  final logo = await _loadAssetImage('assets/brand/logo-dark.png');
  if (logo != null) {
    const logoHeight = 56.0;
    final logoWidth = logo.width * (logoHeight / logo.height);
    canvas.drawImageRect(
      logo,
      Rect.fromLTWH(0, 0, logo.width.toDouble(), logo.height.toDouble()),
      Rect.fromLTWH(
        (_cardSide - logoWidth) / 2,
        footerTop + _cardFooterHeight - 90,
        logoWidth,
        logoHeight,
      ),
      Paint(),
    );
  } else {
    text(
      '+1Pódio',
      footerTop + _cardFooterHeight - 90,
      48,
      weight: FontWeight.w900,
      color: runPassGold,
      maxLines: 1,
    );
  }

  final image = await recorder.endRecording().toImage(
    _cardSide.toInt(),
    totalHeight.toInt(),
  );
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

/// Linha de números da imagem de compartilhamento: km, tempo e pace (só o que houver).
String shareLineOf(RaceRecord race) {
  final km = race.kilometers;
  return [
    if (km != null) formatKilometers(km),
    if (race.timeSeconds != null) formatDuration(race.timeSeconds!),
    if (race.paceSecondsPerKm != null) formatPace(race.paceSecondsPerKm!),
  ].join(' · ');
}

class PostCard extends StatefulWidget {
  final IdentityGateway gateway;
  final FeedEntry entry;

  /// Chamado ao voltar de comentarios ou perfil, para a tela de origem recarregar.
  final VoidCallback? onChanged;

  /// Chamado depois de remover a minha publicação (ex.: fechar a tela da publicação). Não recarrega a lista.
  final VoidCallback? onRemoved;
  const PostCard({
    super.key,
    required this.gateway,
    required this.entry,
    this.onChanged,
    this.onRemoved,
  });

  @override
  State<PostCard> createState() => _PostCardState();
}

class _PostCardState extends State<PostCard> {
  FeedEntry get entry => widget.entry;

  void soon(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> toggleLike() async {
    final id = entry.postId;
    if (id == null) return;
    final wasLiked = entry.liked;
    setState(() {
      entry.liked = !wasLiked;
      entry.likes += wasLiked ? -1 : 1;
    });
    try {
      await widget.gateway.request(
        '/posts/${Uri.encodeComponent(id)}/like',
        method: wasLiked ? 'DELETE' : 'PUT',
      );
    } on Exception {
      if (!mounted) return;
      setState(() {
        entry.liked = wasLiked;
        entry.likes += wasLiked ? 1 : -1;
      });
      soon('Não foi possível atualizar a curtida.');
    }
  }

  Future<void> openComments() async {
    final id = entry.postId;
    if (id == null) {
      soon(
        'Publique a conquista ao concluir a corrida para receber comentários.',
      );
      return;
    }
    String? myId;
    try {
      myId = (await widget.gateway.request('/me'))['id'] as String?;
    } on Exception {
      myId = null;
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CommentsScreen(
          gateway: widget.gateway,
          postId: id,
          title: entry.title,
          myId: myId,
          postIsMine: entry.mine,
        ),
      ),
    );
    widget.onChanged?.call();
  }

  bool removed = false;

  /// Editar a minha publicação: abre a participação concluída (tempo, foto, avaliação e comentário).
  /// Publicação extra: edita só o texto (a foto e a corrida ficam).
  Future<void> editExtra() async {
    final controller = TextEditingController(text: entry.comment ?? '');
    final text = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Editar publicação'),
        content: TextField(
          key: const Key('extra-post-text'),
          controller: controller,
          maxLength: 500,
          minLines: 1,
          maxLines: 4,
          decoration: const InputDecoration(labelText: 'Texto da publicação'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            key: const Key('extra-post-save'),
            onPressed: () => Navigator.pop(dialog, controller.text.trim()),
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || !mounted || entry.postId == null) return;
    try {
      await widget.gateway.request(
        '/posts/${Uri.encodeComponent(entry.postId!)}/extra',
        method: 'PATCH',
        body: {'expectedVersion': entry.version ?? 1, 'postText': text},
      );
      soon('Publicação atualizada.');
      widget.onChanged?.call();
    } on IdentityIssue catch (issue) {
      soon(catalogError(issue));
    } on Exception {
      soon('Não foi possível salvar agora.');
    }
  }

  Future<void> editMine() async {
    if (entry.extra) return editExtra();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ParticipationDraftScreen(
          gateway: widget.gateway,
          initial: {
            ...entry.race.participation,
            'taggedProfiles': entry.tagged,
          },
          fromPost: true,
        ),
      ),
    );
    widget.onChanged?.call();
  }

  /// Remover a minha publicação, com "Desfazer". A publicação nasce da participação concluída, então remover
  /// exclui a participação e a medalha dela. A publicação extra sai sozinha (a corrida, a medalha e a outra
  /// publicação continuam). O cartão some na hora; a exclusão só vai ao servidor quando a janela do
  /// "Desfazer" fecha.
  Future<void> removeMine() async {
    final participation = entry.race.participation;
    final participationId = participation['id'] as String?;
    final id = entry.extra ? entry.postId : participationId;
    if (id == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final onRemoved = widget.onRemoved;
    try {
      final done = await deleteWithUndo(
        context,
        id: id,
        message: entry.extra
            ? 'Publicação removida.'
            : 'Publicação removida, com a participação e a medalha.',
        hide: () {
          setState(() => removed = true);
          onRemoved?.call();
        },
        restore: () {
          if (mounted) setState(() => removed = false);
        },
        perform: () => entry.extra
            ? widget.gateway.request(
                '/posts/${Uri.encodeComponent(id)}',
                method: 'DELETE',
              )
            : deleteParticipation(widget.gateway, id),
      );
      // A exclusão termina no servidor em segundo plano (202): até lá o item ainda pode voltar numa
      // recarga. Fica escondido em todas as listas (Início, perfil e medalhas) até o app fechar.
      if (done) pendingDeletions.add(id);
    } on IdentityIssue catch (issue) {
      if (mounted) setState(() => removed = false);
      messenger.showSnackBar(SnackBar(content: Text(catalogError(issue))));
    } on Exception {
      if (mounted) setState(() => removed = false);
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Não foi possível remover agora. Nada foi alterado.'),
        ),
      );
    }
  }

  /// Atalho do ícone de marcar (só na minha publicação): abre o seletor de pessoas e grava as marcações.
  Future<void> tagPeople() async {
    final messenger = ScaffoldMessenger.of(context);
    final picked = await pickTaggedPeople(
      context,
      widget.gateway,
      entry.tagged,
    );
    if (picked == null || !mounted) return;
    final participation = entry.race.participation;
    final ids = [for (final p in picked) p['id']];
    try {
      if (entry.extra && entry.postId != null) {
        await widget.gateway.request(
          '/posts/${Uri.encodeComponent(entry.postId!)}/extra',
          method: 'PATCH',
          body: {'expectedVersion': entry.version ?? 1, 'taggedUserIds': ids},
        );
      } else {
        await widget.gateway.request(
          '/participations/${Uri.encodeComponent('${participation['id']}')}',
          method: 'PATCH',
          body: {
            'expectedVersion': participation['version'],
            'taggedUserIds': ids,
          },
        );
      }
      messenger.showSnackBar(
        const SnackBar(content: Text('Marcações salvas.')),
      );
      widget.onChanged?.call();
    } on IdentityIssue catch (issue) {
      messenger.showSnackBar(SnackBar(content: Text(catalogError(issue))));
    } on Exception {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Não foi possível salvar as marcações agora. Tente de novo.',
          ),
        ),
      );
    }
  }

  /// Foto do autor: abre o perfil (de outra pessoa, com o botao de seguir).
  Future<void> openProfile() async {
    final id = entry.authorProfile?['id'] as String?;
    if (id == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => entry.mine
            ? RunnerProfileScreen(gateway: widget.gateway)
            : PublicProfileScreen(
                gateway: widget.gateway,
                profileId: id,
                initial: Map<String, dynamic>.from(entry.authorProfile!),
              ),
      ),
    );
    widget.onChanged?.call();
  }

  String shareLine() => shareLineOf(entry.race);

  /// Texto da publicacao para compartilhar (WhatsApp, e-mail, Instagram, Facebook...).
  String shareText() {
    final km = entry.race.kilometers;
    final who = entry.mine ? 'Eu concluí' : '${entry.author} concluiu';
    return [
      '$who ${entry.title}${km == null ? '' : ' (${formatKilometers(km)})'} 🏅',
      if (entry.comment != null && entry.comment!.isNotEmpty) entry.comment!,
      'Veja no +1Pódio.',
    ].join('\n');
  }

  /// Grava os bytes num arquivo real (cache do app) em vez de usar XFile.fromData: o share_plus
  /// documenta que compartilhar bytes em memoria direto e menos confiavel no Android/iOS.
  Future<XFile> _writeShareFile(
    Uint8List bytes,
    String mimeType,
    String name,
  ) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(bytes, flush: true);
    return XFile(file.path, mimeType: mimeType, name: name);
  }

  /// Bytes da foto da medalha pelo link assinado; sem foto, sem rede ou demora, retorna nulo
  /// (o cartao e montado sem foto nesse caso, nao se compartilha a foto crua sozinha).
  Future<Uint8List?> _fetchPhotoBytes() async {
    final endpoint = entry.photoEndpoint;
    if (endpoint == null) return null;
    try {
      final reply = await widget.gateway
          .request(endpoint)
          .timeout(const Duration(seconds: 6));
      final url = Uri.tryParse(reply['url'] as String? ?? '');
      if (url == null || url.scheme != 'https') return null;
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 6);
      try {
        final response = await (await client.getUrl(url))
            .close()
            .timeout(const Duration(seconds: 10));
        if (response.statusCode != 200) return null;
        final bytes = await response
            .fold<List<int>>([], (all, chunk) => all..addAll(chunk))
            .timeout(const Duration(seconds: 15));
        return Uint8List.fromList(bytes);
      } finally {
        client.close(force: true);
      }
    } on Object {
      return null;
    }
  }

  /// Monta a imagem para compartilhar: a foto, o nome da corrida e as informações, com o logo.
  /// Nada de curtir, comentar, marcar ou compartilhar na imagem.
  Future<XFile> shareImage() async {
    soon('Preparando para compartilhar...');
    final photoBytes = await _fetchPhotoBytes();
    final card = await shareCardBuilder(
      title: entry.title,
      line: shareLine(),
      photoBytes: photoBytes,
    );
    return _writeShareFile(card, 'image/png', 'runpass.png');
  }

  Future<void> share() async {
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    final text = shareText();
    try {
      final image = await shareImage();
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      // Sem texto junto da imagem: apps da Meta (Instagram, Facebook) nao
      // tratam bem o envio combinado e caem para o modo so-texto, que so
      // oferece "Mensagens"/Direct em vez de Stories/Feed.
      await shareFunction(
        ShareParams(
          files: [image],
          fileNameOverrides: [image.name],
          sharePositionOrigin: origin,
        ),
      );
    } on Object {
      // Alguns apps recusam anexo: tenta de novo so com o texto.
      try {
        await shareFunction(
          ShareParams(text: text, sharePositionOrigin: origin),
        );
      } on Object catch (error) {
        soon(
          'Não foi possível abrir o compartilhamento (${error.runtimeType}).',
        );
      }
    }
  }

  Widget statItem(IconData icon, String value, String label) => Expanded(
    child: Row(
      children: [
        Icon(icon, size: 22),
        const SizedBox(width: 6),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).hintColor,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  /// Comentario mais recente em destaque; os demais ficam atras do botao de comentarios.
  Widget lastCommentBox() {
    final comment = entry.lastComment!;
    final who = comment['author'] as Map? ?? const {};
    final dark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      key: Key('last-comment-${entry.postId}'),
      onTap: openComments,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: dark ? const Color(0xff2b2415) : const Color(0xfffff6e0),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: runPassGold.withValues(alpha: 0.6)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ProfileAvatar(gateway: widget.gateway, profile: who, radius: 15),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    who['displayName'] as String? ?? 'Corredor',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                    ),
                  ),
                  Text(
                    comment['text'] as String? ?? '',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (entry.comments > 1)
                    Text(
                      'Ver todos os ${entry.comments} comentários',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).hintColor,
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

  @override
  Widget build(BuildContext context) {
    if (removed) return const SizedBox.shrink();
    final race = entry.race;
    final km = race.kilometers;
    final aspectKey = '${entry.photoEndpoint}#${entry.version}';
    final subtitle = [
      if (entry.publishedAt != null) timeAgo(entry.publishedAt!),
      if (entry.place != null) entry.place!,
    ].join('  •  ');
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Cabeçalho: quem publicou, quando e onde.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 12),
            child: Row(
              children: [
                InkWell(
                  key: Key('post-author-${entry.postId}'),
                  onTap: openProfile,
                  borderRadius: BorderRadius.circular(40),
                  child: ProfileAvatar(
                    gateway: widget.gateway,
                    profile: entry.authorProfile,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: InkWell(
                    onTap: openProfile,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.author,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        if (subtitle.isNotEmpty)
                          Text(
                            subtitle,
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).hintColor,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (entry.mine)
                  PopupMenuButton<String>(
                    key: Key('post-menu-${entry.postId}'),
                    tooltip: 'Opções da publicação',
                    icon: const Icon(Icons.more_horiz),
                    onSelected: (value) =>
                        value == 'edit' ? editMine() : removeMine(),
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        key: Key('post-menu-edit'),
                        value: 'edit',
                        child: Text('Editar'),
                      ),
                      PopupMenuItem(
                        key: Key('post-menu-remove'),
                        value: 'remove',
                        child: Text('Remover'),
                      ),
                    ],
                  )
                else
                  const Icon(Icons.more_horiz),
              ],
            ),
          ),
          // Nome da corrida acima da foto (tocar abre as informações da corrida).
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: InkWell(
                key: Key('post-race-${entry.postId}'),
                borderRadius: BorderRadius.circular(6),
                onTap: entry.race.participation['editionId'] is String
                    ? () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => EditionScreen(
                            gateway: widget.gateway,
                            editionId:
                                entry.race.participation['editionId'] as String,
                          ),
                        ),
                      )
                    : null,
                child: Text(
                  entry.title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 17,
                  ),
                ),
              ),
            ),
          ),
          // Foto de ponta a ponta do cartão, no quadro da própria proporção da foto (de 4:5 a 1,91:1), sem
          // faixas pretas e sem cortar.
          AspectRatio(
            aspectRatio: postPhotoFrameRatio(_postPhotoAspects[aspectKey]),
            child: MedalPhoto(
              key: Key('post-photo-${entry.postId}'),
              gateway: widget.gateway,
              participationId: entry.race.participation['id'] as String?,
              endpoint: entry.extra ? entry.photoEndpoint : null,
              size: 72,
              usePostImage: entry.race.hasPostImage,
              fit: BoxFit.cover,
              onAspect: (aspect) {
                if (_postPhotoAspects[aspectKey] == aspect) return;
                setState(() => _postPhotoAspects[aspectKey] = aspect);
              },
            ),
          ),
          // Ações logo abaixo da foto e, depois, a legenda (prova, texto, números e último comentário).
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    InkWell(
                      onTap: entry.postId == null ? null : toggleLike,
                      child: Row(
                        children: [
                          Icon(
                            entry.liked
                                ? Icons.favorite
                                : Icons.favorite_border,
                            color: runPassOrange,
                          ),
                          const SizedBox(width: 6),
                          Text('${entry.likes}'),
                        ],
                      ),
                    ),
                    const SizedBox(width: 22),
                    InkWell(
                      onTap: openComments,
                      child: Row(
                        children: [
                          const Icon(Icons.chat_bubble_outline),
                          const SizedBox(width: 6),
                          Text('${entry.comments}'),
                        ],
                      ),
                    ),
                    // Pessoas marcadas: ao lado direito dos comentários, abre o pop-up com os perfis.
                    // Na minha publicação o ícone aparece sempre e é um atalho para marcar alguém.
                    if ((entry.tagged.isNotEmpty || entry.mine) &&
                        entry.postId != null) ...[
                      const SizedBox(width: 22),
                      TaggedLink(
                        gateway: widget.gateway,
                        postId: entry.postId!,
                        tagged: entry.tagged,
                        onTag: entry.mine ? tagPeople : null,
                      ),
                    ],
                    const SizedBox(width: 12),
                    const Spacer(),
                    Semantics(
                      label: 'Compartilhar',
                      button: true,
                      child: InkWell(
                        key: Key('share-${entry.race.participation['id']}'),
                        onTap: share,
                        customBorder: const CircleBorder(),
                        child: const Padding(
                          padding: EdgeInsets.all(8),
                          child: Tooltip(
                            message: 'Compartilhar',
                            child: Icon(Icons.ios_share, size: 22),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (entry.comment != null) ...[
                  const SizedBox(height: 6),
                  Text(entry.comment!),
                ],
                if (km != null ||
                    race.timeSeconds != null ||
                    race.paceSecondsPerKm != null) ...[
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      if (km != null)
                        statItem(
                          Icons.directions_run,
                          formatKilometers(km),
                          'Distância',
                        ),
                      if (race.timeSeconds != null)
                        statItem(
                          Icons.timer_outlined,
                          formatDuration(race.timeSeconds!),
                          'Tempo',
                        ),
                      if (race.paceSecondsPerKm != null)
                        statItem(
                          Icons.speed,
                          formatPace(race.paceSecondsPerKm!),
                          'Pace',
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 14),
                if (entry.lastComment != null) lastCommentBox(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Uma publicacao aberta por um aviso: o cartao completo, curtir, comentar, compartilhar e
/// tocar no autor para ver o perfil.
/// Miniatura de uma publicacao (medalha e nome da prova) para grades de 3 por linha, como no
/// perfil. Tocar abre a publicacao inteira (curtir, comentar, editar, excluir).
class PostThumb extends StatelessWidget {
  final IdentityGateway gateway;
  final FeedEntry entry;

  /// Chamado ao voltar da publicacao, para a tela de origem recarregar.
  final VoidCallback? onChanged;
  const PostThumb({
    super.key,
    required this.gateway,
    required this.entry,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      button: true,
      label: 'Abrir publicação ${entry.title}',
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: entry.postId == null
            ? null
            : () async {
                await Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        PostScreen(gateway: gateway, postId: entry.postId!),
                  ),
                );
                onChanged?.call();
              },
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: dark
                  ? const [Color(0xff3a2a22), Color(0xff2a211c)]
                  : const [Color(0xffffd9cc), Color(0xfffff2ec)],
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              fit: StackFit.expand,
              children: [
                MedalPhoto(
                  gateway: gateway,
                  participationId: entry.race.participation['id'] as String?,
                  endpoint: entry.extra ? entry.photoEndpoint : null,
                  size: 40,
                  usePostImage: entry.race.hasPostImage,
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 4,
                    ),
                    color: Colors.black54,
                    child: Text(
                      entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class PostScreen extends StatefulWidget {
  final IdentityGateway gateway;
  final String postId;
  const PostScreen({super.key, required this.gateway, required this.postId});

  @override
  State<PostScreen> createState() => _PostScreenState();
}

class _PostScreenState extends State<PostScreen> {
  FeedEntry? entry;
  String? error;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final post = await widget.gateway.request(
        '/posts/${Uri.encodeComponent(widget.postId)}',
      );
      String? myId;
      try {
        myId = (await widget.gateway.request('/me'))['id'] as String?;
      } on Exception {
        myId = null;
      }
      final editionId =
          (post['participation'] as Map?)?['editionId'] as String?;
      final editions = editionId == null
          ? <String, Map<String, dynamic>>{}
          : await loadEditions(widget.gateway, [editionId]);
      if (mounted) {
        setState(() {
          entry = entryFromPost(post, editions[editionId], myId);
          error = null;
        });
      }
    } on IdentityIssue catch (issue) {
      if (mounted) setState(() => error = friendsError(issue));
    } on Exception {
      if (mounted) {
        setState(() => error = friendsError(const IdentityIssue('')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Publicação')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (error != null) Text(error!, key: const Key('post-error')),
        if (entry == null && error == null)
          const Center(child: CircularProgressIndicator()),
        if (entry != null)
          PostCard(
            gateway: widget.gateway,
            entry: entry!,
            onChanged: load,
            onRemoved: () => Navigator.of(context).maybePop(),
          ),
      ],
    ),
  );
}

/// Exclui a participação (com a publicação e a medalha) usando a versão atual do servidor, não a da tela:
/// marcar pessoas ou editar o texto muda a versão, e a versão antiga seria recusada (VERSION_CONFLICT).
Future<void> deleteParticipation(IdentityGateway gateway, String id) async {
  final path = '/participations/${Uri.encodeComponent(id)}';
  final current = await gateway.request(path);
  await gateway.request(
    path,
    method: 'DELETE',
    query: {'expectedVersion': '${current['version']}'},
  );
}
