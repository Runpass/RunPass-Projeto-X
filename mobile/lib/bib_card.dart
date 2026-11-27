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
String? bibDistanceLabel(double? km) =>
    km == null || km <= 0 ? null : distanceLabel(km);

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

/// Quadro de parede: moldura de madeira (a da prateleira das medalhas), passe-partout branco e duas janelas, a medalha à esquerda e o número de
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
        // Moldura na mesma madeira (nogueira) da prateleira das medalhas, nos dois temas. A cor de fundo é a
        // da madeira, para o caso de a imagem não carregar.
        return Container(
          decoration: BoxDecoration(
            color: const Color(0xff5a2c14),
            image: const DecorationImage(
              image: AssetImage('assets/medal_shelf/nicho_nogueira.png'),
              fit: BoxFit.cover,
              // A parte de cima da imagem: só o fundo de madeira, sem a prateleira.
              alignment: Alignment(0, -0.55),
            ),
            border: Border.all(color: const Color(0xff2e1508), width: .35 * u),
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
            // Filete escuro entre a madeira e o passe-partout, como o rebaixo de uma moldura.
            decoration: BoxDecoration(
              color: const Color(0xfffafafa),
              border: Border.all(color: const Color(0x8a1c0c04), width: .5 * u),
            ),
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
