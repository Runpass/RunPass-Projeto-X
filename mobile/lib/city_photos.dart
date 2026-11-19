import 'new_post.dart' show foldName;

/// Foto de cartão postal de uma cidade, usada como capa quando a corrida não tem banner autorizado.
/// Só entram imagens com licença livre que dispensa crédito obrigatório (CC0 ou domínio público),
/// aprovadas pelo dono da mídia. O crédito de cada uma aparece em Configurações > Créditos das fotos.
class CityPhoto {
  final String city, asset, author, license, title, sourceUrl;
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
];

final _byCity = {for (final p in cityPhotoList) foldName(p.city): p};

/// A foto da cidade da corrida (só para corridas de SP, para não confundir cidades de mesmo nome).
CityPhoto? cityPhotoFor(Map<String, dynamic> edition) {
  final state = '${edition['state'] ?? ''}'.trim().toUpperCase();
  if (state != 'SP') return null;
  return _byCity[foldName('${edition['city'] ?? ''}')];
}
