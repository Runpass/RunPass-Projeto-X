import 'package:flutter/material.dart';

import 'new_post.dart' show foldName;

/// Foto de cartão postal de uma cidade, usada como capa quando a corrida não tem banner autorizado.
/// Entram fotos com licença livre que dispensa crédito (CC0 ou domínio público) e, onde não há foto
/// livre, ilustrações criadas por IA (identificadas como tal), aprovadas pelo dono da mídia. O crédito de cada uma aparece em Configurações > Créditos das fotos.
const illustrationLicense = 'Ilustração criada por IA';

class CityPhoto {
  final String city, asset, author, license, title, sourceUrl;

  /// Ilustração criada por IA (não é foto): fica identificada nos créditos e não tem página de origem.
  bool get isIllustration => license == illustrationLicense;
  const CityPhoto({
    required this.city,
    required this.asset,
    required this.author,
    required this.license,
    required this.title,
    required this.sourceUrl,
  });
}

const cityPhotoList = <CityPhoto>[
  CityPhoto(
    city: 'São Paulo',
    asset: 'assets/cidades/sao-paulo.jpg',
    author: 'Wilfredor',
    license: 'CC0 1.0',
    title: 'Parque Ibirapuera',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Ibirapuera_Park_in_S%C3%A3o_Paulo.jpg',
  ),
  CityPhoto(
    city: 'Ribeirão Preto',
    asset: 'assets/cidades/ribeirao-preto.jpg',
    author: 'And Ribeirão 1980',
    license: 'CC0 1.0',
    title: 'Vista do centro de Ribeirão Preto',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Vista_do_Centro_Expandido_de_Ribeir%C3%A3o_Preto_em_2026.jpg',
  ),
  CityPhoto(
    city: 'Jundiaí',
    asset: 'assets/cidades/jundiai.jpg',
    author: 'Ridiculopathy',
    license: 'CC0 1.0',
    title: 'Ponte Torta',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:May2024._Ponte_Torta,_Jundia%C3%AD,_state_of_S%C3%A3o_Paulo,_Brazil_04.jpg',
  ),
  CityPhoto(
    city: 'Guarujá',
    asset: 'assets/cidades/guaruja.jpg',
    author: 'Jose Roberto Seixas',
    license: 'Domínio público',
    title: 'Praia do Saco do Major',
    sourceUrl:
        'https://commons.wikimedia.org/wiki/File:Praia_do_Saco_do_Major.jpg',
  ),
  CityPhoto(
    city: 'São Bernardo do Campo',
    asset: 'assets/cidades/sao-bernardo-do-campo.jpg',
    author: 'LuanCampSouza93',
    license: 'CC0 1.0',
    title: 'Centro de São Bernardo do Campo',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Centro_de_S%C3%A3o_Bernardo_do_Campo_(3).jpg',
  ),
  CityPhoto(
    city: 'Barueri',
    asset: 'assets/cidades/barueri.jpg',
    author: 'Lucas Garcia',
    license: 'Domínio público',
    title: 'Barueri',
    sourceUrl:
        'https://commons.wikimedia.org/wiki/File:Barueri_S%C3%A3o_Paulo.JPG',
  ),
  CityPhoto(
    city: 'Bertioga',
    asset: 'assets/cidades/bertioga.jpg',
    author: 'RunPass',
    license: illustrationLicense,
    title: 'Forte de Bertioga e a praia',
    sourceUrl: '',
  ),
  CityPhoto(
    city: 'Guaratinguetá',
    asset: 'assets/cidades/guaratingueta.jpg',
    author: 'RunPass',
    license: illustrationLicense,
    title: 'Igreja e a serra',
    sourceUrl: '',
  ),
  CityPhoto(
    city: 'Barra Bonita',
    asset: 'assets/cidades/barra-bonita.jpg',
    author: 'RunPass',
    license: illustrationLicense,
    title: 'Barco na eclusa do rio Tietê',
    sourceUrl: '',
  ),
  CityPhoto(
    city: 'Itanhaém',
    asset: 'assets/cidades/itanhaem.jpg',
    author: 'RunPass',
    license: illustrationLicense,
    title: 'Convento no alto e a praia',
    sourceUrl: '',
  ),
  CityPhoto(
    city: 'Boituva',
    asset: 'assets/cidades/boituva.jpg',
    author: 'RunPass',
    license: illustrationLicense,
    title: 'Paraquedas sobre os campos',
    sourceUrl: '',
  ),
  CityPhoto(
    city: 'Mongaguá',
    asset: 'assets/cidades/mongagua.jpg',
    author: 'RunPass',
    license: illustrationLicense,
    title: 'Píer e a praia',
    sourceUrl: '',
  ),
  CityPhoto(
    city: 'Taciba',
    asset: 'assets/cidades/taciba.jpg',
    author: 'RunPass',
    license: illustrationLicense,
    title: 'Capela e a praça',
    sourceUrl: '',
  ),
  CityPhoto(
    city: 'Mairinque',
    asset: 'assets/cidades/mairinque.jpg',
    author: 'RunPass',
    license: illustrationLicense,
    title: 'Estação e o trem',
    sourceUrl: '',
  ),
  CityPhoto(
    city: 'Bananal',
    asset: 'assets/cidades/bananal.jpg',
    author: 'RunPass',
    license: illustrationLicense,
    title: 'Casarão e o cafezal',
    sourceUrl: '',
  ),
  CityPhoto(
    city: 'Vinhedo',
    asset: 'assets/cidades/vinhedo.jpg',
    author: 'RunPass',
    license: illustrationLicense,
    title: 'Vinhedos',
    sourceUrl: '',
  ),
];

final _byCity = {for (final p in cityPhotoList) foldName(p.city): p};

/// A foto da cidade da corrida (só para corridas de SP, para não confundir cidades de mesmo nome).
CityPhoto? cityPhotoFor(Map<String, dynamic> edition) {
  final state = '${edition['state'] ?? ''}'.trim().toUpperCase();
  if (state != 'SP') return null;
  return _byCity[foldName('${edition['city'] ?? ''}')];
}

/// Cidade conquistada no passaporte: miniatura (a foto de cartão postal da cidade, ou uma arte com a
/// inicial quando ainda não há foto) e o nome embaixo.
class PassportCity extends StatelessWidget {
  final String city;
  final String? state;
  const PassportCity({super.key, required this.city, this.state});

  @override
  Widget build(BuildContext context) {
    final photo = cityPhotoFor({'city': city, 'state': state});
    final seed = city.codeUnits.fold<int>(
      7,
      (h, c) => (h * 31 + c) & 0x7fffffff,
    );
    const palettes = [
      [Color(0xff10213f), Color(0xffff7a1a)],
      [Color(0xff1d3a5f), Color(0xff2f9e8f)],
      [Color(0xff3a1c4d), Color(0xffd9594c)],
    ];
    final colors = palettes[seed % palettes.length];
    return SizedBox(
      width: 78,
      child: Column(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 78,
              height: 58,
              child: photo != null
                  ? Image.asset(
                      photo.asset,
                      key: Key('passport-photo-$city'),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    )
                  : DecoratedBox(
                      key: Key('passport-art-$city'),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: colors,
                        ),
                      ),
                      child: Center(
                        child: Text(
                          city.isEmpty
                              ? '?'
                              : city.characters.first.toUpperCase(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                            fontSize: 26,
                          ),
                        ),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            city,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11),
          ),
        ],
      ),
    );
  }
}
