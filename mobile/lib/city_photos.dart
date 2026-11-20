import 'package:flutter/material.dart';

import 'catalog_screen.dart' show RaceKind, raceKind;
import 'new_post.dart' show foldName;

/// Foto de cartão postal de uma cidade, usada como capa quando a corrida não tem banner autorizado.
/// Só fotos reais com licença livre (CC0, domínio público, CC BY ou CC BY-SA; as CC BY pedem o nome do
/// autor, que aparece nos créditos), aprovadas pelo dono da mídia (decisão de 20/11/2026: nada de ilustração). O crédito de cada uma aparece em Configurações > Créditos das fotos.
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
    city: 'Sorocaba',
    asset: 'assets/cidades/sorocaba.jpg',
    author: 'Maribelfotos',
    license: 'CC0 1.0',
    title: 'Catedral Metropolitana',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Parte_da_frente_da_catedral.jpg',
  ),
  CityPhoto(
    city: 'Taubaté',
    asset: 'assets/cidades/taubate.jpg',
    author: 'Themium',
    license: 'CC0 1.0',
    title: 'Catedral de São Francisco das Chagas',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Catedral_de_S%C3%A3o_Francisco_das_Chagas,_Taubat%C3%A9_5.jpg',
  ),
  CityPhoto(
    city: 'Bauru',
    asset: 'assets/cidades/bauru.jpg',
    author: 'Carlosar',
    license: 'Domínio público',
    title: 'Parque Vitória Régia',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:ParqueVitoriaRegia_Bauru_SP_2007.jpg',
  ),
  CityPhoto(
    city: 'Porto Feliz',
    asset: 'assets/cidades/porto-feliz.jpg',
    author: 'Mau the Intrepid',
    license: 'Domínio público',
    title: 'Praça central e igreja matriz',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Praca_Porto_Feliz.jpg',
  ),
  CityPhoto(
    city: 'Presidente Prudente',
    asset: 'assets/cidades/presidente-prudente.jpg',
    author: 'Fabianofcarlos',
    license: 'CC BY-SA 4.0',
    title: 'Parque do Povo',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Parque_do_Povo_em_Presidente_Prudente.jpg',
  ),
  CityPhoto(
    city: 'Araraquara',
    asset: 'assets/cidades/araraquara.jpg',
    author: 'Sturm',
    license: 'CC BY-SA 4.0',
    title: 'Igreja Matriz de São Bento',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Araraquara_(2020_October)_181.jpg',
  ),
  CityPhoto(
    city: 'Valinhos',
    asset: 'assets/cidades/valinhos.jpg',
    author: 'David Alves Silva, o próprio usuário',
    license: 'CC0 1.0',
    title: 'Praça Brasil 500 Anos',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Pra%C3%A7a_Brasil_500_Anos.jpg',
  ),
  CityPhoto(
    city: 'Araçatuba',
    asset: 'assets/cidades/aracatuba.jpg',
    author: 'caiocapelari',
    license: 'CC0 1.0',
    title: 'Avenida com ipês floridos',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Ara%C3%A7atuba_pompeu_ip%C3%AA.jpg',
  ),
  CityPhoto(
    city: 'Santos',
    asset: 'assets/cidades/santos.jpg',
    author: 'Rogério Cassimiro / MTur Destinos',
    license: 'Domínio público',
    title: 'Bondinho e a antiga estação do Valongo',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:ROGERIO_CASSIMIRO_bondinho_SANTOS_SP_(26033618427).jpg',
  ),
  CityPhoto(
    city: 'Campos do Jordão',
    asset: 'assets/cidades/campos-do-jordao.jpg',
    author: 'Marco Ankosqui/MTur.',
    license: 'CC0 1.0',
    title: 'Vista aérea da cidade',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Campos_do_Jord%C3%A3o,_vista_de_cima.jpg',
  ),
  CityPhoto(
    city: 'Embu das Artes',
    asset: 'assets/cidades/embu-das-artes.jpg',
    author: 'DeivsonPrescovia',
    license: 'Domínio público',
    title: 'Igreja Nossa Senhora do Rosário',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Igreja_Nossa_Senhora_do_Ros%C3%A1rio_em_Embu_das_Artes.JPG',
  ),
  CityPhoto(
    city: 'Guararema',
    asset: 'assets/cidades/guararema.jpg',
    author: 'Prefeitura de Guararema',
    license: 'CC0 1.0',
    title: 'Maria-Fumaça na estação',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Passeio_de_Maria-Fuma%C3%A7a_em_Guararema.jpg',
  ),
  CityPhoto(
    city: 'Votuporanga',
    asset: 'assets/cidades/votuporanga.jpg',
    author: 'ASCOM Prefeitura de Votuporanga',
    license: 'Domínio público',
    title: 'Vista aérea do centro',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Vista_a%C3%A9rea_Votuporanga_geral_2020_(51691667759).jpg',
  ),
  CityPhoto(
    city: 'Limeira',
    asset: 'assets/cidades/limeira.jpg',
    author: 'Geogast',
    license: 'CC BY 4.0',
    title: 'Igreja Luterana',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Igreja_Luterana_(IECLB)_de_Limeira_(SP)_%E2%80%A2_3.jpg',
  ),
  CityPhoto(
    city: 'Itapetininga',
    asset: 'assets/cidades/itapetininga.jpg',
    author: 'Knightstalker at English Wikipedia',
    license: 'Domínio público',
    title: 'Largo dos Amores a noite',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Itapetininga_-_Largo_dos_Amores.jpg',
  ),
  CityPhoto(
    city: 'Guarulhos',
    asset: 'assets/cidades/guarulhos.jpg',
    author: 'Humanoo',
    license: 'Domínio público',
    title: 'Vista aérea do centro',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Vista_da_cidade_de_Guarulhos_(SP).JPG',
  ),
  CityPhoto(
    city: 'Mogi das Cruzes',
    asset: 'assets/cidades/mogi-das-cruzes.jpg',
    author: 'Tetizeraz',
    license: 'CC0 1.0',
    title: 'Vista da cidade',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Vis%C3%A3o_panor%C3%A2mica_de_Mogi_das_Cruzes_a_partir_da_Esta%C3%A7%C3%A3o_Estudantes.jpg',
  ),
  CityPhoto(
    city: 'Suzano',
    asset: 'assets/cidades/suzano.jpg',
    author: 'OS2Warp',
    license: 'Domínio público',
    title: 'Prefeitura',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Sede_da_Prefeitura_de_Suzano.jpg',
  ),
  CityPhoto(
    city: 'Araçariguama',
    asset: 'assets/cidades/aracariguama.jpg',
    author: 'OS2Warp',
    license: 'Domínio público',
    title: 'Igreja matriz',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Igreja_matriz_de_Ara%C3%A7ariguama.jpg',
  ),
  CityPhoto(
    city: 'Ubatuba',
    asset: 'assets/cidades/ubatuba.jpg',
    author: 'MTur Destinos',
    license: 'Domínio público',
    title: 'Igreja Matriz',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:ROGERIOCASSIMIRO_IGREJAMATRIZ_UBATUBA_SP_(40957704871).jpg',
  ),
  CityPhoto(
    city: 'Peruíbe',
    asset: 'assets/cidades/peruibe.jpg',
    author: 'Onjacktallcuca',
    license: 'Domínio público',
    title: 'Praia de Peruíbe',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Peruibe_beach.JPG',
  ),
  CityPhoto(
    city: 'Rio Claro',
    asset: 'assets/cidades/rio-claro.jpg',
    author: 'Anne Valladares',
    license: 'Domínio público',
    title: 'Lago do Horto Florestal',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:HortoFlorestalRioClaro_4248.jpg',
  ),
  CityPhoto(
    city: 'Caraguatatuba',
    asset: 'assets/cidades/caraguatatuba.jpg',
    author: 'MTur Destinos',
    license: 'Domínio público',
    title: 'Igreja do Divino Espírito Santo',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:ROGERIO_CASSIMIRO_Igreja_Divino_Esp%C3%ADrito_Santo_CARAGUATATUBA_SP_(40254340765).jpg',
  ),
  CityPhoto(
    city: 'São José dos Campos',
    asset: 'assets/cidades/sao-jose-dos-campos.jpg',
    author: 'ZeroTwoAndHiroWW2',
    license: 'CC0 1.0',
    title: 'Igreja Matriz de São Francisco Xavier',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Igreja_Matriz_de_S%C3%A3o_Francisco_Xavier,_no_distrito_hom%C3%B3nimo_em_S%C3%A3o_Jos%C3%A9_dos_Campos_-_SP.jpg',
  ),
  CityPhoto(
    city: 'Osasco',
    asset: 'assets/cidades/osasco.jpg',
    author: 'Chadner',
    license: 'Domínio público',
    title: 'Vista aérea do centro',
    sourceUrl:
        'https://commons.wikimedia.org/wiki/File:Caio_Badner_-_Osasco.JPG',
  ),
  CityPhoto(
    city: 'Campinas',
    asset: 'assets/cidades/campinas.jpg',
    author: 'Daniel Alves from Brazil',
    license: 'Domínio público',
    title: 'Lagoa do Taquaral',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Parque_Portugal,_Lagoa_do_Taquaral,_Campinas,_Brazil_(51381049762).jpg',
  ),
  CityPhoto(
    city: 'Tremembé',
    asset: 'assets/cidades/tremembe.jpg',
    author: 'Themium',
    license: 'CC0 1.0',
    title: 'Basílica do Bom Jesus',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Bas%C3%ADlica_Bom_Jesus_de_Trememb%C3%A9,_SP_06.jpg',
  ),
  CityPhoto(
    city: 'Cunha',
    asset: 'assets/cidades/cunha.jpg',
    author: 'Themium',
    license: 'CC0 1.0',
    title: 'Morros de Cunha',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Morros_em_Cunha,_S%C3%A3o_Paulo_1.jpg',
  ),
  CityPhoto(
    city: 'Mairiporã',
    asset: 'assets/cidades/mairipora.jpg',
    author: 'OS2Warp',
    license: 'Domínio público',
    title: 'Represa Paulo de Paiva Castro',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Represa_Paulo_de_Paiva_Castro.jpg',
  ),
  CityPhoto(
    city: 'Aparecida',
    asset: 'assets/cidades/aparecida.jpg',
    author: 'Marcos Elias de Oliveira Júnior',
    license: 'CC0 1.0',
    title: 'Santuário Nacional',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Santu%C3%A1rio_Nacional_de_Aparecida_(SP).jpg',
  ),
  CityPhoto(
    city: 'Bertioga',
    asset: 'assets/cidades/bertioga.jpg',
    author: 'CORRETOR-CARVALHO',
    license: 'CC BY-SA 3.0',
    title: 'Forte São Felipe e a Praia da Enseada',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:FORTE_S%C3%83O_FELIPE_e_FAROL_DA_PEDRA_DO_CORVO_-_VISTOS_DA_PRAIA_DA_ENSEADA_-_BERTIOGA-SP_-_panoramio.jpg',
  ),
  CityPhoto(
    city: 'Guaratinguetá',
    asset: 'assets/cidades/guaratingueta.jpg',
    author: 'Túllio F',
    license: 'CC BY-SA 4.0',
    title: 'Estação Ferroviária',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Esta%C3%A7%C3%A3o_Ferrovi%C3%A1ria_de_Guaratinguet%C3%A1.jpg',
  ),
  CityPhoto(
    city: 'Barra Bonita',
    asset: 'assets/cidades/barra-bonita.jpg',
    author: 'José Reynaldo da Fonseca (REFON)',
    license: 'CC BY 2.5',
    title: 'Ponte sobre o rio Tietê',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Barra_Bonita_turismo_-a-_150606_REFON.jpg',
  ),
  CityPhoto(
    city: 'Itanhaém',
    asset: 'assets/cidades/itanhaem.jpg',
    author: 'Johnata Zorzi',
    license: 'CC BY-SA 4.0',
    title: 'Igreja Matriz de Santana',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Igreja_Matriz_de_Santana_-_Itanha%C3%A9m_-_por_Johnata_Zorzi.jpg',
  ),
  CityPhoto(
    city: 'Boituva',
    asset: 'assets/cidades/boituva.jpg',
    author: 'Webysther Nunes',
    license: 'CC BY-SA 4.0',
    title: 'Balões em Boituva',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Webysther_20140125062307_-_Bal%C3%A3o_boituva.jpg',
  ),
  CityPhoto(
    city: 'Mongaguá',
    asset: 'assets/cidades/mongagua.jpg',
    author: 'enioprado',
    license: 'CC BY-SA 3.0',
    title: 'Ponte e o rio',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Mongagu%C3%A1_-_panoramio_-_enioprado.jpg',
  ),
  CityPhoto(
    city: 'Taciba',
    asset: 'assets/cidades/taciba.jpg',
    author: 'Edmarjr',
    license: 'CC BY-SA 3.0',
    title: 'Rio Laranja Doce',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Rio_Laranja_Doce_-_Taciba_SP_-_panoramio.jpg',
  ),
  CityPhoto(
    city: 'Mairinque',
    asset: 'assets/cidades/mairinque.jpg',
    author: 'zardeto',
    license: 'CC BY 3.0',
    title: 'Estação Dona Catarina',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Esta%C3%A7%C3%A3o_Dona_Catarina_do_antigo_tra%C3%A7ado_da_Estrada_de_Ferro_Sorocabana_-_EFS_(Itu-Mairinque)_em_Mairinque_-_panoramio.jpg',
  ),
  CityPhoto(
    city: 'Bananal',
    asset: 'assets/cidades/bananal.jpg',
    author: 'Halley Pacheco de Oliveira',
    license: 'CC BY-SA 3.0',
    title: 'Igreja Nossa Senhora do Rosário',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Igreja_Nossa_Senhora_do_Ros%C3%A1rio_em_Bananal.jpg',
  ),
  CityPhoto(
    city: 'Vinhedo',
    asset: 'assets/cidades/vinhedo.jpg',
    author: 'Daniel Alves from Brazil',
    license: 'Domínio público',
    title: 'Vista da cidade',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Vinhedo,_S%C3%A3o_Paulo,_Brazil_(51382370522).jpg',
  ),
];

// A principal de cada cidade; cidade só com fotos em [moreCityPhotos] usa uma delas (também no passaporte).
final _byCity = {
  for (final p in [...moreCityPhotos, ...cityPhotoList]) foldName(p.city): p,
};

/// Mais fotos das cidades com muitas corridas (além da principal, em [cityPhotoList]): assim a lista
/// alterna as fotos em vez de repetir a mesma.
const moreCityPhotos = <CityPhoto>[
  CityPhoto(
    city: 'Campinas',
    asset: 'assets/cidades/campinas-2.jpg',
    author: 'Parzeus',
    license: 'CC BY-SA 4.0',
    title: 'Catedral Metropolitana',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Catedral_Metropolitana_de_Campinas_-_29.05.2021_01.jpg',
  ),
  CityPhoto(
    city: 'Campinas',
    asset: 'assets/cidades/campinas-3.jpg',
    author: 'Fasouzafreitas',
    license: 'CC BY-SA 3.0',
    title: 'Jardim Proença',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Campinas_-_SP_-_Jardim_Proen%C3%A7a_visto_da_Rua_Proen%C3%A7a.JPG',
  ),
  CityPhoto(
    city: 'Campinas',
    asset: 'assets/cidades/campinas-4.jpg',
    author: 'Raphael Henrique Figueira',
    license: 'CC BY-SA 4.0',
    title: 'Lagoa do Taquaral',
    sourceUrl:
        'https://commons.wikimedia.org/wiki/File:Parque_Portugal_(7).jpg',
  ),
  CityPhoto(
    city: 'Campinas',
    asset: 'assets/cidades/campinas-5.jpg',
    author: 'Elson Júnior',
    license: 'CC BY 2.0',
    title: 'Vista da cidade',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Campinas_skyline.jpg',
  ),
  CityPhoto(
    city: 'Jundiaí',
    asset: 'assets/cidades/jundiai-2.jpg',
    author: 'Daniel Pavan e Silva',
    license: 'CC BY-SA 3.0',
    title: 'Avenida Nove de Julho',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Jundia%C3%AD2015.jpg',
  ),
  CityPhoto(
    city: 'Jundiaí',
    asset: 'assets/cidades/jundiai-3.jpg',
    author: 'FernandoSantos',
    license: 'CC BY-SA 3.0',
    title: 'Jundiaí',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Jundia%C3%AD_-_SP_-_panoramio_(777).jpg',
  ),
  CityPhoto(
    city: 'Sorocaba',
    asset: 'assets/cidades/sorocaba-2.jpg',
    author: 'RobSabino',
    license: 'CC BY 2.0',
    title: 'Rio Sorocaba',
    sourceUrl:
        'https://commons.wikimedia.org/wiki/File:Rio_Sorocaba_(cropped).jpg',
  ),
  CityPhoto(
    city: 'Sorocaba',
    asset: 'assets/cidades/sorocaba-3.jpg',
    author: 'Setheus',
    license: 'Domínio público',
    title: 'Vista da cidade',
    sourceUrl:
        'https://commons.wikimedia.org/wiki/File:Sorocaba_view_flat2.jpg',
  ),
  CityPhoto(
    city: 'Piracicaba',
    asset: 'assets/cidades/piracicaba-2.jpg',
    author: 'Ana Paula Hirama',
    license: 'CC BY-SA 3.0',
    title: 'Vista da cidade',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Piracicaba_(3).jpg',
  ),
  CityPhoto(
    city: 'Piracicaba',
    asset: 'assets/cidades/piracicaba-3.jpg',
    author: 'Bruno.karklis',
    license: 'CC BY-SA 3.0',
    title: 'Rio Piracicaba',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Rio_Piracicaba.jpg',
  ),
  CityPhoto(
    city: 'São Bernardo do Campo',
    asset: 'assets/cidades/sao-bernardo-do-campo-2.jpg',
    author: 'Lukaaz',
    license: 'CC BY-SA 3.0',
    title: 'Vista da cidade',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:S%C3%A3o_Bernardo_do_Campo_(S%C3%A3o_Paulo).jpg',
  ),
  CityPhoto(
    city: 'Santos',
    asset: 'assets/cidades/santos-2.jpg',
    author: 'VicTrindade',
    license: 'CC BY-SA 4.0',
    title: 'Jardim da Praia',
    sourceUrl:
        'https://commons.wikimedia.org/wiki/File:Jardim_da_Praia_de_Santos.jpg',
  ),
  CityPhoto(
    city: 'Santos',
    asset: 'assets/cidades/santos-3.jpg',
    author: 'VicTrindade',
    license: 'CC BY-SA 4.0',
    title: 'Praia de Santos',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Peda%C3%A7o_da_Praia_de_Santos.jpg',
  ),
  CityPhoto(
    city: 'Guarulhos',
    asset: 'assets/cidades/guarulhos-2.jpg',
    author: 'FernandoSantos',
    license: 'CC BY-SA 3.0',
    title: 'Vista da cidade',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Guarulhos_-_SP_-_panoramio_(152).jpg',
  ),
  CityPhoto(
    city: 'São José dos Campos',
    asset: 'assets/cidades/sao-jose-dos-campos-2.jpg',
    author: 'Mike Peel',
    license: 'CC BY-SA 4.0',
    title: 'Vista da cidade ao entardecer',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:At_S%C3%A3o_Jos%C3%A9_dos_Campos_2019_04.jpg',
  ),
  CityPhoto(
    city: 'Indaiatuba',
    asset: 'assets/cidades/indaiatuba-2.jpg',
    author: 'FernandoSantos',
    license: 'CC BY-SA 3.0',
    title: 'Parque Ecológico',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Indaiatuba_-_SP_-_panoramio_(26).jpg',
  ),
  CityPhoto(
    city: 'Barueri',
    asset: 'assets/cidades/barueri-2.jpg',
    author: 'Gervacio Rosales',
    license: 'CC BY 3.0',
    title: 'Alphaville',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Alphaville_Industrial,_Barueri_-_SP,_Brazil_-_panoramio_(3).jpg',
  ),
  CityPhoto(
    city: 'Ribeirão Preto',
    asset: 'assets/cidades/ribeirao-preto-2.jpg',
    author: 'Anderson Bueno Pereira',
    license: 'CC0 1.0',
    title: 'Anel Viário Sul',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Anel_Vi%C3%A1rio_Sul_Ribeir%C3%A3o_Preto.jpg',
  ),
  CityPhoto(
    city: 'Ribeirão Preto',
    asset: 'assets/cidades/ribeirao-preto-3.jpg',
    author: 'Fasouzafreitas',
    license: 'CC BY-SA 4.0',
    title: 'Avenida e o córrego',
    sourceUrl:
        'https://commons.wikimedia.org/wiki/File:Ribeir%C3%A3o_Preto_-_SP.JPG',
  ),
  CityPhoto(
    city: 'Bertioga',
    asset: 'assets/cidades/bertioga-2.jpg',
    author: 'ThiagoALacerda',
    license: 'CC BY-SA 4.0',
    title: 'Parque Estadual Restinga de Bertioga',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Parque_Estadual_Restinga_de_Bertioga_-_Thiago_Altran_(01).jpg',
  ),
  CityPhoto(
    city: 'Bertioga',
    asset: 'assets/cidades/bertioga-3.jpg',
    author: 'Daniel Souza Lima',
    license: 'CC BY-SA 4.0',
    title: 'Canal de Bertioga',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:SP_Bertioga_-_Canal_de_Bertioga.JPG',
  ),
  CityPhoto(
    city: 'São José do Rio Preto',
    asset: 'assets/cidades/sao-jose-do-rio-preto-2.jpg',
    author: 'Creedence',
    license: 'CC BY-SA 4.0',
    title: 'Centro da cidade',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Centro_de_S%C3%A3o_Jos%C3%A9_do_Rio_Preto,_SP.jpg',
  ),
  CityPhoto(
    city: 'Santo André',
    asset: 'assets/cidades/santo-andre-2.jpg',
    author: 'Ramon S. Lopes',
    license: 'CC BY-SA 4.0',
    title: 'Paço Municipal',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Pa%C3%A7o_Municipal_de_Santo_Andr%C3%A9_-_SP.jpg',
  ),
  CityPhoto(
    city: 'Santo André',
    asset: 'assets/cidades/santo-andre-3.jpg',
    author: 'Rafael Vianna Croffi',
    license: 'CC BY 2.0',
    title: 'Parque Celso Daniel',
    sourceUrl:
        'https://commons.wikimedia.org/wiki/File:Santo_Andr%C3%A9_-_SP.jpg',
  ),
  CityPhoto(
    city: 'Taboão da Serra',
    asset: 'assets/cidades/taboao-da-serra-2.jpg',
    author: 'Reginaldo Maia',
    license: 'CC BY-SA 3.0',
    title: 'Vista aérea do centro',
    sourceUrl:
        'https://commons.wikimedia.org/wiki/File:Tabo%C3%A3o_da_Serra.jpg',
  ),
  CityPhoto(
    city: 'Mogi das Cruzes',
    asset: 'assets/cidades/mogi-das-cruzes-2.jpg',
    author: 'Henrique Boney',
    license: 'CC BY-SA 3.0',
    title: 'Vista do Pico do Urubu',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Vista_de_Mogi_das_Cruzes_a_partir_do_Pico_do_Urubu.JPG',
  ),
  CityPhoto(
    city: 'Mogi das Cruzes',
    asset: 'assets/cidades/mogi-das-cruzes-3.jpg',
    author: 'Greissy Rezende',
    license: 'CC BY-SA 4.0',
    title: 'Praça do Carmo',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Pra%C3%A7a_do_Carmo_-_Mogi_das_Cruzes.jpg',
  ),
  CityPhoto(
    city: 'Caraguatatuba',
    asset: 'assets/cidades/caraguatatuba-2.jpg',
    author: 'Monalisa Duarte dos Reis',
    license: 'CC BY-SA 3.0',
    title: 'Praia do Capricórnio',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Caraguatatuba,Brasil.Praia_do_Capric%C3%B3rnio.jpg',
  ),
  CityPhoto(
    city: 'Taubaté',
    asset: 'assets/cidades/taubate-2.jpg',
    author: 'enioprado',
    license: 'CC BY-SA 3.0',
    title: 'Vista da cidade',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Taubat%C3%A9_SP_-_panoramio.jpg',
  ),
  CityPhoto(
    city: 'Taubaté',
    asset: 'assets/cidades/taubate-3.jpg',
    author: 'HelenCampos',
    license: 'CC BY-SA 4.0',
    title: 'Pôr do sol',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:P%C3%B4r_do_sol_em_Taubat%C3%A9_-_S%C3%A3o_Paulo.jpg',
  ),
  CityPhoto(
    city: 'Americana',
    asset: 'assets/cidades/americana-2.jpg',
    author: 'Alex Ribeiro',
    license: 'CC BY-SA 3.0',
    title: 'Bosque dos Ipês',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Bosque_dos_Ip%C3%AAs,_Americana_-_SP,_Brazil_-_panoramio.jpg',
  ),
  CityPhoto(
    city: 'Campos do Jordão',
    asset: 'assets/cidades/campos-do-jordao-2.jpg',
    author: 'Mike Peel',
    license: 'CC BY-SA 4.0',
    title: 'Centro de Capivari',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:At_Campos_do_Jord%C3%A3o_2019_78.jpg',
  ),
  CityPhoto(
    city: 'Campos do Jordão',
    asset: 'assets/cidades/campos-do-jordao-3.jpg',
    author: 'Mike Peel',
    license: 'CC BY-SA 4.0',
    title: 'Casas em estilo alpino',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:At_Campos_do_Jord%C3%A3o_2019_72.jpg',
  ),
  CityPhoto(
    city: 'Campos do Jordão',
    asset: 'assets/cidades/campos-do-jordao-4.jpg',
    author: 'Leandro Neumann Ciuffo',
    license: 'CC BY 2.0',
    title: 'Vista da cidade',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Campos_do_Jord%C3%A3o_2012.jpg',
  ),
  CityPhoto(
    city: 'Sorocaba',
    asset: 'assets/cidades/sorocaba-4.jpg',
    author: 'Luiz Renato Tezotto de Moura Haro Firmo',
    license: 'CC0 1.0',
    title: 'Mosteiro de São Bento e Igreja de Santana',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Mosteiro_de_S%C3%A3o_Bento_e_Igreja_de_Santana.jpg',
  ),
  CityPhoto(
    city: 'Guarulhos',
    asset: 'assets/cidades/guarulhos-3.jpg',
    author: 'CORRETOR-CARVALHO',
    license: 'CC BY-SA 3.0',
    title: 'Lago dos Patos',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:ILHA-LAGO_DOS_PATOS-GUARULHOS-SP_-_panoramio.jpg',
  ),
  CityPhoto(
    city: 'São Bernardo do Campo',
    asset: 'assets/cidades/sao-bernardo-do-campo-3.jpg',
    author: 'DeboraBach',
    license: 'CC BY-SA 4.0',
    title: 'Represa Billings',
    sourceUrl:
        'https://commons.wikimedia.org/wiki/File:Represa_Billings,_2021.jpg',
  ),
  CityPhoto(
    city: 'São Bernardo do Campo',
    asset: 'assets/cidades/sao-bernardo-do-campo-4.jpg',
    author: 'Vsbraga',
    license: 'CC0 1.0',
    title: 'Pôr do sol na Represa Billings',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Por_do_sol_na_represa_Billings.jpg',
  ),
  CityPhoto(
    city: 'Santo André',
    asset: 'assets/cidades/santo-andre-4.jpg',
    author: 'Vertematti',
    license: 'CC BY-SA 4.0',
    title: 'Vista da Vila de Paranapiacaba',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Vis%C3%A3o_Panor%C3%A2mica_da_Cidade.jpg',
  ),
  CityPhoto(
    city: 'Santo André',
    asset: 'assets/cidades/santo-andre-5.jpg',
    author: 'Isangela Borges',
    license: 'CC BY-SA 4.0',
    title: 'Relógio de Paranapiacaba',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Vila_de_Paranapiacaba_-_Seu_rel%C3%B3gio,_seu_tempo.jpg',
  ),
  CityPhoto(
    city: 'Jundiaí',
    asset: 'assets/cidades/jundiai-4.jpg',
    author: 'joao batista Shimoto',
    license: 'CC BY-SA 3.0',
    title: 'Serra do Japi',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Serra_do_Japi._-_panoramio_(5).jpg',
  ),
  CityPhoto(
    city: 'Piracicaba',
    asset: 'assets/cidades/piracicaba-4.jpg',
    author: 'Natanael Alves Ferreira Junior',
    license: 'CC BY-SA 4.0',
    title: 'Rio Piracicaba',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Espelho_espelho_meu,_existe_rio_mais_bonito_que_eu%3F.jpg',
  ),
  CityPhoto(
    city: 'Ribeirão Preto',
    asset: 'assets/cidades/ribeirao-preto-4.jpg',
    author: 'Leandro Maranghetti Lourenço',
    license: 'CC BY-SA 3.0',
    title: 'Theatro Pedro II',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Teatro_Pedro_II-Ribeirao_Preto.jpg',
  ),
  CityPhoto(
    city: 'Santos',
    asset: 'assets/cidades/santos-4.jpg',
    author: 'Emilio Pechini',
    license: 'CC BY 3.0',
    title: 'Monte Serrat',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Monte_Serrat_visto_do_Mercado_-_panoramio.jpg',
  ),
  CityPhoto(
    city: 'Santos',
    asset: 'assets/cidades/santos-5.jpg',
    author: 'Mike Peel',
    license: 'CC BY-SA 4.0',
    title: 'Igreja de Santo Antônio do Valongo',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:At_Santos,_Brazil_2017_336.jpg',
  ),
  CityPhoto(
    city: 'São José dos Campos',
    asset: 'assets/cidades/sao-jose-dos-campos-3.jpg',
    author: 'Paulo Roberto de Souza',
    license: 'CC BY-SA 2.0',
    title: 'Parque da Cidade',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Vista_do_Parque_da_Cidade,_S%C3%A3o_Jos%C3%A9_dos_Campos_SP.jpg',
  ),
  CityPhoto(
    city: 'Taubaté',
    asset: 'assets/cidades/taubate-4.jpg',
    author: 'Sturm',
    license: 'CC BY-SA 4.0',
    title: 'Igreja Santa Terezinha',
    sourceUrl: 'https://commons.wikimedia.org/wiki/File:Igreja_Santa_Terezinha_de_Taubat%C3%A9_(Sep_2019)_08.jpg',
  ),
];

final _moreByCity = () {
  final map = <String, List<CityPhoto>>{};
  for (final p in moreCityPhotos) {
    map.putIfAbsent(foldName(p.city), () => []).add(p);
  }
  return map;
}();

/// A foto da cidade da corrida (só para corridas de SP, para não confundir cidades de mesmo nome).
CityPhoto? cityPhotoFor(Map<String, dynamic> edition) {
  final state = '${edition['state'] ?? ''}'.trim().toUpperCase();
  if (state != 'SP') return null;
  return _byCity[foldName('${edition['city'] ?? ''}')];
}

/// Pontos da capital: a corrida vai para a imagem do lugar pelo local (ou pelo nome) da prova.
/// Cada ponto lista as palavras (sem acento, em minúsculas) que o identificam.
final spLandmarks = <(List<String>, CityPhoto)>[
  (['ibirapuera', 'obelisco', 'pedro alvares cabral'], cityPhotoList.first),
  (['pacaembu', 'charles miller', 'charles muller'], _spPacaembu),
  (['morumbi', 'tricolor'], _spMorumbi),
  (
    [
      'estaiada',
      'rio pinheiros',
      'run the bridge',
      'vila olimpia',
      'jk iguatemi',
      'cidade jardim',
      'vila nova conceicao',
    ],
    _spEstaiada,
  ),
  (['villa lobos', 'villa-lobos', 'vila lobos'], _spVillaLobos),
  (['parque do povo'], _spParqueDoPovo),
  (['campo de marte', 'santana', 'center norte'], _spCampoDeMarte),
  (['paulista', 'masp', 'sao silvestre'], _spMasp),
  (['anhangabau', 'patriarca', 'farol santander'], _spAnhangabau),
  (['catedral da se', 'praca da se'], _spSe),
  (['independencia', 'ipiranga'], _spIpiranga),
  (['jardim da luz', 'parque da luz'], _spLuz),
];

const _spMasp = CityPhoto(
  city: 'São Paulo',
  asset: 'assets/cidades/sp-masp.jpg',
  author: 'Wilfredor',
  license: 'CC0 1.0',
  title: 'MASP, na Avenida Paulista',
  sourceUrl: 'https://commons.wikimedia.org/wiki/File:MASP_Brazil.jpg',
);
const _spSe = CityPhoto(
  city: 'São Paulo',
  asset: 'assets/cidades/sp-se.jpg',
  author: 'Helena Panzera',
  license: 'CC0 1.0',
  title: 'Catedral da Sé',
  sourceUrl: 'https://commons.wikimedia.org/wiki/File:Catedral_da_S%C3%A9_-_S%C3%A3o_Paulo,_Brasil.jpg',
);
const _spLuz = CityPhoto(
  city: 'São Paulo',
  asset: 'assets/cidades/sp-jardim-da-luz.jpg',
  author: 'Marcos Elias de Oliveira Júnior',
  license: 'CC0 1.0',
  title: 'Jardim da Luz',
  sourceUrl: 'https://commons.wikimedia.org/wiki/File:Parque_Jardim_da_Luz,_S%C3%A3o_Paulo_(SP).jpg',
);
const _spEstaiada = CityPhoto(
  city: 'São Paulo',
  asset: 'assets/cidades/sp-ponte-estaiada.jpg',
  author: 'ikedaleo',
  license: 'CC0 1.0',
  title: 'Ponte Estaiada e o Rio Pinheiros',
  sourceUrl: 'https://commons.wikimedia.org/wiki/File:Ponte_Oct%C3%A1vio_Frias_de_Oliveira,_S%C3%A3o_Paulo,_Brasil.jpg',
);
const _spAnhangabau = CityPhoto(
  city: 'São Paulo',
  asset: 'assets/cidades/sp-anhangabau.jpg',
  author: 'Wilfredor',
  license: 'CC0 1.0',
  title: 'Vale do Anhangabaú',
  sourceUrl: 'https://commons.wikimedia.org/wiki/File:Vale_do_Anhangaba%C3%BA,_Sao_Paulo,_Brasil.jpg',
);
const _spIpiranga = CityPhoto(
  city: 'São Paulo',
  asset: 'assets/cidades/sp-ipiranga.jpg',
  author: 'Enohlar',
  license: 'CC0 1.0',
  title: 'Museu do Ipiranga',
  sourceUrl: 'https://commons.wikimedia.org/wiki/File:Vis%C3%A3o_lateral_do_Museu_do_Ipiranga.jpg',
);
const _spPacaembu = CityPhoto(
  city: 'São Paulo',
  asset: 'assets/cidades/sp-pacaembu.jpg',
  author: 'Rodrigo Soldon',
  license: 'CC BY 2.0',
  title: 'Estádio do Pacaembu',
  sourceUrl:
      'https://commons.wikimedia.org/wiki/File:Est%C3%A1dio_do_Pacaembu_6.jpg',
);
const _spMorumbi = CityPhoto(
  city: 'São Paulo',
  asset: 'assets/cidades/sp-morumbi.jpg',
  author: 'Renato Patinhas',
  license: 'CC BY 3.0',
  title: 'Estádio do Morumbi',
  sourceUrl: 'https://commons.wikimedia.org/wiki/File:Patinhas_esteve_aqui_-_Estadio_do_Morumbi_2_-_panoramio.jpg',
);
const _spVillaLobos = CityPhoto(
  city: 'São Paulo',
  asset: 'assets/cidades/sp-villa-lobos.jpg',
  author: 'Dornicke',
  license: 'CC BY-SA 4.0',
  title: 'Parque Villa-Lobos',
  sourceUrl:
      'https://commons.wikimedia.org/wiki/File:Parque_Villa-Lobos_02.jpg',
);
const _spParqueDoPovo = CityPhoto(
  city: 'São Paulo',
  asset: 'assets/cidades/sp-parque-do-povo.jpg',
  author: 'Vitória Salatine',
  license: 'CC BY-SA 4.0',
  title: 'Parque do Povo',
  sourceUrl:
      'https://commons.wikimedia.org/wiki/File:Parque_do_Povo_19_(cropped).jpg',
);
const _spCampoDeMarte = CityPhoto(
  city: 'São Paulo',
  asset: 'assets/cidades/sp-campo-de-marte.jpg',
  author: 'Peter Louiz',
  license: 'CC BY-SA 3.0',
  title: 'Campo de Marte',
  sourceUrl:
      'https://commons.wikimedia.org/wiki/File:Avi%C3%A3o_Campo_de_Marte.JPG',
);

/// Corrida da capital sem local conhecido: uma destas, sempre a mesma para a mesma corrida.
final spDefaultPhotos = <CityPhoto>[
  cityPhotoList.first,
  _spMasp,
  _spEstaiada,
  _spSe,
  _spAnhangabau,
  _spIpiranga,
  _spLuz,
];

/// Foto noturna da cidade, para corrida noturna.
const _nightByCity = <String, CityPhoto>{'sao paulo': _spNoite};
const _spNoite = CityPhoto(
  city: 'São Paulo',
  asset: 'assets/cidades/sp-noite.jpg',
  author: 'Wilfredor',
  license: 'CC0 1.0',
  title: 'Rio Pinheiros à noite',
  sourceUrl: 'https://commons.wikimedia.org/wiki/File:Vista_Panor%C3%A2mica_de_S%C3%A3o_Paulo_Noite.jpg',
);

/// Foto genérica de corrida para quando a cidade ainda não tem foto: nenhuma corrida fica sem imagem.
const _genericStreet = CityPhoto(
  city: 'Foto genérica',
  asset: 'assets/cidades/generica-rua.jpg',
  author: 'Mark Hillary',
  license: 'CC BY 2.0',
  title: 'Largada de corrida de rua',
  sourceUrl: 'https://commons.wikimedia.org/wiki/File:Corrida_S%C3%A3o_Silvestre_2012.jpg',
);
const _genericTrail = CityPhoto(
  city: 'Foto genérica',
  asset: 'assets/cidades/generica-trilha.jpg',
  author: 'Robeter (English Wikipedia)',
  license: 'Domínio público',
  title: 'Corrida de trilha',
  sourceUrl: 'https://commons.wikimedia.org/wiki/File:Runner-1-.jpg',
);
const _genericNight = CityPhoto(
  city: 'Foto genérica',
  asset: 'assets/cidades/generica-noite.jpg',
  author: 'Marcos Elias de Oliveira Júnior',
  license: 'CC0 1.0',
  title: 'Avenida à noite',
  sourceUrl: 'https://commons.wikimedia.org/wiki/File:BR-405_na_Avenida_da_Independ%C3%AAncia_%C3%A0_noite,_Pau_dos_Ferros_(RN).jpg',
);

/// Todas as imagens do app, na ordem dos créditos.
final allCoverPhotos = <CityPhoto>[
  ...cityPhotoList,
  ...moreCityPhotos,
  _spMasp,
  _spSe,
  _spLuz,
  _spEstaiada,
  _spAnhangabau,
  _spIpiranga,
  _spNoite,
  _spPacaembu,
  _spMorumbi,
  _spVillaLobos,
  _spParqueDoPovo,
  _spCampoDeMarte,
  _genericStreet,
  _genericTrail,
  _genericNight,
];

/// Fotos da capital usadas quando a corrida não tem local conhecido (ou o ponto dela já apareceu na lista).
const _spOthers = <CityPhoto>[
  _spVillaLobos,
  _spParqueDoPovo,
  _spPacaembu,
  _spMorumbi,
  _spCampoDeMarte,
];

/// Imagens possíveis para a corrida, da mais adequada para a menos (a primeira é a capa padrão).
/// Corrida noturna: foto noturna da cidade, ou a genérica da noite. Capital: o ponto pelo local ou nome da
/// prova, depois as fotos da capital (numa ordem própria de cada corrida). Fora dela: a foto da cidade e as
/// genéricas de corrida (do tipo da prova primeiro).
List<CityPhoto> coverCandidatesFor(Map<String, dynamic> edition) {
  final kind = raceKind(edition['name'] as String?);
  final state = '${edition['state'] ?? ''}'.trim().toUpperCase();
  final city = foldName('${edition['city'] ?? ''}'.trim());
  final inSp = state == 'SP';
  if (kind == RaceKind.noturna) {
    return [?(inSp ? _nightByCity[city] : null), _genericNight];
  }
  if (inSp && city == 'sao paulo') {
    final text = foldName('${edition['venue'] ?? ''} ${edition['name'] ?? ''}');
    final id = '${edition['id'] ?? edition['name'] ?? ''}';
    final seed = id.codeUnits.fold<int>(7, (h, c) => (h * 31 + c) & 0x7fffffff);
    final pool = [...spDefaultPhotos, ..._spOthers];
    final start = seed % spDefaultPhotos.length;
    return {
      for (final (keys, photo) in spLandmarks)
        if (keys.any(text.contains)) photo,
      for (var k = 0; k < pool.length; k++) pool[(start + k) % pool.length],
    }.toList();
  }
  final more = state == 'SP'
      ? _moreByCity[city] ?? const <CityPhoto>[]
      : const <CityPhoto>[];
  final id = '${edition['id'] ?? edition['name'] ?? ''}';
  final seed = id.codeUnits.fold<int>(7, (h, c) => (h * 31 + c) & 0x7fffffff);
  return [
    ?cityPhotoFor(edition),
    // As outras fotos da cidade, numa ordem própria de cada corrida.
    for (var k = 0; k < more.length; k++) more[(seed + k) % more.length],
    if (kind == RaceKind.trilha) _genericTrail,
    _genericStreet,
  ];
}

/// Capa escolhida para cada corrida numa lista (corrida -> foto), para a mesma corrida mostrar a mesma foto
/// na lista e na tela dela.
final coverChoices = <String, CityPhoto>{};

/// A imagem da capa da corrida, sempre presente (regra: nenhuma corrida sem imagem): a escolhida pela lista,
/// quando houver, ou a mais adequada.
CityPhoto coverPhotoFor(Map<String, dynamic> edition) {
  final id = edition['id'];
  return (id is String ? coverChoices[id] : null) ??
      coverCandidatesFor(edition).first;
}

/// Escolhe as capas de uma lista na ordem em que aparecem, sem repetir foto enquanto houver outra opção
/// adequada (corridas da mesma cidade fora da capital podem repetir: há uma foto por cidade).
void chooseDistinctCovers(Iterable<Map<String, dynamic>> editions) {
  final used = <String>{};
  for (final edition in editions) {
    final id = edition['id'];
    if (id is! String) continue;
    final options = coverCandidatesFor(edition);
    final pick = options.firstWhere(
      (p) => !used.contains(p.asset),
      orElse: () => options.first,
    );
    used.add(pick.asset);
    coverChoices[id] = pick;
  }
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
