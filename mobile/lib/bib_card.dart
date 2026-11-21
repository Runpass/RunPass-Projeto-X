import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'identity_gateway.dart';
import 'my_races.dart';
import 'runpass_theme.dart';

/// Número de peito da participação (o que a pessoa informou no cadastro), ou nulo.
String? bibNumberOf(Map participation) {
  final bib = '${participation['bibNumber'] ?? ''}'.trim();
  return bib.isEmpty ? null : bib;
}

/// Distância no jeito do número de peito: "42K", "21K", "7,5K".
String? bibDistanceLabel(double? km) {
  if (km == null || km <= 0) return null;
  if ((km - 42.195).abs() < 0.3) return '42K';
  if ((km - 21.0975).abs() < 0.2) return '21K';
  final rounded = (km * 10).round() / 10;
  final text = rounded == rounded.roundToDouble()
      ? rounded.round().toString()
      : rounded.toStringAsFixed(1).replaceAll('.', ',');
  return '${text}K';
}

/// "12º LUGAR", ou nulo sem colocação.
String? bibPlacementLabel(num? placement) =>
    placement == null || placement <= 0 ? null : '${placement.round()}º LUGAR';

const _bibPaper = Color(0xfff4f4f1);
const _bibInk = Color(0xff16181c);

/// Cartão do número de peito: a distância e o nome da corrida em cima, o número grande no meio e, embaixo, a
/// colocação (quando há) e o lugar e ano. Preto no papel claro, com um detalhe laranja da marca. Não é a arte
/// do número oficial da prova: é um cartão do app com o que a pessoa informou.
class BibCard extends StatelessWidget {
  final String bib;
  final String title;
  final String? distance, placement, footer;
  const BibCard({
    super.key,
    required this.bib,
    required this.title,
    this.distance,
    this.placement,
    this.footer,
  });

  /// O cartão de uma corrida minha, ou nulo se ela não tem número de peito.
  static BibCard? of(RaceRecord race, {Key? key}) {
    final bib = bibNumberOf(race.participation);
    if (bib == null) return null;
    return BibCard(
      key: key,
      bib: bib,
      title: race.name,
      distance: bibDistanceLabel(race.kilometers),
      placement: bibPlacementLabel(race.placement),
      footer: [
        if (race.medalPlace.isNotEmpty) race.medalPlace,
        if (race.medalYear != null) '${race.medalYear}',
      ].join(' · '),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      // Tudo proporcional à largura, para o cartão ler igual no quadro e em tamanho grande.
      final u = box.maxWidth / 100;
      return Container(
        color: _bibPaper,
        padding: EdgeInsets.fromLTRB(7 * u, 6 * u, 0, 6 * u),
        // Estilo próprio: o cartão lê igual em qualquer tela (com ou sem tema em volta).
        child: DefaultTextStyle.merge(
          style: const TextStyle(decoration: TextDecoration.none),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (distance != null)
                          Padding(
                            padding: EdgeInsets.only(right: 4 * u),
                            child: Text(
                              distance!,
                              style: TextStyle(
                                color: _bibInk,
                                fontWeight: FontWeight.w900,
                                fontSize: 13 * u,
                                height: 1,
                              ),
                            ),
                          ),
                        Expanded(
                          child: Text(
                            title.toUpperCase(),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: distance == null
                                ? TextAlign.left
                                : TextAlign.right,
                            style: TextStyle(
                              color: _bibInk,
                              fontWeight: FontWeight.w800,
                              fontSize: 5.6 * u,
                              height: 1.1,
                              letterSpacing: .3,
                            ),
                          ),
                        ),
                      ],
                    ),
                    Expanded(
                      child: Center(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            bib,
                            key: const Key('bib-number'),
                            maxLines: 1,
                            style: TextStyle(
                              color: _bibInk,
                              fontWeight: FontWeight.w900,
                              fontSize: 46 * u,
                              height: 1,
                              letterSpacing: -1,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Text(
                            (footer ?? '').toUpperCase(),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: _bibInk,
                              fontWeight: FontWeight.w700,
                              fontSize: 4.6 * u,
                              height: 1.15,
                            ),
                          ),
                        ),
                        if (placement != null)
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                placement!,
                                key: const Key('bib-placement'),
                                style: TextStyle(
                                  color: _bibInk,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 6.4 * u,
                                  height: 1,
                                ),
                              ),
                              Container(
                                margin: EdgeInsets.only(top: 1.6 * u),
                                width: 26 * u,
                                height: 2.2 * u,
                                color: runPassOrange,
                              ),
                            ],
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              // Faixa lateral, como a dos números de prova.
              Container(
                margin: EdgeInsets.only(left: 4 * u),
                width: 4 * u,
                color: _bibInk,
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Quadro de parede: moldura preta, passe-partout branco e duas janelas, a medalha à esquerda e o número de
/// peito à direita.
class MedalBibFrame extends StatelessWidget {
  final IdentityGateway gateway;
  final RaceRecord race;
  final BibCard card;
  final int revision;
  const MedalBibFrame({
    super.key,
    required this.gateway,
    required this.race,
    required this.card,
    this.revision = 0,
  });

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: 4 / 3,
    child: LayoutBuilder(
      builder: (context, box) {
        final u = box.maxWidth / 100;
        // No tema escuro a moldura preta sumia no fundo do app: lá ela é grafite, com um filete claro.
        final dark = Theme.of(context).brightness == Brightness.dark;
        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: dark
                  ? const [Color(0xff5a5f67), Color(0xff3a3e45)]
                  : const [Color(0xff2a2a2a), Color(0xff141414)],
            ),
            border: dark
                ? Border.all(color: const Color(0xff7b818a), width: .35 * u)
                : null,
            borderRadius: BorderRadius.circular(1.2 * u),
            boxShadow: const [
              BoxShadow(
                color: Colors.black38,
                blurRadius: 10,
                offset: Offset(0, 4),
              ),
            ],
          ),
          padding: EdgeInsets.all(5.5 * u),
          child: Container(
            color: const Color(0xfffafafa),
            padding: EdgeInsets.all(4 * u),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Janela da medalha: fundo escuro, a medalha com a moldura que a pessoa escolheu.
                Expanded(
                  flex: 40,
                  child: Container(
                    color: const Color(0xff0c0c0e),
                    padding: EdgeInsets.all(1.5 * u),
                    alignment: Alignment.center,
                    child: medalFrameWidget(
                      frame: medalFrameFor(race.medalFrameId),
                      photo: MedalPhoto(
                        gateway: gateway,
                        participationId: race.participation['id'] as String?,
                        useDisplayImage: true,
                        revision: revision,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                ),
                SizedBox(width: 4 * u),
                Expanded(flex: 56, child: card),
              ],
            ),
          ),
        );
      },
    ),
  );
}

/// Desenha o cartão do número de peito num canvas (imagem de compartilhar), dentro de [rect].
void drawBibCard(
  Canvas canvas,
  Rect rect, {
  required String bib,
  required String title,
  String? distance,
  String? placement,
}) {
  final u = rect.width / 100;
  final radius = Radius.circular(3 * u);
  final shape = RRect.fromRectAndRadius(rect, radius);
  canvas.drawRRect(
    shape.shift(Offset(0, 1.5 * u)),
    Paint()
      ..color = const Color(0x66000000)
      ..maskFilter = ui.MaskFilter.blur(BlurStyle.normal, 4 * u),
  );
  canvas.drawRRect(shape, Paint()..color = _bibPaper);
  canvas.save();
  canvas.clipRRect(shape);
  // Faixa lateral.
  canvas.drawRect(
    Rect.fromLTWH(rect.right - 5 * u, rect.top, 5 * u, rect.height),
    Paint()..color = _bibInk,
  );
  final left = rect.left + 7 * u;
  final inner = rect.width - 7 * u - 10 * u;
  TextPainter paint(
    String text,
    double size,
    FontWeight weight, {
    double? maxWidth,
    int maxLines = 1,
    TextAlign align = TextAlign.left,
  }) => TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        color: _bibInk,
        fontSize: size,
        fontWeight: weight,
        height: 1.05,
      ),
    ),
    textAlign: align,
    textDirection: TextDirection.ltr,
    maxLines: maxLines,
    ellipsis: '…',
  )..layout(maxWidth: maxWidth ?? inner);

  var top = rect.top + 6 * u;
  var titleLeft = left, titleWidth = inner;
  if (distance != null) {
    final d = paint(distance, 13 * u, FontWeight.w900);
    d.paint(canvas, Offset(left, top));
    titleLeft = left + d.width + 4 * u;
    titleWidth = inner - d.width - 4 * u;
  }
  final name = paint(
    title.toUpperCase(),
    5.6 * u,
    FontWeight.w800,
    maxWidth: titleWidth,
    maxLines: 2,
    align: distance == null ? TextAlign.left : TextAlign.right,
  );
  name.paint(canvas, Offset(titleLeft + (titleWidth - name.width), top));
  top += 15 * u;

  final bottom = rect.bottom - 6 * u;
  final footerHeight = placement == null ? 0.0 : 11 * u;
  // Número: o maior tamanho que cabe na largura e na altura que sobram.
  final room = bottom - footerHeight - top;
  var size = 46 * u;
  // Medido sem limite de largura: com limite, o texto que não cabe vira "…" e parece caber.
  TextPainter numberAt(double size) =>
      paint(bib, size, FontWeight.w900, maxWidth: double.infinity);
  var number = numberAt(size);
  while ((number.width > inner || number.height > room) && size > 8 * u) {
    size *= .92;
    number = numberAt(size);
  }
  number.paint(
    canvas,
    Offset(left + (inner - number.width) / 2, top + (room - number.height) / 2),
  );
  if (placement != null) {
    final p = paint(placement, 6.4 * u, FontWeight.w900);
    p.paint(canvas, Offset(left + inner - p.width, bottom - 10 * u));
    canvas.drawRect(
      Rect.fromLTWH(left + inner - 26 * u, bottom - 2.2 * u, 26 * u, 2.2 * u),
      Paint()..color = runPassOrange,
    );
  }
  canvas.restore();
}
