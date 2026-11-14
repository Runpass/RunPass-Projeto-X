import 'identity_gateway.dart';
import 'my_races.dart' show fetchImageBytes;

/// Banner que a própria pessoa sugeriu para esta corrida e a equipe ainda não decidiu. Aparece só para ela,
/// no lugar do banner (marcado como "em análise"); se a equipe não aprovar, deixa de aparecer e chega um aviso.
Future<List<int>?> loadProvisionalBanner(
  IdentityGateway gateway,
  String editionId,
) async {
  try {
    final page = await gateway.request(
      '/me/edition-requests',
      query: {'limit': '50'},
    );
    final mine = [
      for (final item in (page['items'] as List? ?? const []))
        if ((item as Map)['linkedEditionId'] == editionId &&
            item['bannerState'] == null &&
            (item['status'] == 'linked' || item['status'] == 'approved') &&
            (item['details'] as Map?)?['imageReference'] != null)
          item,
    ];
    if (mine.isEmpty) return null;
    final link = await gateway.request(
      '/edition-requests/${Uri.encodeComponent(mine.first['id'] as String)}/banner-image',
    );
    return await fetchImageBytes(link['url'] as String);
  } on Exception {
    return null;
  }
}
