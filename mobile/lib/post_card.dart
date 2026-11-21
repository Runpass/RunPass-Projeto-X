import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'catalog_screen.dart'
    show EditionScreen, ParticipationDraftScreen, catalogError;
import 'extra_post_edit.dart';
import 'friends.dart';
import 'identity_gateway.dart';
import 'my_races.dart';
import 'tagged_people.dart';
import 'undo_delete.dart' show deleteWithUndo, pendingDeletions;
import 'post_stats.dart';
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

  /// Quantas fotos a publicação tem (até 5; a primeira é a capa). Sem a informação, uma.
  int get photoCount {
    final count = (race.participation['postImageCount'] as num?)?.toInt() ?? 1;
    return count < 1 ? 1 : (count > 5 ? 5 : count);
  }

  /// Endereço da foto [index] da publicação (0 é a capa, o mesmo de [photoEndpoint]).
  String? photoEndpointAt(int index) {
    final base = photoEndpoint;
    if (base == null || index == 0) return base;
    return '$base?index=$index';
  }

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
  if (post['postImageCount'] is num) {
    participation['postImageCount'] = post['postImageCount'];
  }
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
  required String distance,
  required String time,
  required String pace,
  Uint8List? photoBytes,
  Uint8List? medalBytes,
  MedalFrame? medalFrame,
});
ShareCardBuilder shareCardBuilder = buildShareCard;

const double _cardSide = 1080;
// Nome da corrida em cima, a foto de ponta a ponta no meio (na proporção dela) e, embaixo, só as
// informações e a marca.
const double _cardHeaderHeight = 190;
const double _cardFooterHeight = 380;
// Logo do rodapé, em tamanho de marca (o dobro do que era).
const double _cardLogoHeight = 112;

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
  required String distance,
  required String time,
  required String pace,
  Uint8List? photoBytes,
  Uint8List? medalBytes,
  MedalFrame? medalFrame,
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

  // Fundo branco com o texto preto: o nome da corrida e os números.
  void bg(Rect rect, {Color color = Colors.white}) =>
      canvas.drawRect(rect, Paint()..color = color);

  void text(
    String value,
    double y,
    double size, {
    FontWeight weight = FontWeight.w700,
    Color color = Colors.black,
    int maxLines = 2,
    String? family,
    // Altura da faixa em que o texto fica centralizado na vertical (a partir de [y]); sem ela, começa em [y].
    double? centerIn,
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
    final top = centerIn == null ? y : y + (centerIn - painter.height) / 2;
    painter.paint(canvas, Offset((_cardSide - painter.width) / 2, top));
  }

  // Cabeçalho: só o nome da corrida.
  bg(const Rect.fromLTWH(0, 0, _cardSide, _cardHeaderHeight));
  // Centralizado na faixa do cabeçalho, na horizontal e na vertical (com uma ou duas linhas).
  text(title, 0, 56, weight: FontWeight.w900, centerIn: _cardHeaderHeight);

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
    // Sem foto: um quadro cinza-claro separa o troféu do cabeçalho e do rodapé brancos.
    bg(photoRect, color: const Color(0xfff1f2f5));
    text(
      String.fromCharCode(Icons.emoji_events.codePoint),
      photoRect.top + photoRect.height / 2 - 130,
      260,
      color: runPassGold,
      family: Icons.emoji_events.fontFamily,
      maxLines: 1,
    );
  }

  // A medalha, com a moldura do modelo escolhido, no canto de baixo da foto.
  if (medalBytes != null && medalFrame != null) {
    await _drawMedal(canvas, photoRect, medalBytes, medalFrame);
  }

  // Rodapé: distância, tempo e pace, cada um com o seu ícone (sempre os três, com "--" quando falta o
  // dado) e, embaixo, o logo.
  final footerTop = _cardHeaderHeight + photoHeight;
  bg(Rect.fromLTWH(0, footerTop, _cardSide, _cardFooterHeight));
  void stat(double centerX, IconData icon, String value, String label) {
    final iconPainter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontSize: 56,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          color: runPassOrange,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    iconPainter.paint(
      canvas,
      Offset(centerX - iconPainter.width / 2, footerTop + 30),
    );
    for (final (y, size, weight, content) in [
      (100.0, 44.0, FontWeight.w800, value),
      (156.0, 28.0, FontWeight.w500, label),
    ]) {
      final painter = TextPainter(
        text: TextSpan(
          text: content,
          style: TextStyle(
            fontSize: size,
            fontWeight: weight,
            color: Colors.black,
          ),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: _cardSide / 3 - 40);
      painter.paint(canvas, Offset(centerX - painter.width / 2, footerTop + y));
    }
  }

  stat(_cardSide / 6, statDistanceIcon, distance, 'Distância');
  stat(_cardSide / 2, statTimeIcon, time, 'Tempo');
  stat(_cardSide * 5 / 6, statPaceIcon, pace, 'Pace');
  // Logo da marca na versão para fundo claro; sem o asset carregar por algum
  // motivo, cai para o texto "+1Pódio".
  final logo = await _loadAssetImage('assets/brand/logo-light.png');
  if (logo != null) {
    const logoHeight = _cardLogoHeight;
    final logoWidth = logo.width * (logoHeight / logo.height);
    canvas.drawImageRect(
      logo,
      Rect.fromLTWH(0, 0, logo.width.toDouble(), logo.height.toDouble()),
      Rect.fromLTWH(
        (_cardSide - logoWidth) / 2,
        footerTop + _cardFooterHeight - logoHeight - 34,
        logoWidth,
        logoHeight,
      ),
      Paint(),
    );
  } else {
    text(
      '+1Pódio',
      footerTop + _cardFooterHeight - _cardLogoHeight - 34,
      88,
      weight: FontWeight.w900,
      color: runPassOrange,
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

  /// Dois toques na foto curtem (como no Instagram): só curte, nunca descurte, e mostra um coração.
  bool heartVisible = false;

  Future<void> likeByDoubleTap() async {
    if (entry.postId == null) return;
    setState(() => heartVisible = true);
    Future<void>.delayed(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => heartVisible = false);
    });
    if (!entry.liked) await toggleLike();
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
  /// Publicação extra: edita as fotos e o texto (a corrida fica).
  Future<void> editExtra() async {
    if (entry.postId == null) return;
    // Fotos (capa e as a mais) e texto da publicação extra, na mesma tela.
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ExtraPostEditScreen(
          gateway: widget.gateway,
          postId: entry.postId!,
          version: entry.version ?? 1,
          text: entry.comment,
          tagged: entry.tagged,
        ),
      ),
    );
    if (mounted) widget.onChanged?.call();
  }

  Future<void> editMine() async {
    if (entry.extra) return editExtra();
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    // O feed traz só a parte pública da participação. O editor precisa dela inteira (número de peito, texto,
    // "exibir tempo", fotos a mais): abrir com a parte pública faria o salvar apagar o que faltava.
    final Map<String, dynamic> full;
    try {
      full = await widget.gateway.request(
        '/participations/${Uri.encodeComponent('${entry.race.participation['id']}')}',
      );
    } on Exception {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Não foi possível abrir a publicação agora. Tente de novo.',
          ),
        ),
      );
      return;
    }
    await navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => ParticipationDraftScreen(
          gateway: widget.gateway,
          initial: {...full, 'taggedProfiles': entry.tagged},
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

  /// Foto da MEDALHA (o recorte da prateleira, quando houver; senão a foto inteira), para desenhar com a
  /// moldura na imagem de compartilhar. Sem acesso, sem rede ou demora: nulo (a imagem sai sem a medalha).
  Future<Uint8List?> _fetchMedalBytes() async {
    final id = entry.race.participation['id'];
    if (id is! String) return null;
    final kind = entry.race.medalDisplayImageReference != null
        ? 'display-image'
        : 'image';
    return _fetchBytes('/participations/${Uri.encodeComponent(id)}/$kind');
  }

  /// Bytes da foto da medalha pelo link assinado; sem foto, sem rede ou demora, retorna nulo
  /// (o cartao e montado sem foto nesse caso, nao se compartilha a foto crua sozinha).
  /// Foto do carrossel que está na tela (0 é a capa): é a que vai na imagem de compartilhar.
  int shownPhoto = 0;

  Future<Uint8List?> _fetchPhotoBytes() async {
    final endpoint = entry.photoCount > 1 && entry.race.hasPostImage
        ? entry.photoEndpointAt(shownPhoto.clamp(0, entry.photoCount - 1))
        : entry.photoEndpoint;
    if (endpoint == null) return null;
    return _fetchBytes(endpoint);
  }

  /// Baixa uma imagem do app pelo link assinado; sem acesso, sem rede ou demora, nulo.
  Future<Uint8List?> _fetchBytes(String endpoint) async {
    try {
      // O endereço pode trazer `?index=N` (a foto N de uma publicação com várias).
      final parts = Uri.parse(endpoint);
      final reply = await widget.gateway
          .request(
            parts.path,
            query: parts.queryParameters.isEmpty ? null : parts.queryParameters,
          )
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
    final medalBytes = await _fetchMedalBytes();
    final card = await shareCardBuilder(
      title: entry.title,
      distance: entry.race.kilometers == null
          ? statEmpty
          : formatKilometers(entry.race.kilometers!),
      time: entry.race.timeSeconds == null
          ? statEmpty
          : formatDuration(entry.race.timeSeconds!),
      pace: entry.race.paceSecondsPerKm == null
          ? statEmpty
          : formatPace(entry.race.paceSecondsPerKm!),
      photoBytes: photoBytes,
      medalBytes: medalBytes,
      medalFrame: medalBytes == null
          ? null
          : medalFrameFor(entry.race.medalFrameId),
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
          // Junto do título, antes da foto e nesta ordem: o texto da publicação e, depois, distância, tempo e
          // pace, que aparecem sempre (com "--" quando faltam) para manter o mesmo padrão.
          Padding(
            key: Key('post-summary-${entry.postId}'),
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (entry.comment != null)
                  Text(entry.comment!, key: Key('post-text-${entry.postId}')),
                if (entry.comment != null) const SizedBox(height: 10),
                PostStats(
                  distance: km == null ? null : formatKilometers(km),
                  time: race.timeSeconds == null
                      ? null
                      : formatDuration(race.timeSeconds!),
                  pace: race.paceSecondsPerKm == null
                      ? null
                      : formatPace(race.paceSecondsPerKm!),
                  placement: race.placement == null
                      ? null
                      : '${race.placement}º',
                ),
              ],
            ),
          ),
          // Foto de ponta a ponta do cartão, no quadro da própria proporção da foto (de 4:5 a 1,91:1), sem
          // faixas pretas e sem cortar.
          AspectRatio(
            aspectRatio: postPhotoFrameRatio(_postPhotoAspects[aspectKey]),
            child: GestureDetector(
              key: Key('post-photo-double-tap-${entry.postId}'),
              onDoubleTap: likeByDoubleTap,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  entry.photoCount > 1 && entry.race.hasPostImage
                      ? PostPhotoCarousel(
                          key: Key('post-photo-${entry.postId}'),
                          gateway: widget.gateway,
                          entry: entry,
                          onPage: (index) => shownPhoto = index,
                          onAspect: (aspect) {
                            if (_postPhotoAspects[aspectKey] == aspect) return;
                            setState(
                              () => _postPhotoAspects[aspectKey] = aspect,
                            );
                          },
                        )
                      : MedalPhoto(
                          key: Key('post-photo-${entry.postId}'),
                          gateway: widget.gateway,
                          participationId:
                              entry.race.participation['id'] as String?,
                          endpoint: entry.extra ? entry.photoEndpoint : null,
                          size: 72,
                          usePostImage: entry.race.hasPostImage,
                          fit: BoxFit.cover,
                          onAspect: (aspect) {
                            if (_postPhotoAspects[aspectKey] == aspect) return;
                            setState(
                              () => _postPhotoAspects[aspectKey] = aspect,
                            );
                          },
                        ),
                  // Coração ao curtir com dois toques.
                  IgnorePointer(
                    child: Center(
                      child: AnimatedOpacity(
                        opacity: heartVisible ? 1 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: AnimatedScale(
                          scale: heartVisible ? 1 : 0.6,
                          duration: const Duration(milliseconds: 200),
                          child: const Icon(
                            Icons.favorite,
                            key: Key('double-tap-heart'),
                            color: Colors.white,
                            size: 96,
                            shadows: [
                              Shadow(blurRadius: 12, color: Colors.black45),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
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

/// Publicação com várias fotos (até 5): uma por vez, deslizando para o lado, com bolinhas e "2/5" no canto.
/// O quadro segue a proporção da primeira foto (a capa), para o cartão não mudar de tamanho ao deslizar.
class PostPhotoCarousel extends StatefulWidget {
  final IdentityGateway gateway;
  final FeedEntry entry;
  final ValueChanged<double>? onAspect;

  /// Foto que está na tela (0 é a capa), para compartilhar a que a pessoa está vendo.
  final ValueChanged<int>? onPage;
  const PostPhotoCarousel({
    super.key,
    required this.gateway,
    required this.entry,
    this.onAspect,
    this.onPage,
  });

  @override
  State<PostPhotoCarousel> createState() => _PostPhotoCarouselState();
}

class _PostPhotoCarouselState extends State<PostPhotoCarousel> {
  int page = 0;

  @override
  Widget build(BuildContext context) {
    final count = widget.entry.photoCount;
    final participationId = widget.entry.race.participation['id'] as String?;
    return Stack(
      fit: StackFit.expand,
      children: [
        PageView.builder(
          key: const Key('post-photo-pages'),
          itemCount: count,
          onPageChanged: (index) {
            setState(() => page = index);
            widget.onPage?.call(index);
          },
          itemBuilder: (context, index) => MedalPhoto(
            key: Key('post-photo-page-$index'),
            gateway: widget.gateway,
            participationId: participationId,
            endpoint: widget.entry.photoEndpointAt(index),
            size: 72,
            usePostImage: true,
            fit: BoxFit.cover,
            onAspect: index == 0 ? widget.onAspect : null,
          ),
        ),
        Positioned(
          top: 10,
          right: 10,
          child: Container(
            key: const Key('post-photo-counter'),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '${page + 1}/$count',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 8,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < count; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: i == page ? 8 : 6,
                  height: i == page ? 8 : 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i == page ? Colors.white : Colors.white54,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Desenha a medalha (a foto da medalha dentro do furo e a moldura do modelo por cima) no canto inferior
/// direito da foto. Sem conseguir abrir a foto ou a moldura, não desenha nada (a imagem sai sem a medalha).
Future<void> _drawMedal(
  Canvas canvas,
  Rect photoRect,
  Uint8List medalBytes,
  MedalFrame frame,
) async {
  ui.Image? medal;
  try {
    final codec = await ui.instantiateImageCodec(medalBytes);
    medal = (await codec.getNextFrame()).image;
  } on Object {
    return;
  }
  final art = await _loadAssetImage(frame.asset);
  if (art == null) return;
  final height = (photoRect.height * 0.42).clamp(220.0, 440.0);
  final width = height * frame.aspectRatio;
  const margin = 28.0;
  final box = Rect.fromLTWH(
    photoRect.right - width - margin,
    photoRect.bottom - height - margin,
    width,
    height,
  );
  // Furo da moldura, nas coordenadas da caixa.
  final Path hole;
  if (frame.shape == MedalHoleShape.polygon) {
    hole = medalHolePath(frame, box.size).shift(box.topLeft);
  } else {
    final holeW = frame.holeHalfWidthFrac * width * 2;
    final holeH = frame.holeHalfHeightFrac * width * 2;
    final left = box.left + frame.holeCenterXFrac * width - holeW / 2;
    final top = box.top + frame.holeCenterYFrac * width - holeH / 2;
    hole = medalHolePath(frame, Size(holeW, holeH)).shift(Offset(left, top));
  }
  // Sombra leve para a medalha se destacar da foto.
  canvas.drawPath(
    hole,
    Paint()
      ..color = const Color(0x66000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
  );
  canvas.save();
  canvas.clipPath(hole);
  final bounds = hole.getBounds();
  canvas.drawImageRect(
    medal,
    _coverSrcRect(medal, bounds),
    bounds,
    Paint()..filterQuality = FilterQuality.high,
  );
  canvas.restore();
  canvas.drawImageRect(
    art,
    Rect.fromLTWH(0, 0, art.width.toDouble(), art.height.toDouble()),
    box,
    Paint()..filterQuality = FilterQuality.high,
  );
}
