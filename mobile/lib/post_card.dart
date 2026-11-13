import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'catalog_screen.dart' show EditionScreen;
import 'friends.dart';
import 'identity_gateway.dart';
import 'my_races.dart';
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
  int likes, comments;
  bool liked;

  FeedEntry({
    required this.postId,
    required this.author,
    required this.username,
    required this.title,
    required this.race,
    required this.mine,
    this.authorProfile,
    this.lastComment,
    this.comment,
    this.place,
    this.publishedAt,
    this.likes = 0,
    this.comments = 0,
    this.liked = false,
  });
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
    likes: (post['likeCount'] as num?)?.toInt() ?? 0,
    comments: (post['commentCount'] as num?)?.toInt() ?? 0,
    liked: post['likedByMe'] == true,
  );
}

/// Abre a folha de compartilhamento do sistema. Trocavel nos testes.
typedef ShareFunction = Future<ShareResult> Function(ShareParams params);
ShareFunction shareFunction = (params) => SharePlus.instance.share(params);

/// Imagem usada quando a medalha nao tem foto (ou nao foi possivel baixa-la). Trocavel nos testes.
typedef ShareCardBuilder = Future<Uint8List> Function({
  required String title,
  required String line,
  required String author,
});
ShareCardBuilder shareCardBuilder = buildShareCard;

/// Cartao quadrado com trofeu, nome da corrida e distancia/tempo. Garante que o compartilhamento
/// sempre leve uma imagem, que e o que Instagram e Facebook aceitam.
Future<Uint8List> buildShareCard({
  required String title,
  required String line,
  required String author,
}) async {
  const side = 1080.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, side, side));
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, side, side),
    Paint()
      ..shader = ui.Gradient.linear(Offset.zero, const Offset(side, side), [
        runPassNavy,
        const Color(0xff5a2a1c),
        runPassOrange,
      ]),
  );
  void text(
    String value,
    double y,
    double size, {
    FontWeight weight = FontWeight.w700,
    Color color = Colors.white,
    int maxLines = 3,
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
    )..layout(maxWidth: side - 160);
    painter.paint(canvas, Offset((side - painter.width) / 2, y));
  }

  text(
    String.fromCharCode(Icons.emoji_events.codePoint),
    150,
    300,
    color: runPassGold,
    family: Icons.emoji_events.fontFamily,
  );
  text(title, 520, 76, weight: FontWeight.w900);
  if (line.isNotEmpty) {
    text(line, 760, 56, weight: FontWeight.w500, maxLines: 1);
  }
  text(
    author,
    850,
    44,
    weight: FontWeight.w500,
    color: Colors.white70,
    maxLines: 1,
  );
  text(
    '+1Pódio',
    950,
    56,
    weight: FontWeight.w900,
    color: runPassGold,
    maxLines: 1,
  );
  final image = await recorder.endRecording().toImage(1080, 1080);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

class PostCard extends StatefulWidget {
  final IdentityGateway gateway;
  final FeedEntry entry;

  /// Chamado ao voltar de comentarios ou perfil, para a tela de origem recarregar.
  final VoidCallback? onChanged;
  const PostCard({
    super.key,
    required this.gateway,
    required this.entry,
    this.onChanged,
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

  String shareLine() {
    final race = entry.race;
    final km = race.kilometers;
    return [
      if (km != null) formatKilometers(km),
      if (race.timeSeconds != null) formatDuration(race.timeSeconds!),
    ].join(' · ');
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

  /// Foto da medalha pelo link assinado; sem foto, sem rede ou demora, usa o cartao desenhado.
  Future<XFile> shareImage() async {
    final id = entry.race.participation['id'] as String?;
    try {
      if (id == null) throw const IdentityIssue('NO_ID');
      final reply = await widget.gateway
          .request('/participations/${Uri.encodeComponent(id)}/image')
          .timeout(const Duration(seconds: 6));
      final url = Uri.tryParse(reply['url'] as String? ?? '');
      if (url == null || url.scheme != 'https') {
        throw const IdentityIssue('NO_URL');
      }
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 6);
      try {
        final response = await (await client.getUrl(url))
            .close()
            .timeout(const Duration(seconds: 10));
        if (response.statusCode != 200) {
          throw const IdentityIssue('NO_IMAGE');
        }
        final bytes = await response
            .fold<List<int>>([], (all, chunk) => all..addAll(chunk))
            .timeout(const Duration(seconds: 15));
        final type = reply['contentType'] as String? ?? 'image/jpeg';
        return XFile.fromData(
          Uint8List.fromList(bytes),
          mimeType: type,
          name: type == 'image/png' ? 'medalha.png' : 'medalha.jpg',
        );
      } finally {
        client.close(force: true);
      }
    } on Object {
      final card = await shareCardBuilder(
        title: entry.title,
        line: shareLine(),
        author: entry.mine ? '' : entry.author,
      );
      return XFile.fromData(card, mimeType: 'image/png', name: 'runpass.png');
    }
  }

  Future<void> share() async {
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    soon('Preparando para compartilhar...');
    final text = shareText();
    try {
      final image = await shareImage();
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      await shareFunction(
        ShareParams(
          text: text,
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
    final race = entry.race;
    final km = race.kilometers;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final subtitle = [
      if (entry.publishedAt != null) timeAgo(entry.publishedAt!),
      if (entry.place != null) entry.place!,
    ].join('  •  ');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
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
                const Icon(Icons.more_horiz),
              ],
            ),
            const SizedBox(height: 12),
            // Em negrito, sem sublinhado: tocar no nome da corrida abre as informações dela.
            InkWell(
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
                'concluiu ${entry.title}',
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 17,
                ),
              ),
            ),
            if (entry.comment != null) ...[
              const SizedBox(height: 6),
              Text(entry.comment!),
            ],
            const SizedBox(height: 12),
            AspectRatio(
              aspectRatio: 16 / 10,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: dark
                        ? const [Color(0xff3a2a22), Color(0xff2a211c)]
                        : const [Color(0xffffd9cc), Color(0xfffff2ec)],
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: SizedBox.expand(
                    child: MedalPhoto(
                      gateway: widget.gateway,
                      participationId:
                          entry.race.participation['id'] as String?,
                      size: 72,
                    ),
                  ),
                ),
              ),
            ),
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
            Row(
              children: [
                InkWell(
                  onTap: entry.postId == null ? null : toggleLike,
                  child: Row(
                    children: [
                      Icon(
                        entry.liked ? Icons.favorite : Icons.favorite_border,
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
                const Spacer(),
                InkWell(
                  key: Key('share-${entry.race.participation['id']}'),
                  onTap: share,
                  child: const Row(
                    children: [
                      Icon(Icons.ios_share, size: 20),
                      SizedBox(width: 6),
                      Text('Compartilhar'),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
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
                  size: 40,
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
          PostCard(gateway: widget.gateway, entry: entry!, onChanged: load),
      ],
    ),
  );
}
