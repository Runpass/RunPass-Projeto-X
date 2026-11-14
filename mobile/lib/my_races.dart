import 'dart:async';
import 'dart:io';
import 'dart:math' show max;
import 'dart:typed_data' show Uint8List;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'catalog_screen.dart';
import 'catalog_views.dart';
import 'edition_cards.dart';
import 'edit_profile.dart';
import 'friends.dart';
import 'grid_columns.dart';
import 'identity_gateway.dart';
import 'location_picker.dart';
import 'medal_scan.dart';
import 'pending_medals.dart';
import 'notifications.dart';
import 'post_card.dart' show FeedEntry, PostCard, PostThumb, entryFromPost;
import 'profile_photo.dart';
import 'runpass_theme.dart';
import 'settings.dart';

/// "15/03/1995 • 18 anos", so quando GET /me devolve birthDate (so para o proprio
/// titular; nunca em perfil publico). Nulo se ausente ou mal formatada.
String? birthDateLabel(String? isoBirthDate) {
  final birth = isoBirthDate == null ? null : DateTime.tryParse(isoBirthDate);
  if (birth == null) return null;
  final today = DateTime.now();
  var age = today.year - birth.year;
  if (today.month < birth.month ||
      (today.month == birth.month && today.day < birth.day)) {
    age--;
  }
  final formatted =
      '${birth.day.toString().padLeft(2, '0')}/${birth.month.toString().padLeft(2, '0')}/${birth.year}';
  return '$formatted  •  $age anos';
}

/// A completed participation joined with the official edition it refers to.
class RaceRecord {
  final Map<String, dynamic> participation;
  final Map<String, dynamic>? edition;
  const RaceRecord(this.participation, this.edition);

  String get name =>
      edition?['name'] as String? ?? 'Corrida ${participation['editionId']}';
  String? get date => edition?['date'] as String?;
  int? get year => date == null ? null : int.tryParse(date!.substring(0, 4));
  static const noCity = 'Sem cidade';

  /// "São Paulo/SP", para agrupar as medalhas por cidade visitada.
  String get cityLabel {
    final city = edition?['city'] as String?;
    if (city == null || city.isEmpty) return noCity;
    final state = edition?['state'] as String?;
    return state == null || state.isEmpty ? city : '$city/$state';
  }

  String get place {
    final city = edition?['city'] as String?;
    final state = edition?['state'] as String?;
    if (city == null) return '';
    return state == null ? city : '$city - $state';
  }

  double? get kilometers {
    for (final distance
        in (edition?['distances'] as List? ?? const []).cast<Map>()) {
      if (distance['id'] == participation['distanceId']) {
        return (distance['kilometers'] as num?)?.toDouble();
      }
    }
    return null;
  }

  num? get timeSeconds => participation['timeSeconds'] as num?;
  num? get paceSecondsPerKm => participation['paceSecondsPerKm'] as num?;

  // Customizacao da medalha na prateleira: cada campo tem o dado do catalogo
  // como padrao e so usa o valor salvo quando a pessoa o personalizou.
  String get medalFrameId =>
      participation['medalFrameId'] as String? ?? defaultMedalFrameId;
  String? get medalDisplayImageReference =>
      participation['medalDisplayImageReference'] as String?;
  String get medalDescription =>
      participation['medalDescription'] as String? ?? name;
  String get medalCity =>
      participation['medalCity'] as String? ??
      (edition?['city'] as String? ?? '');
  String get medalState =>
      participation['medalState'] as String? ??
      (edition?['state'] as String? ?? '');
  int? get medalYear => (participation['medalYear'] as num?)?.toInt() ?? year;
  String get medalPlace => medalCity.isEmpty
      ? ''
      : medalState.isEmpty
      ? medalCity
      : '$medalCity - $medalState';
}

/// Catalogo fixo de modelos de medalha: cada imagem ja traz a forma, o metal
/// e a fita prontos, com um furo transparente onde a foto do usuario aparece.
/// As fracoes do furo sao medidas sobre a propria imagem (uma unica vez,
/// offline) e expressas como fracao da LARGURA da imagem — usando a mesma
/// unidade nos dois eixos, a geometria fica correta em qualquer tamanho de
/// tela, desde que a imagem seja exibida respeitando sua proporcao nativa.
enum MedalHoleShape { circle, hexagon, roundedSquare, polygon }

class MedalFrame {
  final String id;
  final String label;
  final String asset;
  final double aspectRatio; // largura / altura da imagem
  final MedalHoleShape shape;
  final double holeCenterXFrac;
  final double holeCenterYFrac;
  final double holeHalfWidthFrac;
  final double holeHalfHeightFrac;
  // Usado so quando shape == roundedSquare: fracao do raio do canto em
  // relacao a largura do furo.
  final double cornerRadiusFrac;
  // Usado so quando shape == polygon: contorno exato do furo, medido sobre
  // o canal alpha da imagem, em fracao da LARGURA da imagem (mesma unidade
  // nos dois eixos, igual ao resto da geometria desta classe).
  final List<Offset>? holeOutlineFrac;
  const MedalFrame({
    required this.id,
    required this.label,
    required this.asset,
    required this.aspectRatio,
    required this.shape,
    this.holeCenterXFrac = 0,
    this.holeCenterYFrac = 0,
    this.holeHalfWidthFrac = 0,
    this.holeHalfHeightFrac = 0,
    this.cornerRadiusFrac = 0,
    this.holeOutlineFrac,
  });
}

const defaultMedalFrameId = 'circular_prata_azul';

const medalFrames = <MedalFrame>[
  MedalFrame(
    id: 'circular_prata_azul',
    label: 'Circular · prata/azul',
    asset: 'assets/medal_frames/circular_prata_azul.png',
    aspectRatio: 1200 / 1600,
    shape: MedalHoleShape.circle,
    holeCenterXFrac: 0.5000,
    holeCenterYFrac: 0.8167,
    holeHalfWidthFrac: 0.3100,
    holeHalfHeightFrac: 0.3100,
  ),
  MedalFrame(
    id: 'circular_rose_rosa',
    label: 'Circular · rosé/rosa',
    asset: 'assets/medal_frames/circular_rose_rosa.png',
    aspectRatio: 1200 / 1600,
    shape: MedalHoleShape.circle,
    holeCenterXFrac: 0.5000,
    holeCenterYFrac: 0.8167,
    holeHalfWidthFrac: 0.3100,
    holeHalfHeightFrac: 0.3100,
  ),
  MedalFrame(
    id: 'circular_grafite_preto',
    label: 'Circular · grafite/preto',
    asset: 'assets/medal_frames/circular_grafite_preto.png',
    aspectRatio: 1200 / 1600,
    shape: MedalHoleShape.circle,
    holeCenterXFrac: 0.5000,
    holeCenterYFrac: 0.8167,
    holeHalfWidthFrac: 0.3100,
    holeHalfHeightFrac: 0.3100,
  ),
  MedalFrame(
    id: 'hexagonal_bronze_verde',
    label: 'Hexagonal · bronze/verde',
    asset: 'assets/medal_frames/hexagonal_bronze_verde.png',
    aspectRatio: 1200 / 1600,
    shape: MedalHoleShape.hexagon,
    holeCenterXFrac: 0.5000,
    holeCenterYFrac: 0.8167,
    holeHalfWidthFrac: 0.3705,
    holeHalfHeightFrac: 0.3090,
  ),
  MedalFrame(
    id: 'hexagonal_rose_lilas',
    label: 'Hexagonal · rosé/lilás',
    asset: 'assets/medal_frames/hexagonal_rose_lilas.png',
    aspectRatio: 1200 / 1600,
    shape: MedalHoleShape.hexagon,
    holeCenterXFrac: 0.5000,
    holeCenterYFrac: 0.8167,
    holeHalfWidthFrac: 0.3705,
    holeHalfHeightFrac: 0.3090,
  ),
  MedalFrame(
    id: 'quadrada_rose_malva',
    label: 'Quadrada · rosé/malva',
    asset: 'assets/medal_frames/quadrada_rose_malva.png',
    aspectRatio: 1200 / 1600,
    shape: MedalHoleShape.roundedSquare,
    holeCenterXFrac: 0.5000,
    holeCenterYFrac: 0.8167,
    holeHalfWidthFrac: 0.3100,
    holeHalfHeightFrac: 0.3100,
    cornerRadiusFrac: 0.14,
  ),
  MedalFrame(
    id: 'escudo_grafite_azul',
    label: 'Escudo · grafite/azul',
    asset: 'assets/medal_frames/escudo_grafite_azul.png',
    aspectRatio: 1200 / 1600,
    shape: MedalHoleShape.polygon,
    holeOutlineFrac: [
      Offset(0.4996, 0.5087),
      Offset(0.3237, 0.5367),
      Offset(0.2178, 0.5767),
      Offset(0.2162, 0.6167),
      Offset(0.2162, 0.6567),
      Offset(0.2178, 0.6967),
      Offset(0.2203, 0.7367),
      Offset(0.2253, 0.7767),
      Offset(0.2320, 0.8167),
      Offset(0.2420, 0.8558),
      Offset(0.2553, 0.8958),
      Offset(0.2737, 0.9358),
      Offset(0.2978, 0.9758),
      Offset(0.3303, 1.0158),
      Offset(0.3728, 1.0558),
      Offset(0.4312, 1.0958),
      Offset(0.4996, 1.1238),
      Offset(0.5680, 1.0958),
      Offset(0.6263, 1.0558),
      Offset(0.6688, 1.0158),
      Offset(0.7013, 0.9758),
      Offset(0.7255, 0.9358),
      Offset(0.7438, 0.8958),
      Offset(0.7572, 0.8558),
      Offset(0.7672, 0.8167),
      Offset(0.7738, 0.7767),
      Offset(0.7788, 0.7367),
      Offset(0.7813, 0.6967),
      Offset(0.7830, 0.6567),
      Offset(0.7830, 0.6167),
      Offset(0.7813, 0.5767),
      Offset(0.6755, 0.5367),
    ],
  ),
  MedalFrame(
    id: 'assimetrica_prata_lima',
    label: 'Assimétrica · prata/lima',
    asset: 'assets/medal_frames/assimetrica_prata_lima.png',
    aspectRatio: 1200 / 1600,
    shape: MedalHoleShape.polygon,
    holeOutlineFrac: [
      Offset(0.4988, 0.5078),
      Offset(0.3737, 0.5275),
      Offset(0.3220, 0.5600),
      Offset(0.2870, 0.5917),
      Offset(0.2595, 0.6242),
      Offset(0.2395, 0.6558),
      Offset(0.2245, 0.6875),
      Offset(0.2128, 0.7200),
      Offset(0.2045, 0.7517),
      Offset(0.1995, 0.7842),
      Offset(0.1978, 0.8158),
      Offset(0.1995, 0.8475),
      Offset(0.2037, 0.8800),
      Offset(0.2103, 0.9117),
      Offset(0.2212, 0.9442),
      Offset(0.2362, 0.9758),
      Offset(0.2553, 1.0075),
      Offset(0.2812, 1.0400),
      Offset(0.3162, 1.0717),
      Offset(0.3687, 1.1042),
      Offset(0.4729, 1.1238),
      Offset(0.4647, 1.1042),
      Offset(0.4705, 1.0717),
      Offset(0.4805, 1.0400),
      Offset(0.4938, 1.0075),
      Offset(0.5122, 0.9758),
      Offset(0.5363, 0.9442),
      Offset(0.5680, 0.9117),
      Offset(0.6088, 0.8800),
      Offset(0.6680, 0.8475),
      Offset(0.8005, 0.8158),
      Offset(0.7988, 0.7842),
      Offset(0.7947, 0.7517),
      Offset(0.7863, 0.7200),
      Offset(0.7755, 0.6875),
      Offset(0.7605, 0.6558),
      Offset(0.7413, 0.6242),
      Offset(0.7147, 0.5917),
      Offset(0.6805, 0.5600),
      Offset(0.6288, 0.5275),
    ],
  ),
  MedalFrame(
    id: 'triangular_grafite_preto',
    label: 'Triangular · grafite/preto',
    asset: 'assets/medal_frames/triangular_grafite_preto.png',
    aspectRatio: 1200 / 1600,
    shape: MedalHoleShape.polygon,
    holeOutlineFrac: [
      Offset(0.1912, 0.5078),
      Offset(0.1912, 0.5408),
      Offset(0.1912, 0.5867),
      Offset(0.1912, 0.6325),
      Offset(0.1912, 0.6775),
      Offset(0.2070, 0.7225),
      Offset(0.2412, 0.7683),
      Offset(0.2753, 0.8142),
      Offset(0.3087, 0.8592),
      Offset(0.3420, 0.9042),
      Offset(0.3762, 0.9500),
      Offset(0.4103, 0.9958),
      Offset(0.4437, 1.0408),
      Offset(0.4770, 1.0858),
      Offset(0.4996, 1.1197),
      Offset(0.5222, 1.0858),
      Offset(0.5555, 1.0408),
      Offset(0.5888, 0.9958),
      Offset(0.6230, 0.9500),
      Offset(0.6572, 0.9042),
      Offset(0.6905, 0.8592),
      Offset(0.7238, 0.8142),
      Offset(0.7580, 0.7683),
      Offset(0.7922, 0.7225),
      Offset(0.8080, 0.6775),
      Offset(0.8080, 0.6325),
      Offset(0.8080, 0.5867),
      Offset(0.8080, 0.5408),
      Offset(0.8080, 0.5078),
    ],
  ),
  MedalFrame(
    id: 'triangular_rose_rosa',
    label: 'Triangular · rosé/rosa',
    asset: 'assets/medal_frames/triangular_rose_rosa.png',
    aspectRatio: 1200 / 1600,
    shape: MedalHoleShape.polygon,
    holeOutlineFrac: [
      Offset(0.1912, 0.5078),
      Offset(0.1912, 0.5408),
      Offset(0.1912, 0.5867),
      Offset(0.1912, 0.6325),
      Offset(0.1912, 0.6775),
      Offset(0.2070, 0.7225),
      Offset(0.2412, 0.7683),
      Offset(0.2753, 0.8142),
      Offset(0.3087, 0.8592),
      Offset(0.3420, 0.9042),
      Offset(0.3762, 0.9500),
      Offset(0.4103, 0.9958),
      Offset(0.4437, 1.0408),
      Offset(0.4770, 1.0858),
      Offset(0.4996, 1.1197),
      Offset(0.5222, 1.0858),
      Offset(0.5555, 1.0408),
      Offset(0.5888, 0.9958),
      Offset(0.6230, 0.9500),
      Offset(0.6572, 0.9042),
      Offset(0.6905, 0.8592),
      Offset(0.7238, 0.8142),
      Offset(0.7580, 0.7683),
      Offset(0.7922, 0.7225),
      Offset(0.8080, 0.6775),
      Offset(0.8080, 0.6325),
      Offset(0.8080, 0.5867),
      Offset(0.8080, 0.5408),
      Offset(0.8080, 0.5078),
    ],
  ),
];

MedalFrame medalFrameFor(String? id) =>
    medalFrames.firstWhere((f) => f.id == id, orElse: () => medalFrames.first);

/// Recorte hexagonal (pontas na esquerda/direita, topo e base retos) usado
/// para encaixar a foto exatamente no furo dos modelos hexagonais.
class _HexagonHoleClipper extends CustomClipper<Path> {
  const _HexagonHoleClipper();
  @override
  Path getClip(Size size) {
    final w = size.width, h = size.height;
    return Path()
      ..moveTo(w, h / 2)
      ..lineTo(w * 0.75, 0)
      ..lineTo(w * 0.25, 0)
      ..lineTo(0, h / 2)
      ..lineTo(w * 0.25, h)
      ..lineTo(w * 0.75, h)
      ..close();
  }

  @override
  bool shouldReclip(covariant _HexagonHoleClipper oldClipper) => false;
}

/// Composicao da medalha na prateleira: a foto do usuario atras, recortada no
/// formato do furo, com a imagem do modelo (metal + fita) por cima.
Widget medalFrameWidget({required MedalFrame frame, required Widget photo}) =>
    AspectRatio(
      aspectRatio: frame.aspectRatio,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          // Contorno em polígono: medido direto sobre a imagem inteira, então
          // o recorte usa o Stack completo (sem sub-retângulo posicionado).
          if (frame.shape == MedalHoleShape.polygon) {
            return Stack(
              fit: StackFit.expand,
              children: [
                ClipPath(
                  clipper: _PolygonHoleClipper(frame.holeOutlineFrac!),
                  child: photo,
                ),
                Image.asset(frame.asset, fit: BoxFit.fill),
              ],
            );
          }
          final holeCx = frame.holeCenterXFrac * w;
          final holeCy = frame.holeCenterYFrac * w;
          final holeW = frame.holeHalfWidthFrac * w * 2;
          final holeH = frame.holeHalfHeightFrac * w * 2;
          return Stack(
            fit: StackFit.expand,
            children: [
              Positioned(
                left: holeCx - holeW / 2,
                top: holeCy - holeH / 2,
                width: holeW,
                height: holeH,
                child: ClipPath(
                  clipper: switch (frame.shape) {
                    MedalHoleShape.hexagon => const _HexagonHoleClipper(),
                    MedalHoleShape.roundedSquare => _RoundedSquareHoleClipper(
                      frame.cornerRadiusFrac,
                    ),
                    _ => const _CircleClipper(),
                  },
                  child: photo,
                ),
              ),
              Image.asset(frame.asset, fit: BoxFit.fill),
            ],
          );
        },
      ),
    );

class _CircleClipper extends CustomClipper<Path> {
  const _CircleClipper();
  @override
  Path getClip(Size size) =>
      Path()..addOval(Rect.fromLTWH(0, 0, size.width, size.height));
  @override
  bool shouldReclip(covariant _CircleClipper oldClipper) => false;
}

class _RoundedSquareHoleClipper extends CustomClipper<Path> {
  final double cornerRadiusFrac;
  const _RoundedSquareHoleClipper(this.cornerRadiusFrac);
  @override
  Path getClip(Size size) => Path()
    ..addRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, size.width, size.height),
        Radius.circular(size.width * cornerRadiusFrac),
      ),
    );
  @override
  bool shouldReclip(covariant _RoundedSquareHoleClipper oldClipper) =>
      oldClipper.cornerRadiusFrac != cornerRadiusFrac;
}

/// Recorte por contorno exato, medido sobre o canal alpha da imagem do
/// modelo (fracoes da LARGURA da imagem nos dois eixos). Usado para furos
/// com formato irregular (escudo, assimetrica) que um simples circulo/
/// hexagono nao reproduz sem sobrar foto fora do contorno metalico.
class _PolygonHoleClipper extends CustomClipper<Path> {
  final List<Offset> pointsFrac;
  const _PolygonHoleClipper(this.pointsFrac);
  @override
  Path getClip(Size size) {
    final w = size.width;
    final path = Path();
    for (var i = 0; i < pointsFrac.length; i++) {
      final p = pointsFrac[i] * w;
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    return path..close();
  }

  @override
  bool shouldReclip(covariant _PolygonHoleClipper oldClipper) => false;
}

/// Baixa os bytes de um link assinado (S3), para reabrir num editor de
/// recorte local. Lanca [IdentityIssue] se a resposta nao for 200.
Future<List<int>> fetchImageBytes(String url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client
        .getUrl(Uri.parse(url))
        .timeout(const Duration(seconds: 10));
    final response = await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw const IdentityIssue('IMAGE_NOT_VALID');
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
    }
    return bytes;
  } finally {
    client.close(force: true);
  }
}

String two(int value) => value.toString().padLeft(2, '0');

String formatDuration(num seconds) {
  final total = seconds.round();
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final rest = total % 60;
  return hours > 0
      ? '$hours:${two(minutes)}:${two(rest)}'
      : '${two(minutes)}:${two(rest)}';
}

String formatPace(num secondsPerKm) {
  final total = secondsPerKm.round();
  return '${total ~/ 60}:${two(total % 60)}/km';
}

String formatKilometers(double km) => km == km.roundToDouble()
    ? '${km.toInt()} km'
    : '${km.toStringAsFixed(1)} km';

String distanceLabel(double km) => '${km.round()}K';

/// Edition details by id. A lookup that fails is left out of the result.
Future<Map<String, Map<String, dynamic>>> loadEditions(
  IdentityGateway gateway,
  Iterable<String> ids,
) async {
  final editions = <String, Map<String, dynamic>>{};
  await Future.wait([
    for (final id in ids.toSet())
      () async {
        try {
          editions[id] = await gateway.request(
            '/editions/${Uri.encodeComponent(id)}',
          );
        } on Exception {
          // The caller still shows the item, only without edition details.
        }
      }(),
  ]);
  return editions;
}

String timeAgo(DateTime moment, {DateTime? now}) {
  final diff = (now ?? DateTime.now()).difference(moment);
  if (diff.inMinutes < 1) return 'agora';
  if (diff.inMinutes < 60) return 'há ${diff.inMinutes} min';
  if (diff.inHours < 24) {
    return 'há ${diff.inHours} ${diff.inHours == 1 ? 'hora' : 'horas'}';
  }
  if (diff.inDays < 7) {
    return 'há ${diff.inDays} ${diff.inDays == 1 ? 'dia' : 'dias'}';
  }
  final weeks = diff.inDays ~/ 7;
  return 'há $weeks ${weeks == 1 ? 'semana' : 'semanas'}';
}

/// Placeholder for official medal art, which the API does not serve yet.
class MedalArt extends StatelessWidget {
  final double size;
  const MedalArt({super.key, this.size = 46});

  @override
  Widget build(BuildContext context) =>
      Icon(Icons.emoji_events, size: size, color: const Color(0xffe8b23a));
}

/// Imagem privada servida por link curto e assinado (`GET <endpoint>` devolve `url`).
/// Sem foto, sem permissao ou sem rede, mostra o `fallback`.
class SignedPhoto extends StatefulWidget {
  final IdentityGateway gateway;
  final String? endpoint;
  final Widget fallback;
  final BoxFit fit;
  const SignedPhoto({
    super.key,
    required this.gateway,
    required this.endpoint,
    required this.fallback,
    this.fit = BoxFit.cover,
  });

  @override
  State<SignedPhoto> createState() => _SignedPhotoState();
}

/// Links valem 5 minutos; reaproveita enquanto a tela esta aberta.
final Map<String, ({String url, DateTime expires})> _photoLinks = {};

/// Esquece o link guardado, por exemplo depois de trocar a foto.
void forgetMedalPhoto(String participationId) => _photoLinks.remove(
  '/participations/${Uri.encodeComponent(participationId)}/image',
);

/// Esquece o link da foto da prateleira, depois de reposicionar/resetar.
void forgetMedalDisplayImage(String participationId) => _photoLinks.remove(
  '/participations/${Uri.encodeComponent(participationId)}/display-image',
);

void forgetBanner(String profileId) =>
    _photoLinks.remove('/profiles/${Uri.encodeComponent(profileId)}/banner');

void forgetProfilePhoto(String profileId) =>
    _photoLinks.remove('/profiles/${Uri.encodeComponent(profileId)}/photo');

class _SignedPhotoState extends State<SignedPhoto> {
  String? url;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final endpoint = widget.endpoint;
    if (endpoint == null) return;
    final cached = _photoLinks[endpoint];
    if (cached != null && cached.expires.isAfter(DateTime.now())) {
      url = cached.url;
      return;
    }
    try {
      final reply = await widget.gateway.request(endpoint);
      final link = reply['url'];
      final expires = DateTime.tryParse(reply['expiresAt'] as String? ?? '');
      if (link is String && link.startsWith('https://')) {
        _photoLinks[endpoint] = (
          url: link,
          expires: (expires ?? DateTime.now().add(const Duration(minutes: 4)))
              .subtract(const Duration(seconds: 30)),
        );
        if (mounted) setState(() => url = link);
      }
    } on Exception {
      // Sem foto ou sem rede: fica o fallback.
    }
  }

  @override
  Widget build(BuildContext context) {
    final link = url;
    if (link == null) return widget.fallback;
    return Image.network(
      link,
      fit: widget.fit,
      errorBuilder: (_, _, _) => widget.fallback,
      // frameBuilder (nao loadingBuilder): quando a imagem ja esta no cache
      // (por exemplo ao voltar para uma aba), o frame chega de forma
      // sincrona (wasSynchronouslyLoaded) e evita o lampejo do fallback por
      // um quadro a cada tela nova, mesmo com o link ja resolvido.
      frameBuilder: (_, child, frame, wasSynchronouslyLoaded) =>
          wasSynchronouslyLoaded || frame != null ? child : widget.fallback,
    );
  }
}

/// Foto da medalha enviada pela pessoa (`GET /participations/{id}/image`); sem foto, o trofeu.
/// Com [useDisplayImage], usa `/display-image`: o recorte reposicionado pela
/// pessoa so para a prateleira, quando existir (senao a mesma foto de sempre).
class MedalPhoto extends StatelessWidget {
  final IdentityGateway gateway;
  final String? participationId;
  final double size;
  final BoxFit fit;
  final bool useDisplayImage;
  const MedalPhoto({
    super.key,
    required this.gateway,
    required this.participationId,
    this.size = 46,
    this.fit = BoxFit.cover,
    this.useDisplayImage = false,
  });

  @override
  Widget build(BuildContext context) => SignedPhoto(
    gateway: gateway,
    endpoint: participationId == null
        ? null
        : '/participations/${Uri.encodeComponent(participationId!)}/'
              '${useDisplayImage ? 'display-image' : 'image'}',
    fallback: MedalArt(size: size),
    fit: fit,
  );
}

/// Detecta JPEG ou PNG pelos primeiros bytes; qualquer outro formato volta nulo.
String? imageContentType(List<int> bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[2] == 0xff) {
    return 'image/jpeg';
  }
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47) {
    return 'image/png';
  }
  return null;
}

class Stars extends StatelessWidget {
  final num value;
  final double size;
  const Stars(this.value, {super.key, this.size = 20});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var i = 1; i <= 5; i++)
        Icon(
          value >= i - 0.25
              ? Icons.star
              : value >= i - 0.75
              ? Icons.star_half
              : Icons.star_border,
          size: size,
          color: runPassGold,
        ),
    ],
  );
}

String decimalPt(num value) => value.toStringAsFixed(1).replaceAll('.', ',');

/// Every completed participation of the signed-in runner, newest edition first.
/// Edition lookups that fail leave the record without edition details.
Future<List<RaceRecord>> loadMyRaces(IdentityGateway gateway) async {
  final completed = <Map<String, dynamic>>[];
  String? cursor;
  var pages = 0;
  do {
    final page = await gateway.request(
      '/me/participations',
      query: {'state': 'completed', 'limit': '100', 'cursor': ?cursor},
    );
    completed.addAll(
      (page['items'] as List? ?? const []).cast<Map<String, dynamic>>().where(
        (item) => item['state'] == 'completed',
      ),
    );
    cursor = page['nextCursor'] as String?;
  } while (cursor != null && ++pages < 5);
  final editions = await loadEditions(gateway, [
    for (final p in completed) p['editionId'] as String,
  ]);
  final records = [
    for (final p in completed) RaceRecord(p, editions[p['editionId']]),
  ];
  records.sort((a, b) => (b.date ?? '').compareTo(a.date ?? ''));
  return records;
}

/// Achievements derived only from the runner's completed races. They are not
/// stored or awarded by the backend: a badge shows when the condition holds.
class Achievement {
  final String title, caption;
  final IconData icon;
  final Color color;
  const Achievement(this.title, this.caption, this.icon, this.color);
}

List<Achievement> achievementsOf(RaceStats stats) => [
  if (stats.cities > 0)
    Achievement(
      'Desbravador',
      '${stats.cities} ${stats.cities == 1 ? 'cidade' : 'cidades'}',
      Icons.landscape_outlined,
      const Color(0xff4cc38a),
    ),
  if ((stats.byDistance[5] ?? 0) > 0)
    const Achievement(
      'Primeiro Passo',
      '5K',
      Icons.looks_5_outlined,
      Color(0xffff9f2e),
    ),
  if ((stats.byDistance[10] ?? 0) > 0)
    const Achievement(
      'Ritmo Forte',
      '10K',
      Icons.filter_1_outlined,
      Color(0xff3fbf8a),
    ),
  if ((stats.byDistance[21] ?? 0) > 0)
    const Achievement(
      'Meio Caminho',
      '(21K)',
      Icons.star_outline,
      Color(0xff8a5cf6),
    ),
  if ((stats.byDistance[42] ?? 0) > 0)
    const Achievement(
      'Lenda da Maratona',
      '(42K)',
      Icons.workspace_premium_outlined,
      Color(0xffe8b23a),
    ),
];

/// Selo do perfil: conquistado ou bloqueado (ainda nao conquistado), com a dica de como
/// desbloquear. Sao todos os selos que existem hoje, derivados so das corridas concluidas.
class Seal {
  final Achievement item;
  final String label, hint;
  final bool earned;
  const Seal(this.item, this.label, this.hint, {required this.earned});
}

List<Seal> sealsOf(RaceStats stats) {
  bool did(double km) => (stats.byDistance[km] ?? 0) > 0;
  return [
    Seal(
      Achievement(
        'Desbravador',
        '${stats.cities} ${stats.cities == 1 ? 'cidade' : 'cidades'}',
        Icons.landscape_outlined,
        const Color(0xff4cc38a),
      ),
      'Desbravador',
      'Conclua uma prova em qualquer cidade.',
      earned: stats.cities > 0,
    ),
    Seal(
      const Achievement(
        'Primeiro Passo',
        '5K',
        Icons.looks_5_outlined,
        Color(0xffff9f2e),
      ),
      '5K',
      'Conclua uma prova de 5K.',
      earned: did(5),
    ),
    Seal(
      const Achievement(
        'Ritmo Forte',
        '10K',
        Icons.filter_1_outlined,
        Color(0xff3fbf8a),
      ),
      '10K',
      'Conclua uma prova de 10K.',
      earned: did(10),
    ),
    Seal(
      const Achievement(
        'Meio Caminho',
        '(21K)',
        Icons.star_outline,
        Color(0xff8a5cf6),
      ),
      '21K',
      'Conclua uma meia maratona (21K).',
      earned: did(21),
    ),
    Seal(
      const Achievement(
        'Lenda da Maratona',
        '(42K)',
        Icons.workspace_premium_outlined,
        Color(0xffe8b23a),
      ),
      '42K',
      'Conclua uma maratona (42K).',
      earned: did(42),
    ),
  ];
}

/// Círculo do selo: colorido quando conquistado; cinza, com o ícone apagado e um cadeado, quando bloqueado.
/// É o mesmo no perfil, em Medalhas > Conquistas e na folha de detalhes.
class SealAvatar extends StatelessWidget {
  final Seal seal;
  final double radius;
  const SealAvatar({super.key, required this.seal, this.radius = 17});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        CircleAvatar(
          radius: radius,
          backgroundColor: seal.earned
              ? seal.item.color
              : (dark ? Colors.white12 : Colors.black12),
          child: Icon(
            seal.item.icon,
            size: radius * 1.05,
            color: seal.earned
                ? Colors.white
                : (dark ? Colors.white38 : Colors.black38),
          ),
        ),
        if (!seal.earned)
          Positioned(
            right: -radius * 0.18,
            bottom: -radius * 0.18,
            child: Container(
              key: Key('seal-locked-${seal.label}'),
              padding: EdgeInsets.all(radius * 0.12),
              decoration: BoxDecoration(
                color: dark ? Colors.black54 : Colors.white,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.lock,
                size: radius * 0.6,
                color: dark ? Colors.white54 : Colors.black54,
              ),
            ),
          ),
      ],
    );
  }
}

/// Selo (conquistado ou bloqueado) com o ícone e a legenda curta. É o mesmo no perfil e em
/// Medalhas > Conquistas (lá, maior).
class SealBadge extends StatelessWidget {
  final Seal seal;
  final VoidCallback onTap;
  final double radius;
  const SealBadge({
    super.key,
    required this.seal,
    required this.onTap,
    this.radius = 17,
  });

  @override
  Widget build(BuildContext context) => Tooltip(
    message: seal.earned
        ? '${seal.item.title} ${seal.item.caption}'
        : 'Bloqueado: ${seal.hint}',
    child: InkWell(
      key: Key('seal-${seal.label}'),
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SealAvatar(seal: seal, radius: radius),
          SizedBox(height: radius * 0.2),
          Text(
            seal.label,
            style: TextStyle(
              fontSize: radius >= 26 ? 13 : 10,
              fontWeight: FontWeight.w700,
              color: seal.earned ? null : context.muted,
            ),
          ),
        ],
      ),
    ),
  );
}

/// Folha com todos os selos e como desbloquear cada um.
Future<void> showSealsSheet(BuildContext context, List<Seal> seals) =>
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: Padding(
          key: const Key('achievements-sheet'),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final seal in seals)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: SealAvatar(seal: seal, radius: 20),
                  title: Text('${seal.item.title} ${seal.item.caption}'),
                  subtitle: Text(
                    seal.earned ? 'Conquistado' : 'Bloqueado. ${seal.hint}',
                  ),
                ),
            ],
          ),
        ),
      ),
    );

Widget achievementBadge(Achievement item) => SizedBox(
  width: 78,
  child: Column(
    children: [
      CircleAvatar(
        radius: 28,
        backgroundColor: item.color,
        child: Icon(item.icon, color: Colors.white, size: 28),
      ),
      const SizedBox(height: 6),
      Text(
        item.title,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
      ),
      Text(
        item.caption,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 10, color: Colors.grey),
      ),
    ],
  ),
);

String statLabel(double km) => switch (km.round()) {
  21 => 'meias\n(21K)',
  42 => 'maratona\n(42K)',
  _ => 'corridas\n${distanceLabel(km)}',
};

class RaceStats {
  final int completed, cities, countries;
  final double kilometers;
  final Map<double, int> byDistance;
  const RaceStats(
    this.completed,
    this.cities,
    this.byDistance, {
    this.countries = 0,
    this.kilometers = 0,
  });

  factory RaceStats.of(List<RaceRecord> races) {
    final byDistance = <double, int>{};
    var kilometers = 0.0;
    for (final race in races) {
      final km = race.kilometers;
      if (km != null) {
        final key = km.roundToDouble();
        byDistance[key] = (byDistance[key] ?? 0) + 1;
        kilometers += km;
      }
    }
    return RaceStats(
      races.length,
      {
        for (final race in races)
          if ((race.edition?['city'] as String?) != null)
            race.edition!['city'] as String,
      }.length,
      byDistance,
      // Edicao sem pais informado e do Brasil.
      countries: {
        for (final race in races)
          if (race.edition != null)
            (race.edition!['country'] as String?)?.trim().toLowerCase() ??
                'brasil',
      }.length,
      kilometers: kilometers,
    );
  }
}

Widget statBlock(
  String value,
  String label, {
  Color? color,
  Color? labelColor,
  VoidCallback? onTap,
}) {
  final column = Column(
    children: [
      Text(
        value,
        style: TextStyle(
          fontWeight: FontWeight.w900,
          fontSize: 22,
          color: color,
        ),
      ),
      const SizedBox(height: 2),
      Text(
        label,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 11, color: labelColor),
      ),
    ],
  );
  return Expanded(
    child: onTap == null
        ? column
        : InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onTap,
            child: column,
          ),
  );
}

Widget loadMessage(String text) => Center(
  child: Padding(padding: const EdgeInsets.all(24), child: Text(text)),
);

String loadError(Object error) => error is IdentityIssue
    ? catalogError(error)
    : 'Não foi possível carregar seus dados. Tente novamente.';

void openMedal(
  BuildContext context,
  IdentityGateway gateway,
  RaceRecord race,
) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) =>
        ParticipationDraftScreen(gateway: gateway, initial: race.participation),
  ),
);

enum MedalGrouping { all, year, distance, city }

/// Baixa os bytes de uma foto, dada a URL assinada; injetavel para testes.
typedef ImageBytesFetcher = Future<List<int>> Function(String url);

/// Abre o editor de recorte circular (reaproveita o da foto de perfil) e
/// devolve os bytes recortados, ou nulo se a pessoa desistir. Injetavel para
/// testes, que podem pular a interacao real de recorte.
typedef MedalCropOpener = Future<List<int>?> Function(
  BuildContext context,
  Uint8List image,
  MedalFrame frame,
);

Future<List<int>?> openMedalCropScreen(
  BuildContext context,
  Uint8List image,
  MedalFrame frame,
) => Navigator.of(context).push<List<int>>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => TouchCropScreen(image: image, frame: frame),
  ),
);

/// Razao largura/altura da area que a foto realmente preenche no furo do
/// modelo escolhido: para os formatos com sub-retangulo posicionado
/// (circulo, hexagono, quadrada) e a razao do proprio furo; para contorno em
/// poligono (escudo, assimetrica) a foto preenche o quadro inteiro antes do
/// recorte, entao e a razao do quadro. Usada para o recorte de reposicionar
/// a foto exportar no mesmo formato que vai aparecer na prateleira, sem
/// sobra nem corte extra por um BoxFit.cover posterior.
double medalCropAspectRatio(MedalFrame frame) =>
    frame.shape == MedalHoleShape.polygon
    ? frame.aspectRatio
    : frame.holeHalfWidthFrac / frame.holeHalfHeightFrac;

/// Mesmo contorno usado para recortar a foto na prateleira (circulo,
/// hexagono, quadrada arredondada ou poligono), mas calculado direto para um
/// [Size] arbitrario — usado so para desenhar o guia de recorte, sem
/// precisar montar a arvore de widgets da prateleira.
Path medalHolePath(MedalFrame frame, Size size) => switch (frame.shape) {
  MedalHoleShape.hexagon => const _HexagonHoleClipper().getClip(size),
  MedalHoleShape.roundedSquare => _RoundedSquareHoleClipper(
    frame.cornerRadiusFrac,
  ).getClip(size),
  MedalHoleShape.polygon => _PolygonHoleClipper(
    frame.holeOutlineFrac!,
  ).getClip(size),
  MedalHoleShape.circle => const _CircleClipper().getClip(size),
};

/// Desenha a foto aplicando zoom/giro/arrasto; usado tanto na pre-visualizacao
/// ao vivo quanto na exportacao final, pra garantir que os dois batem pixel a
/// pixel (sem essa garantia, o recorte exportado poderia ficar diferente do
/// que a pessoa viu na tela).
class TouchCropPainter extends CustomPainter {
  final ui.Image image;
  final double scale;
  final double rotation;
  final Offset offset;
  const TouchCropPainter({
    required this.image,
    required this.scale,
    required this.rotation,
    required this.offset,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cover = max(size.width / image.width, size.height / image.height);
    canvas.save();
    canvas.translate(size.width / 2 + offset.dx, size.height / 2 + offset.dy);
    canvas.rotate(rotation);
    canvas.scale(cover * scale);
    canvas.translate(-image.width / 2, -image.height / 2);
    canvas.drawImage(image, Offset.zero, Paint());
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant TouchCropPainter oldDelegate) =>
      oldDelegate.image != image ||
      oldDelegate.scale != scale ||
      oldDelegate.rotation != rotation ||
      oldDelegate.offset != offset;
}

/// Mascara semitransparente por cima do recorte, no formato exato do furo
/// do modelo escolhido (circulo, hexagono, quadrada ou poligono) — so pra
/// orientar, nao afeta o que e exportado. O contorno e desenhado em duas
/// camadas (preta larga por baixo, branca estreita por cima) pra continuar
/// visivel mesmo sobre fotos escuras ou claras.
class _FrameGuidePainter extends CustomPainter {
  final MedalFrame frame;
  const _FrameGuidePainter(this.frame);

  @override
  void paint(Canvas canvas, Size size) {
    final hole = medalHolePath(frame, size);
    final mask = Path.combine(
      PathOperation.difference,
      Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height)),
      hole,
    );
    canvas.drawPath(mask, Paint()..color = const Color(0x99000000));
    canvas.drawPath(
      hole,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..color = const Color(0xaa000000),
    );
    canvas.drawPath(
      hole,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(covariant _FrameGuidePainter oldDelegate) =>
      oldDelegate.frame.id != frame.id;
}

/// Tela de reposicionamento por toque: arrastar com um dedo move a foto,
/// pinçar com dois dedos amplia/reduz, e girar com dois dedos gira a foto —
/// tudo junto, como em qualquer editor de foto. Devolve um PNG no mesmo
/// formato do furo do modelo escolhido (circulo, hexagono, quadrada ou
/// poligono — ver [medalCropAspectRatio]), ou nulo se a pessoa desistir.
class TouchCropScreen extends StatefulWidget {
  final Uint8List image;
  final MedalFrame frame;
  const TouchCropScreen({super.key, required this.image, required this.frame});

  @override
  State<TouchCropScreen> createState() => _TouchCropScreenState();
}

class _TouchCropScreenState extends State<TouchCropScreen> {
  ui.Image? decoded;
  double scale = 1;
  double rotation = 0;
  Offset offset = Offset.zero;
  double _baseScale = 1;
  double _baseRotation = 0;
  Size viewportSize = const Size(320, 320);
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  Future<void> _decode() async {
    final codec = await ui.instantiateImageCodec(widget.image);
    final codecFrame = await codec.getNextFrame();
    if (!mounted) return;
    setState(() => decoded = codecFrame.image);
  }

  void _onScaleStart(ScaleStartDetails details) {
    _baseScale = scale;
    _baseRotation = rotation;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    setState(() {
      scale = (_baseScale * details.scale).clamp(0.2, 8.0);
      rotation = _baseRotation + details.rotation;
      offset += details.focalPointDelta;
    });
  }

  Future<void> _confirm(Size viewport) async {
    final image = decoded;
    if (image == null || busy) return;
    setState(() => busy = true);
    try {
      final width = viewport.width.round();
      final height = viewport.height.round();
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      TouchCropPainter(
        image: image,
        scale: scale,
        rotation: rotation,
        offset: offset,
      ).paint(canvas, viewport);
      final output = await recorder.endRecording().toImage(width, height);
      final data = await output.toByteData(format: ui.ImageByteFormat.png);
      if (!mounted) return;
      Navigator.of(context).pop<List<int>>(data!.buffer.asUint8List());
    } on Exception {
      if (!mounted) return;
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
      title: const Text('Reposicionar foto'),
    ),
    body: SafeArea(
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'Arraste para posicionar, pinça para o zoom e gire com dois '
              'dedos. Essa área é o que aparece na prateleira de medalhas.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70),
            ),
          ),
          Expanded(
            child: decoded == null
                ? const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final aspect = medalCropAspectRatio(widget.frame);
                      final available = constraints.biggest;
                      var viewport = Size(
                        available.width,
                        available.width / aspect,
                      );
                      if (viewport.height > available.height) {
                        viewport = Size(
                          available.height * aspect,
                          available.height,
                        );
                      }
                      viewportSize = viewport;
                      return Center(
                        child: ClipRect(
                          child: GestureDetector(
                            key: const Key('crop-touch-area'),
                            onScaleStart: _onScaleStart,
                            onScaleUpdate: _onScaleUpdate,
                            child: SizedBox(
                              width: viewport.width,
                              height: viewport.height,
                              child: Stack(
                                children: [
                                  CustomPaint(
                                    size: viewport,
                                    painter: TouchCropPainter(
                                      image: decoded!,
                                      scale: scale,
                                      rotation: rotation,
                                      offset: offset,
                                    ),
                                  ),
                                  IgnorePointer(
                                    child: CustomPaint(
                                      size: viewport,
                                      painter: _FrameGuidePainter(widget.frame),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
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
                    onPressed: busy || decoded == null
                        ? null
                        : () => _confirm(viewportSize),
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

class MedalCollectionScreen extends StatefulWidget {
  final IdentityGateway gateway;
  final ImageBytesFetcher fetchDisplayPhoto;
  final MedalCropOpener openCropScreen;

  /// Foto da medalha para o "+" e o leitor de texto dela. Trocáveis nos testes (câmera e Vision não rodam lá).
  final MedalPhotoPicker medalPhotoPicker;
  final MedalTextReader medalTextReader;

  /// Carrega a foto da medalha provisória. Trocável nos testes (o link assinado não roda lá).
  final Future<List<int>?> Function(IdentityGateway, String) pendingPhotoLoader;
  const MedalCollectionScreen({
    super.key,
    required this.gateway,
    this.fetchDisplayPhoto = fetchImageBytes,
    this.openCropScreen = openMedalCropScreen,
    this.medalPhotoPicker = pickMedalPhotoPath,
    this.medalTextReader = const PlatformMedalTextReader(),
    this.pendingPhotoLoader = loadRequestMedalPhoto,
  });

  @override
  State<MedalCollectionScreen> createState() => _MedalCollectionScreenState();
}

class _MedalCollectionScreenState extends State<MedalCollectionScreen> {
  late Future<List<RaceRecord>> races = loadMyRaces(widget.gateway);
  late Future<List<Map<String, dynamic>>> pendingMedals = loadPendingMedals(
    widget.gateway,
  );
  MedalGrouping grouping = MedalGrouping.all;
  bool newestFirst = true;

  /// Exclui a medalha: a participação some das medalhas e de "Minhas corridas" (a corrida segue no catálogo).
  Future<void> deleteMedal(RaceRecord race) async {
    final id = race.participation['id'] as String;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.gateway.request(
        '/participations/${Uri.encodeComponent(id)}',
        method: 'DELETE',
        query: {'expectedVersion': '${race.participation['version']}'},
      );
      forgetMedalDisplayImage(id);
      if (!mounted) return;
      setState(() {
        races = loadMyRaces(widget.gateway);
      });
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Medalha excluída. Ela também saiu de Minhas corridas.',
          ),
        ),
      );
    } on Exception {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Não foi possível excluir a medalha. Tente de novo.'),
        ),
      );
    }
  }

  Future<void> editMedal(RaceRecord race) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheet) => _MedalEditSheet(
        gateway: widget.gateway,
        race: race,
        fetchDisplayPhoto: widget.fetchDisplayPhoto,
        openCropScreen: widget.openCropScreen,
      ),
    );
    if (result == null || !mounted) return;
    final id = race.participation['id'] as String;
    if (result['_delete'] == true) return deleteMedal(race);
    try {
      await widget.gateway.request(
        '/participations/${Uri.encodeComponent(id)}',
        method: 'PATCH',
        body: {'expectedVersion': race.participation['version'], ...result},
      );
      if (result.containsKey('medalDisplayImageReference')) {
        forgetMedalDisplayImage(id);
      }
      setState(() {
        races = loadMyRaces(widget.gateway);
      });
    } on Exception {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Não foi possível salvar a medalha. Tente de novo.'),
        ),
      );
    }
  }

  /// Nicho de nogueira com prateleira flutuante: fundo individual de cada
  /// medalha (um nicho por medalha, nao uma prateleira compartilhada).
  /// Cantos arredondados + sombra para ler como um "cartao" por medalha,
  /// como no template; a medalha fica encostada no topo da prateleira.
  Widget _medalNiche({required MedalFrame frame, required Widget photo}) =>
      DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          boxShadow: const [
            BoxShadow(
              color: Color(0x40000000),
              blurRadius: 6,
              offset: Offset(0, 3),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: AspectRatio(
            aspectRatio: 1086 / 1448,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final w = constraints.maxWidth;
                final h = constraints.maxHeight;
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.asset(
                      'assets/medal_shelf/nicho_nogueira.png',
                      fit: BoxFit.fill,
                    ),
                    Positioned(
                      // O PNG de cada modelo tem uma margem transparente
                      // embutida (a medalha ocupa so ~86% da altura e ~66%
                      // da largura do arquivo); e a prateleira da imagem de
                      // fundo comeca em ~76% da altura do nicho. Esta caixa
                      // foi calculada para que a medalha DESENHADA (nao o
                      // retangulo do PNG) encoste exatamente no topo da
                      // prateleira, do tamanho maximo que cabe ali.
                      left: w * 0.06,
                      right: w * 0.06,
                      top: h * 0.01,
                      height: h * 0.87,
                      child: medalFrameWidget(frame: frame, photo: photo),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );

  Widget tile(RaceRecord race) => Stack(
    children: [
      InkWell(
        onTap: () => openMedal(context, widget.gateway, race),
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          // Sem card/borda/sombra: a medalha fica direto no fundo da tela,
          // como no template. Sem padding horizontal proprio: o espacamento
          // entre as medalhas vem só do crossAxisSpacing da grade, senão o
          // recuo dobra e as imagens não ficam próximas.
          padding: EdgeInsets.zero,
          child: Column(
            // Altura fixa (sem Expanded/Center) para a imagem e para os
            // blocos de texto: assim a medalha e a prateleira ficam na
            // mesma posicao em todos os cards, mesmo quando a legenda de
            // um deles quebra em 2 linhas e a do vizinho cabe em 1.
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              _medalNiche(
                frame: medalFrameFor(race.medalFrameId),
                photo: MedalPhoto(
                  gateway: widget.gateway,
                  participationId: race.participation['id'] as String?,
                  useDisplayImage: true,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(height: 4),
              SizedBox(
                height: 32,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Text(
                    race.medalDescription,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
              Text(
                [
                  if (race.medalPlace.isNotEmpty) race.medalPlace,
                  if (race.medalYear != null) '${race.medalYear}',
                ].join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(color: context.muted, fontSize: 10),
              ),
            ],
          ),
        ),
      ),
      Positioned(
        top: 2,
        right: 2,
        child: Material(
          color: Colors.black38,
          shape: const CircleBorder(),
          child: InkWell(
            key: Key('medal-edit-${race.participation['id']}'),
            customBorder: const CircleBorder(),
            onTap: () => editMedal(race),
            child: const Padding(
              padding: EdgeInsets.all(5),
              child: Icon(Icons.edit, size: 14, color: Colors.white),
            ),
          ),
        ),
      ),
    ],
  );

  Widget grid(List<RaceRecord> list) => GridView.count(
    padding: EdgeInsets.zero,
    crossAxisCount: 3,
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    mainAxisSpacing: 0,
    crossAxisSpacing: 2,
    // Baixo o suficiente para o nicho de nogueira (proporcao fixa 1086:1448)
    // mais o texto caberem usando a largura inteira do card, sem cortar —
    // mesmo quando local/ano quebra em 2 linhas (o pior caso). Por isso nao
    // da para reduzir muito mais sem arriscar sobrepor a proxima linha
    // quando isso acontecer; 0.52 aperta a folga sem cortar texto.
    childAspectRatio: 0.52,
    children: [for (final race in list) tile(race)],
  );

  /// Botao compacto ao lado de "Minhas medalhas": abre a foto da medalha para achar a corrida.
  /// "+": primeiro a foto da medalha (câmera ou galeria); o app lê o texto e tenta achar a corrida.
  /// Se não achar, a tela seguinte tem o botão que leva às corridas.
  /// Medalhas provisórias (pedido de cadastro com a foto da medalha), até a equipe decidir.
  Widget pendingSection(List<RaceRecord> done) =>
      FutureBuilder<List<Map<String, dynamic>>>(
        future: pendingMedals,
        builder: (context, snapshot) => PendingMedalsSection(
          gateway: widget.gateway,
          requests: visiblePendingMedals(snapshot.data ?? const [], {
            for (final race in done) '${race.participation['editionId']}',
          }),
          photoLoader: widget.pendingPhotoLoader,
        ),
      );

  Future<void> addMedal() async {
    final path = await widget.medalPhotoPicker(context);
    if (path == null || !mounted) return;
    final registered = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => MedalScanScreen(
          gateway: widget.gateway,
          photoPath: path,
          reader: widget.medalTextReader,
        ),
      ),
    );
    if (registered == true && mounted) {
      setState(() {
        pendingMedals = loadPendingMedals(widget.gateway);
      });
    }
  }

  Widget _addTile() => InkWell(
    key: const Key('medal-add-tile'),
    borderRadius: BorderRadius.circular(16),
    onTap: addMedal,
    child: Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white,
        // No claro, o branco nao contrasta com o fundo: uma borda fina
        // laranja marca o circulo. No escuro ele ja se destaca sozinho.
        border: context.isDark
            ? null
            : Border.all(color: runPassOrange, width: 1),
      ),
      child: const Icon(Icons.add, color: runPassOrange, size: 16),
    ),
  );

  List<Widget> sections(List<RaceRecord> races) {
    final ordered = newestFirst ? races : races.reversed.toList();
    if (grouping == MedalGrouping.all) {
      return [grid(ordered)];
    }
    final groups = <String, List<RaceRecord>>{};
    for (final race in ordered) {
      final key = switch (grouping) {
        MedalGrouping.year => '${race.year ?? 'Sem data'}',
        MedalGrouping.city => race.cityLabel,
        _ =>
          race.kilometers == null ? 'Outras' : distanceLabel(race.kilometers!),
      };
      groups.putIfAbsent(key, () => []).add(race);
    }
    final keys = groups.keys.toList();
    if (grouping == MedalGrouping.city) {
      // Cidades visitadas em ordem alfabética; as medalhas sem cidade ficam por último.
      keys.sort((a, b) {
        if (a == RaceRecord.noCity) return 1;
        if (b == RaceRecord.noCity) return -1;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });
    }
    if (grouping == MedalGrouping.distance) {
      keys.sort(
        (a, b) => (int.tryParse(a.replaceAll('K', '')) ?? 1 << 20).compareTo(
          int.tryParse(b.replaceAll('K', '')) ?? 1 << 20,
        ),
      );
    }
    return [
      for (final key in keys) ...[
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 8),
          child: Text(
            key,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
          ),
        ),
        grid(groups[key]!),
      ],
    ];
  }

  // Icone ao lado do numero (em vez de em cima), e a legenda embaixo: ganha
  // altura vertical no card sem mudar fonte/cor. A legenda sempre quebra nas
  // 2 palavras (quebra manual, nao automatica): assim as 3 legendas ficam
  // com a mesma altura/duas linhas sempre, em vez de uma quebrar e outra
  // nao conforme o texto coube ou nao na largura.
  Widget bigStat(
    Widget icon,
    String value,
    String firstWord,
    String secondWord,
  ) => Expanded(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: 22, height: 22, child: Center(child: icon)),
            const SizedBox(width: 6),
            Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 20),
            ),
          ],
        ),
        Text(
          '$firstWord\n$secondWord',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: context.muted),
        ),
      ],
    ),
  );

  Widget chip(String label, MedalGrouping value) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: ChoiceChip(
      label: Text(label),
      selected: grouping == value,
      onSelected: (_) => setState(() => grouping = value),
      showCheckmark: false,
    ),
  );

  @override
  Widget build(BuildContext context) => Theme(
    data: Theme.of(context),
    child: Builder(
      builder: (context) => Scaffold(
        appBar: AppBar(
          title: const RunPassWordmark(compact: true),
          actions: [
            NotificationBell(gateway: widget.gateway),
            const SizedBox(width: 8),
          ],
        ),
        bottomNavigationBar: runPassNavigation(context, widget.gateway, 1),
        body: FutureBuilder<List<RaceRecord>>(
          future: races,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return loadMessage(loadError(snapshot.error!));
            }
            final data = snapshot.data!;
            if (data.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      pendingSection(data),
                      const Text(
                        'Você ainda não concluiu uma corrida. Sua primeira medalha aparecerá aqui.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      // Sem medalhas ainda: começa pela foto da medalha, sem escolher a corrida antes.
                      FilledButton.icon(
                        key: const Key('medal-add-first'),
                        onPressed: addMedal,
                        icon: const Icon(Icons.add_a_photo_outlined),
                        label: const Text('Adicionar medalha'),
                      ),
                    ],
                  ),
                ),
              );
            }
            final stats = RaceStats.of(data);
            return ListView(
              key: const Key('medals-list'),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              children: [
                pendingSection(data),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      chip('Todas', MedalGrouping.all),
                      chip('Por ano', MedalGrouping.year),
                      chip('Por distância', MedalGrouping.distance),
                      chip('Por cidade', MedalGrouping.city),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 8,
                      horizontal: 12,
                    ),
                    child: IntrinsicHeight(
                      child: Row(
                        children: [
                          bigStat(
                            const Icon(
                              Icons.directions_run_rounded,
                              color: Color(0xff4cc38a),
                              size: 22,
                            ),
                            '${stats.kilometers.round()}',
                            "km's",
                            'percorridos',
                          ),
                          VerticalDivider(
                            width: 24,
                            thickness: 1,
                            color: context.panelStrong,
                          ),
                          bigStat(
                            Image.asset(
                              'assets/icons/gold-medal.png',
                              width: 22,
                              height: 22,
                            ),
                            '${stats.completed}',
                            'medalhas',
                            'conquistadas',
                          ),
                          VerticalDivider(
                            width: 24,
                            thickness: 1,
                            color: context.panelStrong,
                          ),
                          bigStat(
                            Image.asset(
                              'assets/icons/location.png',
                              width: 22,
                              height: 22,
                            ),
                            '${stats.cities}',
                            'cidades',
                            'visitadas',
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Minhas medalhas',
                            key: const Key('medals-title'),
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 17,
                            ),
                          ),
                          const SizedBox(width: 10),
                          _addTile(),
                        ],
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () =>
                          setState(() => newestFirst = !newestFirst),
                      icon: const Icon(Icons.swap_vert, size: 18),
                      label: Text(
                        newestFirst ? 'Mais recentes' : 'Mais antigas',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                ...sections(data),
              ],
            );
          },
        ),
      ),
    ),
  );
}

/// Bottom sheet para personalizar a medalha: modelo (catalogo de imagens) e
/// legenda (descricao, cidade, UF, ano). Devolve o corpo pronto para PATCH
/// /participations/{id}, ou nulo se a pessoa cancelar.
class _MedalEditSheet extends StatefulWidget {
  final IdentityGateway gateway;
  final RaceRecord race;
  final ImageBytesFetcher fetchDisplayPhoto;
  final MedalCropOpener openCropScreen;
  const _MedalEditSheet({
    required this.gateway,
    required this.race,
    this.fetchDisplayPhoto = fetchImageBytes,
    this.openCropScreen = openMedalCropScreen,
  });

  @override
  State<_MedalEditSheet> createState() => _MedalEditSheetState();
}

class _MedalEditSheetState extends State<_MedalEditSheet> {
  late String frameId = widget.race.medalFrameId;
  late final description = TextEditingController(
    text: widget.race.medalDescription,
  );
  // Recorte da foto so para a prateleira; so entra no PATCH se a pessoa
  // realmente tocar em "Reposicionar foto" (senao nao mexe no que ja existe).
  late String? displayImageReference = widget.race.medalDisplayImageReference;
  bool displayImageTouched = false;
  bool repositioning = false;

  @override
  void dispose() {
    description.dispose();
    super.dispose();
  }

  Future<void> confirmDelete() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Excluir medalha?'),
        content: const Text(
          'A medalha e a sua participação nesta corrida serão excluídas: tempo, colocação, número de peito e avaliação. '
          'Ela também deixa de aparecer em Minhas corridas. A corrida continua no catálogo.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            key: const Key('medal-delete-confirm'),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Excluir'),
          ),
        ],
      ),
    );
    if (sure == true && mounted) Navigator.pop(context, {'_delete': true});
  }

  String? _blankToNull(String text) {
    final trimmed = text.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  Future<void> repositionPhoto() async {
    final id = widget.race.participation['id'] as String?;
    if (id == null || repositioning) return;
    setState(() => repositioning = true);
    try {
      // Sempre parte da foto oficial (nunca alterada), nao do recorte
      // anterior: senao, cada reposicionamento encolheria o enquadramento a
      // partir do corte ja feito, em vez de deixar escolher de novo na foto
      // inteira.
      final reply = await widget.gateway.request(
        '/participations/${Uri.encodeComponent(id)}/image',
      );
      final url = reply['url'] as String?;
      if (url == null) throw const IdentityIssue('IMAGE_NOT_AVAILABLE');
      final bytes = await widget.fetchDisplayPhoto(url);
      if (!mounted) return;
      final cropped = await widget.openCropScreen(
        context,
        Uint8List.fromList(bytes),
        medalFrameFor(frameId),
      );
      if (cropped == null || !mounted) return;
      final reference = await uploadProfilePhoto(widget.gateway, cropped);
      setState(() {
        displayImageReference = reference;
        displayImageTouched = true;
      });
    } on Exception {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Não foi possível reposicionar a foto. Tente de novo.'),
        ),
      );
    } finally {
      if (mounted) setState(() => repositioning = false);
    }
  }

  void resetPhoto() => setState(() {
    displayImageReference = null;
    displayImageTouched = true;
  });

  void save() {
    Navigator.pop<Map<String, dynamic>>(context, {
      'medalFrameId': frameId,
      'medalDescription': _blankToNull(description.text),
      // Cidade, UF e ano nao sao mais personalizaveis aqui: sempre vem do
      // catalogo da corrida (RaceRecord.medalCity/medalState/medalYear ja
      // caem para o catalogo quando a participacao nao tem valor proprio).
      'medalCity': null,
      'medalState': null,
      'medalYear': null,
      if (displayImageTouched)
        'medalDisplayImageReference': displayImageReference,
    });
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 8,
        bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Personalizar medalha',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('medal-reposition-photo'),
                    onPressed: repositioning ? null : repositionPhoto,
                    icon: repositioning
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.crop, size: 18),
                    label: Text(
                      repositioning ? 'Carregando…' : 'Reposicionar foto',
                    ),
                  ),
                ),
                if (displayImageReference != null) ...[
                  const SizedBox(width: 8),
                  TextButton(
                    key: const Key('medal-reset-photo'),
                    onPressed: repositioning ? null : resetPhoto,
                    child: const Text('Remover'),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              'Modelo da medalha',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 140,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: medalFrames.length,
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (context, index) {
                  final option = medalFrames[index];
                  final selected = frameId == option.id;
                  return InkWell(
                    key: Key('medal-frame-${option.id}'),
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => setState(() => frameId = option.id),
                    child: Container(
                      width: 92,
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: selected ? runPassOrange : Colors.transparent,
                          width: 2,
                        ),
                      ),
                      child: Column(
                        children: [
                          Expanded(
                            child: medalFrameWidget(
                              frame: option,
                              photo: MedalPhoto(
                                gateway: widget.gateway,
                                participationId:
                                    widget.race.participation['id'] as String?,
                                useDisplayImage: true,
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            option.label,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 10),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: description,
              decoration: const InputDecoration(
                labelText: 'Nome da Corrida',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancelar'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    key: const Key('medal-edit-save'),
                    style: FilledButton.styleFrom(
                      backgroundColor: runPassOrange,
                    ),
                    onPressed: save,
                    child: const Text('Salvar'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              key: const Key('medal-delete'),
              onPressed: confirmDelete,
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              label: const Text(
                'Excluir medalha',
                style: TextStyle(color: Colors.red),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class ProfileData {
  final Map<String, dynamic> profile;
  final List<RaceRecord> races;

  /// Agenda da pessoa (`/me/race-plans`): corridas desejadas e inscritas.
  final List<Map<String, dynamic>> plans;
  final List<FeedEntry> myPosts;
  final int followers, following, friends;
  const ProfileData(
    this.profile,
    this.races,
    this.plans, [
    this.followers = 0,
    this.following = 0,
    this.myPosts = const [],
    this.friends = 0,
  ]);
}

/// As publicações do próprio usuário (corridas com `publishToFeed=true`), mais recente
/// primeiro, já no formato completo do cartão do Feed (curtidas, comentários).
Future<List<FeedEntry>> loadMyPosts(
  IdentityGateway gateway,
  List<RaceRecord> races,
  String? myId,
) async {
  final published =
      [
        for (final race in races)
          if (race.participation['publishToFeed'] == true) race,
      ]..sort(
        (a, b) => (b.participation['completedAt'] as String? ?? '').compareTo(
          a.participation['completedAt'] as String? ?? '',
        ),
      );
  final entries = <FeedEntry>[];
  for (final race in published) {
    final id = race.participation['id'] as String?;
    if (id == null) continue;
    try {
      final post = await gateway.request('/posts/${Uri.encodeComponent(id)}');
      entries.add(entryFromPost(post, race.edition, myId));
    } on Exception {
      // Uma publicacao que falhar ao carregar simplesmente nao aparece na lista.
    }
  }
  return entries;
}

class RunnerProfileScreen extends StatefulWidget {
  final IdentityGateway gateway;
  final ProfilePhotoPicker photoPicker;
  final ProfilePhotoPicker bannerPicker;
  const RunnerProfileScreen({
    super.key,
    required this.gateway,
    this.photoPicker = pickProfilePhoto,
    this.bannerPicker = pickBannerPhoto,
  });

  @override
  State<RunnerProfileScreen> createState() => _RunnerProfileScreenState();
}

class _RunnerProfileScreenState extends State<RunnerProfileScreen> {
  static const _gridKey = 'grid-columns-profile';
  int gridColumns = GridColumns.standard;

  /// Corridas da agenda no perfil: grade (padrão, 3 por linha) ou lista como na tela Corridas; fica neste aparelho.
  static const _viewKey = 'profile-view-mode';
  CatalogViewMode planView = CatalogViewMode.grid;

  /// Minhas publicações: grade de miniaturas (padrão) ou lista com as publicações inteiras, como no início.
  static const _postViewKey = 'profile-posts-view-mode';
  CatalogViewMode postView = CatalogViewMode.grid;

  @override
  void initState() {
    super.initState();
    _loadGridColumns();
    CatalogViewMode.read(_viewKey, CatalogViewMode.grid).then((mode) {
      if (mounted) setState(() => planView = mode);
    });
    CatalogViewMode.read(_postViewKey, CatalogViewMode.grid).then((mode) {
      if (mounted) setState(() => postView = mode);
    });
  }

  void _loadGridColumns() => GridColumns.read(_gridKey).then((n) {
    if (mounted) {
      setState(() {
        gridColumns = n;
      });
    }
  });

  void _setGridColumns(int n) {
    setState(() {
      gridColumns = n;
    });
    GridColumns.write(_gridKey, n);
  }

  late Future<ProfileData> data = load();

  Future<void> changePhoto(Map<String, dynamic> profile) async {
    final hasPhoto = profile['photoReference'] != null;
    final choice = await askPhotoChoice(context, canRemove: hasPhoto);
    if (choice == null || !mounted) return;
    try {
      String? reference;
      if (choice == PhotoChoice.remove) {
        final sure = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Remover a foto de perfil?'),
            content: const Text('Seu perfil volta a mostrar o ícone padrão.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                key: const Key('confirm-remove-photo'),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Remover'),
              ),
            ],
          ),
        );
        if (sure != true) return;
      } else {
        final bytes = await widget.photoPicker(context, choice);
        if (bytes == null) return;
        soon('Enviando a foto...');
        reference = await uploadProfilePhoto(widget.gateway, bytes);
      }
      await widget.gateway.request(
        '/me',
        method: 'PATCH',
        body: {
          'expectedVersion': profile['version'],
          'photoReference': reference,
        },
      );
      forgetProfilePhoto(profile['id'] as String);
      forgetNavProfile(widget.gateway);
      if (mounted) {
        setState(() {
          data = load();
        });
      }
    } on IdentityIssue catch (issue) {
      soon(photoError(issue));
    } on Exception catch (error) {
      soon(photoError(error));
    }
  }

  void openRelationList(
    Map<String, dynamic> profile,
    RelationListKind kind,
    String title,
  ) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RelationListScreen(
          gateway: widget.gateway,
          profileId: profile['id'] as String,
          kind: kind,
          title: title,
          ownList: true,
        ),
      ),
    );
  }

  Future<void> editProfile(Map<String, dynamic> profile) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) =>
            EditProfileScreen(gateway: widget.gateway, profile: profile),
      ),
    );
    if (saved == true && mounted) {
      setState(() {
        data = load();
      });
    }
  }

  Future<void> changeBanner(Map<String, dynamic> profile) async {
    final choice = await askPhotoChoice(
      context,
      canRemove: profile['bannerReference'] != null,
    );
    if (choice == null || !mounted) return;
    try {
      String? reference;
      if (choice != PhotoChoice.remove) {
        final bytes = await widget.bannerPicker(context, choice);
        if (bytes == null) return;
        soon('Enviando o banner...');
        reference = await uploadProfilePhoto(widget.gateway, bytes);
      }
      await widget.gateway.request(
        '/me',
        method: 'PATCH',
        body: {
          'expectedVersion': profile['version'],
          'bannerReference': reference,
        },
      );
      forgetBanner(profile['id'] as String);
      if (mounted) {
        setState(() {
          data = load();
        });
      }
    } on IdentityIssue catch (issue) {
      soon(photoError(issue));
    } on Exception catch (error) {
      soon(photoError(error));
    }
  }

  Future<ProfileData> load() async {
    final profile = await widget.gateway.request('/me');
    rememberNavProfile(widget.gateway, profile);
    var races = const <RaceRecord>[];
    var plans = const <Map<String, dynamic>>[];
    try {
      races = await loadMyRaces(widget.gateway);
    } on Exception {
      // The profile still opens, only without the race summary.
    }
    try {
      final page = await widget.gateway.request('/me/race-plans');
      plans = (page['items'] as List? ?? const []).cast<Map<String, dynamic>>();
    } on Exception {
      // A agenda e opcional; a secao mostra a mensagem de vazio.
    }
    var followers = 0, following = 0, friends = 0;
    final myId = profile['id'] as String?;
    if (myId != null) {
      try {
        final me = await widget.gateway.request(
          '/profiles/${Uri.encodeComponent(myId)}',
        );
        followers = (me['followersCount'] as num?)?.toInt() ?? 0;
        following = (me['followingCount'] as num?)?.toInt() ?? 0;
        friends = (me['friendsCount'] as num?)?.toInt() ?? 0;
      } on Exception {
        // Sem contagem: mostra zero.
      }
    }
    var myPosts = const <FeedEntry>[];
    try {
      myPosts = await loadMyPosts(widget.gateway, races, myId);
    } on Exception {
      // A secao de publicacoes so fica vazia.
    }
    return ProfileData(
      profile,
      races,
      plans,
      followers,
      following,
      myPosts,
      friends,
    );
  }

  void soon(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Widget cover(Map<String, dynamic> profile, ProfileData result) => SizedBox(
    height: 232,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          key: const Key('profile-banner'),
          height: 176,
          clipBehavior: Clip.hardEdge,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [runPassNavy, Color(0xff5a2a1c), runPassOrange],
            ),
          ),
          child: profile['bannerReference'] == null
              ? null
              : SizedBox.expand(
                  child: SignedPhoto(
                    key: ValueKey('banner-${profile['bannerReference']}'),
                    gateway: widget.gateway,
                    endpoint:
                        '/profiles/${Uri.encodeComponent(profile['id'] as String)}/banner',
                    fallback: const SizedBox.shrink(),
                  ),
                ),
        ),
        Positioned(
          right: 12,
          top: 134,
          child: InkWell(
            key: const Key('change-banner'),
            onTap: () => changeBanner(profile),
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.image_outlined, size: 16, color: Colors.white),
                  SizedBox(width: 6),
                  Text(
                    'Banner',
                    style: TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          right: 8,
          top: 8,
          child: SafeArea(
            child: Row(
              children: [
                IconTheme(
                  data: const IconThemeData(color: Colors.white),
                  child: NotificationBell(gateway: widget.gateway),
                ),
                IconButton(
                  key: const Key('open-settings'),
                  tooltip: 'Configurações',
                  color: Colors.white,
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => SettingsScreen(gateway: widget.gateway),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // Seguidores e seguindo ao lado da foto, ABAIXO do banner (formato do Instagram).
        Positioned(
          left: 124,
          right: 12,
          top: 188,
          child: Row(
            key: const Key('profile-counts'),
            children: [
              statBlock(
                '${result.friends}',
                'amigos',
                onTap: () => openRelationList(
                  profile,
                  RelationListKind.friends,
                  'Amigos',
                ),
              ),
              statBlock(
                '${result.followers}',
                'seguidores',
                onTap: () => openRelationList(
                  profile,
                  RelationListKind.followers,
                  'Seguidores',
                ),
              ),
              statBlock(
                '${result.following}',
                'seguindo',
                onTap: () => openRelationList(
                  profile,
                  RelationListKind.following,
                  'Seguindo',
                ),
              ),
            ],
          ),
        ),
        Positioned(
          left: 20,
          bottom: 0,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              CircleAvatar(
                radius: 46,
                backgroundColor: Theme.of(context).colorScheme.surface,
                child: ProfileAvatar(
                  key: ValueKey('avatar-${profile['photoReference']}'),
                  radius: 42,
                  gateway: widget.gateway,
                  profile: profile,
                ),
              ),
              Positioned(
                right: -2,
                bottom: 2,
                child: InkWell(
                  key: const Key('change-profile-photo'),
                  onTap: () => changePhoto(profile),
                  child: const CircleAvatar(
                    radius: 14,
                    backgroundColor: runPassNavy,
                    child: Icon(
                      Icons.photo_camera_outlined,
                      size: 15,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  /// Todos os selos entre o nome e o @usuario: os conquistados coloridos e os que faltam
  /// bloqueados (cinza, com cadeado). Tocar mostra o detalhe e como desbloquear.
  Widget _sealRow(List<Seal> seals) => SingleChildScrollView(
    key: const Key('seal-row'),
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        for (final seal in seals)
          Padding(
            padding: const EdgeInsets.only(right: 12, top: 4, bottom: 2),
            child: SealBadge(
              seal: seal,
              onTap: () => showSealsSheet(context, seals),
            ),
          ),
      ],
    ),
  );

  Widget sectionTitle(
    String title, {
    String? action,
    VoidCallback? onAction,
    Widget? trailing,
  }) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 2),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 19),
          ),
        ),
        ?trailing,
        if (action != null)
          TextButton(
            onPressed: onAction,
            style: TextButton.styleFrom(
              minimumSize: Size.zero,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(action),
          ),
      ],
    ),
  );

  /// Corrida da agenda no mesmo cartão da tela Corridas (lista ou grade). Tocar abre a prova.
  Widget planTile(Map<String, dynamic> plan) {
    final edition = {
      ...(plan['edition'] as Map<String, dynamic>? ?? const {}),
      'id': plan['editionId'],
    };
    final date = edition['date'] as String?;
    final place = [
      if (edition['city'] != null) edition['city'] as String,
      if (edition['state'] != null) edition['state'] as String,
    ].join('/');
    final subtitle = [
      if (date != null) displayDate(date),
      if (place.isNotEmpty) place,
    ].join(' · ');
    Future<void> open() async {
      if (plan['editionId'] == null) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => EditionScreen(
            gateway: widget.gateway,
            editionId: plan['editionId'] as String,
          ),
        ),
      );
      if (mounted) {
        setState(() {
          data = load();
        });
      }
    }

    final key = Key('plan-${plan['editionId']}');
    if (planView == CatalogViewMode.grid) {
      return EditionGridCard(
        key: key,
        gateway: widget.gateway,
        edition: edition,
        columns: gridColumns,
        subtitle: subtitle,
        shortDate: date == null ? '' : displayDate(date).substring(0, 5),
        onTap: open,
      );
    }
    final distances = [
      for (final d in (edition['distances'] as List? ?? const []))
        '${(d as Map)['kilometers']} km',
    ].join(' · ');
    return EditionListCard(
      key: key,
      gateway: widget.gateway,
      edition: edition,
      lines: [
        if (subtitle.isNotEmpty) subtitle,
        if (distances.isNotEmpty) distances,
      ],
      onTap: open,
    );
  }

  /// Desejadas ou inscritas, da mais proxima para a mais distante.
  Widget planGrid(String status, List<Map<String, dynamic>> plans) {
    final items =
        [
          for (final p in plans)
            if (p['status'] == status) p,
        ]..sort(
          (a, b) => ((a['edition'] as Map?)?['date'] as String? ?? '')
              .compareTo((b['edition'] as Map?)?['date'] as String? ?? ''),
        );
    if (items.isEmpty) return const SizedBox.shrink();
    final shown = items.take(9).toList();
    return Column(
      key: Key('plans-$status'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            status == 'wanted' ? 'Desejadas' : 'Inscritas',
            style: TextStyle(fontWeight: FontWeight.w700, color: context.muted),
          ),
        ),
        if (planView == CatalogViewMode.grid)
          GridView.count(
            padding: EdgeInsets.zero,
            crossAxisCount: gridColumns,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
            childAspectRatio: gridCardAspectRatio(gridColumns),
            children: [for (final plan in shown) planTile(plan)],
          )
        else
          for (final plan in shown) planTile(plan),
        const SizedBox(height: 8),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    bottomNavigationBar: runPassNavigation(context, widget.gateway, 3),
    body: FutureBuilder<ProfileData>(
      future: data,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) return loadMessage(loadError(snapshot.error!));
        final result = snapshot.data!;
        final profile = result.profile;
        final stats = RaceStats.of(result.races);
        final distances = stats.byDistance.keys.toList()..sort();
        final city = profile['city'] as String?;
        final bio = profile['bio'] as String?;
        final birthLabel = birthDateLabel(profile['birthDate'] as String?);
        final cities = {
          for (final race in result.races)
            if (race.edition?['city'] != null) race.edition!['city'] as String,
        }.toList();
        final myPosts = result.myPosts;
        return ListView(
          padding: EdgeInsets.zero,
          children: [
            cover(profile, result),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          profile['displayName'] as String? ?? 'Corredor',
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 24,
                          ),
                        ),
                      ),
                      IconButton(
                        key: const Key('edit-profile'),
                        tooltip: 'Editar perfil',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.edit_outlined, size: 20),
                        onPressed: () => editProfile(profile),
                      ),
                    ],
                  ),
                  _sealRow(sealsOf(stats)),
                  Text(
                    [
                      '@${profile['username'] ?? ''}',
                      ?brLocationLabel(profile),
                      if (brLocationLabel(profile) == null &&
                          city != null &&
                          city.isNotEmpty)
                        city,
                    ].join('  •  '),
                    style: TextStyle(color: context.muted),
                  ),
                  if (birthLabel != null) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(
                          Icons.cake_outlined,
                          size: 16,
                          color: context.muted,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          birthLabel,
                          style: TextStyle(color: context.muted, fontSize: 13),
                        ),
                      ],
                    ),
                  ],
                  if (bio != null && bio.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(bio, key: const Key('profile-phrase')),
                  ],
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Row(
                        children: [
                          statBlock('${stats.completed}', 'provas\nconcluídas'),
                          for (final km in distances.take(4))
                            statBlock('${stats.byDistance[km]}', statLabel(km)),
                        ],
                      ),
                    ),
                  ),
                  sectionTitle(
                    'Quero correr',
                    trailing: CatalogViewMenu(
                      key: const Key('view-menu-plans'),
                      value: planView,
                      columns: gridColumns,
                      onChanged: (mode) {
                        setState(() => planView = mode);
                        mode.write(_viewKey);
                      },
                      onColumnsChanged: _setGridColumns,
                    ),
                  ),
                  if (result.plans.isEmpty)
                    const Text(
                      'Suas corridas desejadas e inscritas aparecerão aqui.',
                      key: Key('no-plans'),
                    )
                  else ...[
                    planGrid('wanted', result.plans),
                    planGrid('registered', result.plans),
                  ],
                  sectionTitle(
                    'Minhas publicações',
                    trailing: CatalogViewMenu(
                      key: const Key('view-menu-posts'),
                      value: postView,
                      columns: gridColumns,
                      onChanged: (mode) {
                        setState(() => postView = mode);
                        mode.write(_postViewKey);
                      },
                      onColumnsChanged: _setGridColumns,
                    ),
                  ),
                  if (myPosts.isEmpty)
                    const Text(
                      'Suas corridas publicadas aparecerão aqui.',
                      key: Key('no-my-posts'),
                    )
                  else if (postView == CatalogViewMode.list)
                    Column(
                      key: const Key('my-posts-list'),
                      children: [
                        for (final entry in myPosts)
                          PostCard(
                            key: Key('my-post-card-${entry.postId}'),
                            gateway: widget.gateway,
                            entry: entry,
                            onChanged: () {
                              if (mounted) {
                                setState(() {
                                  data = load();
                                });
                              }
                            },
                          ),
                      ],
                    )
                  else
                    // Miniaturas, 3 por linha; tocar abre a publicação inteira.
                    GridView.count(
                      padding: EdgeInsets.zero,
                      key: const Key('my-posts-grid'),
                      crossAxisCount: gridColumns,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      mainAxisSpacing: 6,
                      crossAxisSpacing: 6,
                      children: [
                        for (final entry in myPosts)
                          PostThumb(
                            key: Key('my-post-${entry.postId}'),
                            gateway: widget.gateway,
                            entry: entry,
                            onChanged: () {
                              if (mounted) {
                                setState(() {
                                  data = load();
                                });
                              }
                            },
                          ),
                      ],
                    ),
                  const SizedBox(height: 8),
                  Card(
                    child: ListTile(
                      leading: const Icon(
                        Icons.map_outlined,
                        color: runPassOrange,
                      ),
                      title: const Text(
                        'Meu passaporte',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                      subtitle: Text(
                        '${cities.length} ${cities.length == 1 ? 'cidade conquistada' : 'cidades conquistadas'}',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => soon('Passaporte completo em breve.'),
                    ),
                  ),
                  if (cities.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final name in cities.take(6))
                          Chip(
                            avatar: const Icon(Icons.place_outlined, size: 16),
                            label: Text(name),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    ),
  );
}
