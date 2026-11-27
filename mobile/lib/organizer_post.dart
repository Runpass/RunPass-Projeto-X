import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'runpass_theme.dart';

/// Post do organizador (Instagram ou Facebook) para MOSTRAR na corrida pelo embed oficial da Meta.
///
/// Regras (termos da Meta): só exibir. O app não guarda a imagem nem o texto do post: guarda só o endereço
/// (aprovado pela equipe no portal). O embed vem do oEmbed oficial, sem token, e é desenhado pela própria
/// Meta numa WebView. Se a Meta não responder, o app mostra só um link para abrir o post fora dele.

/// (rede, endereço) quando o endereço é de um post/reel/vídeo que o embed oficial exibe; senão nulo.
({String network, Uri uri})? organizerPostRef(Object? value) {
  if (value is! String || value.length > 500) return null;
  final uri = Uri.tryParse(value.trim());
  if (uri == null || uri.scheme != 'https' || uri.userInfo.isNotEmpty) {
    return null;
  }
  final host = uri.host.toLowerCase();
  final parts = uri.pathSegments.where((p) => p.isNotEmpty).toList();
  final code = RegExp(r'^[A-Za-z0-9_\-]{5,40}$');
  final number = RegExp(r'^\d{5,30}$');
  if (host == 'www.instagram.com' || host == 'instagram.com') {
    if (parts.length == 2 &&
        const ['p', 'reel', 'tv'].contains(parts[0]) &&
        code.hasMatch(parts[1])) {
      return (network: 'instagram', uri: uri);
    }
    return null;
  }
  if (host == 'www.facebook.com' || host == 'facebook.com') {
    if (parts.length == 2 && parts[0] == 'reel' && number.hasMatch(parts[1])) {
      return (network: 'facebook', uri: uri);
    }
    if (parts.length == 3 &&
        const ['posts', 'videos'].contains(parts[1]) &&
        (number.hasMatch(parts[2]) || parts[2].startsWith('pfbid'))) {
      return (network: 'facebook', uri: uri);
    }
  }
  return null;
}

/// Endereço do oEmbed oficial (sem token) para o post.
Uri oembedEndpoint(({String network, Uri uri}) ref) {
  final video =
      ref.uri.path.contains('/videos/') || ref.uri.path.contains('/reel/');
  final path = ref.network == 'instagram'
      ? 'instagram_oembed'
      : (video ? 'oembed_video' : 'oembed_post');
  return Uri.https('graph.facebook.com', '/v25.0/$path', {
    'url': ref.uri.toString(),
    'maxwidth': '500',
  });
}

/// Busca o HTML do embed; nulo se a Meta recusar (post privado, removido, conta com embeds desligados...).
typedef OEmbedFetcher = Future<String?> Function(
  ({String network, Uri uri}) ref,
);

Future<String?> fetchOEmbedHtml(({String network, Uri uri}) ref) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final request = await client
        .getUrl(oembedEndpoint(ref))
        .timeout(const Duration(seconds: 8));
    final response = await request.close().timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) return null;
    final text = await utf8.decoder
        .bind(response)
        .join()
        .timeout(const Duration(seconds: 10));
    final html = (jsonDecode(text) as Map)['html'];
    return html is String && html.isNotEmpty ? html : null;
  } on Object {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// Abre um endereço fora do app. Trocável nos testes.
Future<bool> Function(Uri uri) organizerLinkOpener = (uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

/// Desenha o HTML do embed. Trocável nos testes (a WebView não roda no `flutter test`).
typedef OEmbedViewBuilder = Widget Function(
  BuildContext context,
  String html,
  String network,
);

Widget webViewEmbed(BuildContext context, String html, String network) =>
    _OrganizerWebView(html: html, network: network);

class _OrganizerWebView extends StatefulWidget {
  final String html;
  final String network;
  const _OrganizerWebView({required this.html, required this.network});

  @override
  State<_OrganizerWebView> createState() => _OrganizerWebViewState();
}

class _OrganizerWebViewState extends State<_OrganizerWebView> {
  late final WebViewController controller;

  String get base => widget.network == 'instagram'
      ? 'https://www.instagram.com/'
      : 'https://www.facebook.com/';

  @override
  void initState() {
    super.initState();
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..setNavigationDelegate(
        NavigationDelegate(
          // O embed carrega dentro da página; qualquer outro destino abre fora do app.
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            final inside =
                uri != null &&
                (request.url.startsWith('about:') ||
                    request.url.startsWith('data:') ||
                    request.url == base ||
                    uri.path.contains('/embed') ||
                    uri.host.endsWith('cdninstagram.com') ||
                    uri.host.endsWith('fbcdn.net'));
            if (inside) return NavigationDecision.navigate;
            if (uri != null && uri.scheme == 'https') {
              organizerLinkOpener(uri);
            }
            return NavigationDecision.prevent;
          },
        ),
      )
      ..loadHtmlString(
        '<!doctype html><html><head>'
        '<meta name="viewport" content="width=device-width, initial-scale=1">'
        '<style>body{margin:0;display:flex;justify-content:center}</style>'
        '</head><body>${widget.html}</body></html>',
        baseUrl: base,
      );
  }

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: controller);
}

/// Cartão "Do organizador": o post (quando a Meta entrega o embed) e sempre o link para abri-lo.
class OrganizerPostCard extends StatefulWidget {
  final ({String network, Uri uri}) post;
  final OEmbedFetcher fetcher;
  final OEmbedViewBuilder embedBuilder;
  const OrganizerPostCard({
    super.key,
    required this.post,
    this.fetcher = fetchOEmbedHtml,
    this.embedBuilder = webViewEmbed,
  });

  @override
  State<OrganizerPostCard> createState() => _OrganizerPostCardState();
}

class _OrganizerPostCardState extends State<OrganizerPostCard> {
  late final Future<String?> html = widget.fetcher(widget.post);

  String get networkName =>
      widget.post.network == 'instagram' ? 'Instagram' : 'Facebook';

  @override
  Widget build(BuildContext context) => Card(
    key: const Key('organizer-post'),
    margin: const EdgeInsets.only(bottom: 16),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Do organizador · $networkName',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
          ),
          const SizedBox(height: 8),
          FutureBuilder<String?>(
            future: html,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Padding(
                  key: Key('organizer-post-loading'),
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final data = snapshot.data;
              if (data == null) {
                return Text(
                  'Não foi possível mostrar o post aqui agora. Você ainda pode abri-lo no $networkName.',
                  key: const Key('organizer-post-failed'),
                  style: TextStyle(color: context.muted),
                );
              }
              return SizedBox(
                key: const Key('organizer-post-embed'),
                height: 520,
                child: widget.embedBuilder(context, data, widget.post.network),
              );
            },
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('organizer-post-open'),
              onPressed: () => organizerLinkOpener(widget.post.uri),
              icon: const Icon(Icons.open_in_new_rounded, size: 18),
              label: Text('Abrir no $networkName'),
            ),
          ),
          Text(
            'Conteúdo do organizador, exibido pelo $networkName. O +1Pódio não copia nem guarda este post.',
            style: TextStyle(fontSize: 12, color: context.muted),
          ),
        ],
      ),
    ),
  );
}
