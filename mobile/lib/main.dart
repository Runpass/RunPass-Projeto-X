import 'dart:async' show unawaited;
import 'dart:convert' show jsonEncode;
import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:geolocator/geolocator.dart';

import 'identity_gateway.dart';
import 'br_locations.dart' show brCityCoordinates;
import 'catalog_screen.dart';
import 'friends.dart' show MedalAvatar;
import 'biometrics.dart';
import 'home_screen.dart';
import 'location_picker.dart';
import 'notifications.dart';
import 'password_policy.dart';
import 'profile_photo.dart';
import 'registration_card.dart';
import 'runpass_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ThemeController.load();
  const api = String.fromEnvironment('RUNPASS_API_URL');
  const cognito = String.fromEnvironment('RUNPASS_COGNITO_URL');
  const client = String.fromEnvironment('RUNPASS_COGNITO_CLIENT_ID');
  IdentityGateway? gateway;
  if (api.isNotEmpty && cognito.isNotEmpty && client.isNotEmpty) {
    try {
      gateway = IdentityGateway(
        api: Uri.parse(api),
        cognito: Uri.parse(cognito),
        clientId: client,
        tokenStore: SecureTokenStore(),
      );
    } on ArgumentError {
      gateway = null;
    }
  }
  NotificationCenter.active = true;
  runApp(MainApp(gateway: gateway));
}

class MainApp extends StatelessWidget {
  final IdentityGateway? gateway;
  final bool demonstration;
  final ProfilePhotoPicker photoPicker;
  const MainApp({
    super.key,
    this.gateway,
    this.demonstration = false,
    this.photoPicker = pickProfilePhoto,
  });

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: ThemeController.dark,
    builder: (context, dark, _) => MaterialApp(
      title: '+1Pódio',
      navigatorKey: runPassNavigatorKey,
      navigatorObservers: [runPassRouteObserver],
      // Toque fora de um campo fecha o teclado; o teclado numerico do iOS nao tem tecla de fim.
      builder: (context, shell) {
        final child = GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
          child: shell!,
        );
        return !demonstration
            ? child
            : Column(
                children: [
                  SafeArea(
                    bottom: false,
                    child: Material(
                      color: Colors.amber.shade100,
                      child: const Padding(
                        padding: EdgeInsets.all(8),
                        child: Text(
                          'DEMONSTRAÇÃO LOCAL · Dados fictícios\nUse e-mail .test · Código: 123456',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.black, fontSize: 12),
                        ),
                      ),
                    ),
                  ),
                  Expanded(child: child),
                ],
              );
      },
      theme: runPassTheme(),
      darkTheme: runPassDarkTheme(),
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      // pt_BR para o seletor nativo de data (dia/mes/ano) seguir o formato brasileiro.
      locale: const Locale('pt', 'BR'),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('pt', 'BR')],
      home: IdentityScreen(gateway: gateway, photoPicker: photoPicker),
    ),
  );
}

enum Step {
  signIn,
  signUp,
  confirm,
  setPassword,
  forgot,
  reset,
  profile,
  admission,
  location,
  photo,
  celebration,
  ready,
  waiting,
  closed,
}

class IdentityScreen extends StatefulWidget {
  final IdentityGateway? gateway;

  /// Aviso mostrado na tela de entrada (por exemplo, depois de excluir a conta).
  final String? notice;
  final ProfilePhotoPicker photoPicker;

  /// Falso depois de "Sair" com biometria ligada: nao entra sozinho de volta.
  final bool autoRestore;
  const IdentityScreen({
    super.key,
    this.gateway,
    this.notice,
    this.autoRestore = true,
    this.photoPicker = pickProfilePhoto,
  });
  @override
  State<IdentityScreen> createState() => _IdentityScreenState();
}

class _IdentityScreenState extends State<IdentityScreen> {
  final email = TextEditingController();
  final password = TextEditingController();
  final code = TextEditingController();
  final name = TextEditingController();
  final username = TextEditingController();
  // So pra saber se a mudanca no campo de usuario veio da propria pessoa digitando
  // (campo com foco) ou da sugestao automatica escrevendo por conta propria (sem
  // foco nele): onChanged dispara nos dois casos, so o foco distingue de verdade.
  final usernameFocus = FocusNode();
  // Mesma ideia para o campo de nome: resume()/onTapProfile preenchem name.text
  // programaticamente (sem foco), e isso nao deve re-sugerir o usuario sozinho;
  // so a pessoa digitando ali de verdade (campo com foco) deve.
  final nameFocus = FocusNode();
  final form = GlobalKey<FormState>();
  Step step = Step.signIn;
  bool busy = false, adult = false, full = false;
  // 'female' | 'male' | 'undisclosed'; obrigatorio para a admissao (decisao de 20/11/2026).
  String? gender;
  // Codigo de inscricao da ficha (sorteado pelo servidor, nunca sequencial); so leitura.
  String? registrationCode;
  // Verdadeiro so durante o cadastro que acabou de admitir: mostra a celebracao uma vez.
  bool freshSignup = false;
  // Verdadeiro so entre tocar num bloco da ficha na celebracao e salvar: o "Continuar"
  // deve so corrigir o campo (PATCH /me) e voltar para a celebracao, nunca repetir a
  // acao do cadastro original (recriar perfil, admitir de novo etc).
  bool editingFromCelebration = false;
  // Seletor nativo de rolagem (dia/mes/ano), igual ao Instagram; sem campo de texto livre.
  DateTime? birthDate;
  // Estado e cidade: so por rolagem (lista fechada do IBGE), igual a data de nascimento.
  String? selectedUf;
  String? selectedCity;
  double? selectedLat;
  double? selectedLon;
  // Evita reenviar o mesmo PATCH de localizacao a cada chamada de status() depois
  // que a admissao acontece (selectedUf/selectedCity continuam preenchidos, para a
  // ficha mostrar a cidade nas telas seguintes).
  bool locationSynced = false;
  // So para o botao manual de localizacao mostrar um indicador de carregamento.
  bool detectingLocation = false;
  String? message;
  String? displayName;
  // Cadastro novo ainda sem foto: a foto de perfil e obrigatoria antes de entrar.
  bool needsPhoto = false;
  // "Manter conectado": guarda so o token de renovacao, nunca a senha.
  bool keepSignedIn = true;
  // Entrando com a sessao guardada: mostra um indicador em vez do formulario.
  bool restoring = false;
  List<int>? chosenPhoto;
  // "Ver senha": independente por tela, nao deve seguir marcado entre uma tela e outra.
  bool showPasswordSignIn = false;
  bool showPasswordSetPassword = false;
  // Enquanto false, o campo de usuario e sugerido a partir do nome; vira true assim
  // que a pessoa digita nele por conta propria, e a sugestao automatica para.
  bool usernameTouched = false;

  @override
  void initState() {
    super.initState();
    message = widget.notice;
    email.addListener(() {
      if (mounted && step == Step.signIn) setState(() {});
    });
    // Ficha de inscricao: atualiza ao vivo conforme nome/usuario sao digitados.
    name.addListener(() {
      // Decisao de produto de 21/11/2026: o usuario sempre acompanha o nome, mesmo
      // depois de a pessoa ter editado o campo de usuario na mao — editar o nome de
      // novo reescreve o usuario com a sugestao atual (de proposito, apaga uma
      // personalizacao anterior). usernameTouched volta a false aqui: o campo esta
      // sugerido de novo, nao mais "escolhido a dedo", entao a autocorrecao de
      // usuario-em-uso (mais abaixo) pode agir nele de novo se precisar.
      if (nameFocus.hasFocus) {
        final suggestion = suggestUsername(name.text);
        if (suggestion != username.text) {
          username.value = username.value.copyWith(
            text: suggestion,
            selection: TextSelection.collapsed(offset: suggestion.length),
          );
          usernameTouched = false;
        }
      }
      if (mounted && step == Step.profile) setState(() {});
    });
    username.addListener(() {
      if (mounted && step == Step.profile) setState(() {});
    });
    loadSavedAccount();
    // Le "manter conectado" antes de decidir se restaura a sessao guardada: desligado
    // em Configuracoes, a sessao nao deve voltar sozinha ao abrir o app de novo.
    KeepSignedInPrefs.enabled().then((value) {
      if (mounted) keepSignedIn = value;
      if (value &&
          widget.autoRestore &&
          (widget.gateway?.canRestore ?? false)) {
        restoreSession();
      }
    });
  }

  /// E-mail lembrado deste aparelho e se da para entrar so com o rosto (biometria ligada
  /// e token guardado). A senha nunca e guardada.
  String? savedEmail;
  bool faceReady = false;

  Future<void> loadSavedAccount() async {
    final saved = await SavedAccount.email();
    final gateway = widget.gateway;
    final ready =
        gateway != null &&
        gateway.canRestore &&
        await BiometricPrefs.enabled() &&
        await gateway.hasStoredSession &&
        await biometricGate.available();
    if (!mounted) return;
    setState(() {
      savedEmail = saved;
      faceReady = ready;
      if (saved != null && email.text.isEmpty) email.text = saved;
    });
  }

  /// O e-mail digitado e o da conta lembrada neste aparelho.
  bool get emailIsSaved =>
      savedEmail != null &&
      email.text.trim().toLowerCase() == savedEmail!.toLowerCase();

  /// Mostra "Entrar com biometria" quando a trava esta ligada e ha sessao guardada.
  bool biometricLocked = false;

  Future<void> restoreSession() async {
    setState(() => restoring = true);
    try {
      // Sessao trancada pelo "Sair": o proprio Keychain pede o rosto ao ler o token, entao
      // nao ha segundo pedido aqui.
      if (await BiometricPrefs.enabled() && !await widget.gateway!.isLocked) {
        // Trava ligada: a biometria vem antes de renovar o acesso. Falhou ou cancelou:
        // cai na tela de entrada (senha) com o botao para tentar de novo.
        final ok = await biometricGate.authenticate(
          'Entrar no +1Pódio com a biometria',
        );
        if (!ok) {
          if (mounted) {
            setState(() {
              restoring = false;
              biometricLocked = true;
            });
          }
          return;
        }
      }
      if (await widget.gateway!.restoreSession()) {
        await resume();
        if (mounted && step == Step.ready) {
          openHome();
          return;
        }
      }
    } on Exception {
      // Sem rede ou falha: cai na tela de entrada; a sessao guardada continua valendo.
    }
    if (mounted) {
      setState(() => restoring = false);
      loadSavedAccount();
    }
  }

  @override
  void dispose() {
    for (final field in [email, password, code, name, username]) {
      field.dispose();
    }
    usernameFocus.dispose();
    nameFocus.dispose();
    super.dispose();
  }

  void change(Step next) {
    setState(() {
      step = next;
      message = null;
    });
  }

  Future<void> status() async {
    final response = await widget.gateway!.request('/beta/status');
    full = response['admissionsOpen'] != true;
    // Estado/cidade escolhidos no cadastro (Step.location) so podem ser salvos depois da
    // admissao: PATCH /me exige conta admitida. Enviar aqui, na primeira vez que o status
    // acusar admissao, cobre tanto o caso comum (admissao imediata) quanto quem ficou na
    // lista de espera e foi admitido depois, numa checagem de status futura.
    if (response['myStatus'] == 'admitted' &&
        !locationSynced &&
        selectedUf != null &&
        selectedCity != null) {
      final current = await widget.gateway!.request('/me');
      await widget.gateway!.request(
        '/me',
        method: 'PATCH',
        body: {
          'expectedVersion': current['version'],
          ...brLocationPatch(
            selectedUf!,
            selectedCity!,
            selectedLat,
            selectedLon,
          ),
        },
      );
      // Mantem selectedUf/selectedCity (nao zera): a ficha de inscricao usa esses
      // mesmos campos para mostrar a cidade nas telas seguintes (foto, celebracao).
      // O proprio flag evita reenviar o mesmo PATCH numa chamada futura a status().
      locationSynced = true;
    }
    step = switch (response['myStatus']) {
      'admitted' => Step.ready,
      'waiting' => Step.waiting,
      'closed' => Step.closed,
      _ => Step.admission,
    };
    if (step == Step.ready && needsPhoto) step = Step.photo;
    if (step == Step.ready && freshSignup) step = Step.celebration;
  }

  /// Tenta pre-selecionar estado/cidade pela localizacao do aparelho (cidade mais
  /// proxima da lista fechada do IBGE). Silencioso: sem permissao, sem GPS ou
  /// qualquer falha, a pessoa so segue escolhendo manualmente, como sempre.
  /// `manual`: tocada pela pessoa (botao na tela), mostra motivo se nao der certo;
  /// a chamada automatica ao entrar na tela continua sem avisar nada.
  Future<void> tryAutoDetectLocation({bool manual = false}) async {
    if (selectedUf != null && selectedCity != null) return;
    if (manual && mounted) setState(() => detectingLocation = true);
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (manual && mounted) {
          setState(
            () => message =
                'Permissão de localização negada. Selecione manualmente ou '
                'permita o acesso à localização nos Ajustes do celular.',
          );
        }
        return;
      }
      if (!await Geolocator.isLocationServiceEnabled()) {
        if (manual && mounted) {
          setState(
            () => message =
                'Ative a localização do aparelho para preencher sozinho, ou '
                'selecione manualmente.',
          );
        }
        return;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: Duration(seconds: 6),
        ),
      );
      String? bestKey;
      var bestDist = double.infinity;
      for (final entry in brCityCoordinates.entries) {
        final dLat = entry.value.lat - position.latitude;
        final dLon = entry.value.lon - position.longitude;
        final dist = dLat * dLat + dLon * dLon;
        if (dist < bestDist) {
          bestDist = dist;
          bestKey = entry.key;
        }
      }
      if (bestKey == null || !mounted || selectedUf != null) return;
      final parts = bestKey.split('|');
      final coordinate = brCityCoordinates[bestKey]!;
      setState(() {
        selectedUf = parts[0];
        selectedCity = parts[1];
        selectedLat = coordinate.lat;
        selectedLon = coordinate.lon;
      });
    } on Object {
      // Sem permissao, localizacao desligada ou qualquer outra falha: segue so
      // com a escolha manual, sem mostrar erro quando automatico (e so uma
      // conveniencia); quando tocada pela pessoa, avisa que nao deu certo agora.
      if (manual && mounted) {
        setState(
          () => message = 'Não foi possível obter sua localização agora. Selecione manualmente.',
        );
      }
    } finally {
      if (manual && mounted) setState(() => detectingLocation = false);
    }
  }

  /// Uma vez, depois de entrar com "Manter conectado": oferece ligar a biometria.
  Future<void> offerBiometrics() async {
    if (!keepSignedIn || !(widget.gateway?.canRestore ?? false)) return;
    if (await BiometricPrefs.asked() || !await biometricGate.available()) {
      return;
    }
    await BiometricPrefs.setAsked();
    if (!mounted) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Entrar com biometria?'),
        content: const Text(
          'Nas próximas vezes, use o rosto ou a digital do aparelho em vez de digitar a senha. Você pode mudar isso em Configurações.',
        ),
        actions: [
          TextButton(
            key: const Key('biometric-later'),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Agora não'),
          ),
          FilledButton(
            key: const Key('biometric-yes'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Ativar'),
          ),
        ],
      ),
    );
    if (yes == true &&
        await biometricGate.authenticate('Confirme para ativar a biometria')) {
      await BiometricPrefs.setEnabled(true);
    }
  }

  void openHome() => Navigator.of(context).pushReplacement(
    MaterialPageRoute<void>(
      builder: (_) => RunPassHomeScreen(gateway: widget.gateway!),
    ),
  );

  static const _monthNames = [
    'Jan',
    'Fev',
    'Mar',
    'Abr',
    'Mai',
    'Jun',
    'Jul',
    'Ago',
    'Set',
    'Out',
    'Nov',
    'Dez',
  ];

  static int _daysInMonth(int year, int month) =>
      DateTime(year, month + 1, 0).day;

  /// Tres rolagens independentes (dia, mes e ano), igual ao Instagram: evita erro de
  /// formato, mas o servidor segue como a unica fonte confiavel da idade (contrato
  /// BetaAdmissionInput).
  Future<void> pickBirthDate() async {
    final now = DateTime.now();
    final initial = birthDate ?? DateTime(now.year - 13, now.month, now.day);
    var day = initial.day;
    var month = initial.month;
    var year = initial.year;
    final minYear = now.year - 100;
    final maxYear = now.year;

    final dayController = FixedExtentScrollController(initialItem: day - 1);
    final monthController = FixedExtentScrollController(initialItem: month - 1);
    final yearController = FixedExtentScrollController(
      initialItem: maxYear - year,
    );

    Widget wheelColumn({
      required String label,
      required FixedExtentScrollController controller,
      required int itemCount,
      required String Function(int index) text,
      required ValueChanged<int> onChanged,
    }) => Expanded(
      child: Column(
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              color: context.muted,
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: CupertinoPicker(
              scrollController: controller,
              itemExtent: 40,
              onSelectedItemChanged: onChanged,
              selectionOverlay: Container(
                decoration: BoxDecoration(
                  color: runPassOrange.withValues(alpha: .08),
                  border: const Border.symmetric(
                    horizontal: BorderSide(color: runPassOrange, width: 1.2),
                  ),
                ),
              ),
              children: List.generate(
                itemCount,
                (i) => Center(
                  child: Text(
                    text(i),
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w600,
                      color: context.isDark ? Colors.white : runPassNavy,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          void clampDay() {
            final maxDay = _daysInMonth(year, month);
            if (day > maxDay) {
              day = maxDay;
              dayController.jumpToItem(day - 1);
            }
          }

          return SafeArea(
            top: false,
            child: Container(
              decoration: BoxDecoration(
                color: Theme.of(sheetContext).scaffoldBackgroundColor,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
              ),
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: sheetContext.track,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Data de nascimento',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                            color: sheetContext.isDark
                                ? Colors.white
                                : runPassNavy,
                          ),
                        ),
                      ),
                      TextButton(
                        key: const Key('birth-date-done'),
                        onPressed: () => Navigator.pop(sheetContext, true),
                        child: const Text('Concluído'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  SizedBox(
                    height: 210,
                    child: Row(
                      children: [
                        wheelColumn(
                          label: 'Dia',
                          controller: dayController,
                          itemCount: _daysInMonth(year, month),
                          text: (i) => '${i + 1}'.padLeft(2, '0'),
                          onChanged: (i) => day = i + 1,
                        ),
                        wheelColumn(
                          label: 'Mês',
                          controller: monthController,
                          itemCount: 12,
                          text: (i) => _monthNames[i],
                          onChanged: (i) => setSheetState(() {
                            month = i + 1;
                            clampDay();
                          }),
                        ),
                        wheelColumn(
                          label: 'Ano',
                          controller: yearController,
                          itemCount: maxYear - minYear + 1,
                          text: (i) => '${maxYear - i}',
                          onChanged: (i) => setSheetState(() {
                            year = maxYear - i;
                            clampDay();
                          }),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    dayController.dispose();
    monthController.dispose();
    yearController.dispose();
    if (confirmed == true && mounted) {
      final chosen = DateTime(year, month, day);
      setState(() {
        birthDate = chosen.isAfter(now) ? now : chosen;
        message = null;
      });
    }
  }

  Future<void> choosePhoto() async {
    final choice = await askPhotoChoice(context);
    if (choice == null || !mounted) return;
    try {
      final bytes = await widget.photoPicker(context, choice);
      if (bytes != null && mounted) {
        setState(() {
          chosenPhoto = bytes;
          message = null;
        });
      }
    } on Exception catch (error) {
      if (mounted) setState(() => message = photoError(error));
    }
  }

  /// Ajusta o enquadramento da foto ja escolhida, sem pedir pra escolher de novo
  /// (abre direto o recorte na mesma imagem).
  Future<void> repositionChosenPhoto() async {
    final photo = chosenPhoto;
    if (photo == null) return;
    final cropped = await Navigator.of(context).push<List<int>>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) =>
            ProfilePhotoCropScreen(image: Uint8List.fromList(photo)),
      ),
    );
    if (cropped != null && mounted) {
      setState(() {
        chosenPhoto = cropped;
        message = null;
      });
    }
  }

  Future<void> resume() async {
    try {
      final profile = await widget.gateway!.request('/me');
      displayName = profile['displayName'] as String?;
      registrationCode = profile['registrationCode'] as String?;
      // Reabrir o app no meio do cadastro (depois do perfil criado, antes da
      // admissao) nao devia deixar esses campos em branco na ficha: a pessoa
      // acabava preenchendo "Nome e sobrenome" de novo so pra ver o usuario
      // reaparecer, e isso tentava CRIAR o perfil outra vez (ja existe),
      // dando "PROFILE_EXISTS". Repopula os dois a partir do servidor.
      if (displayName != null) name.text = displayName!;
      final savedUsername = profile['username'] as String?;
      if (savedUsername != null) username.text = savedUsername;
      // Ja tem usuario salvo: a sugestao automatica por nome nao deve mais mexer nele.
      usernameTouched = true;
      // Sem foto e com poucas edicoes no perfil: o cadastro provavelmente nao foi
      // concluido (so a criacao, mais talvez uma correcao de nome/usuario antes da
      // admissao ou o patch de localizacao, nunca mais que isso nesta fase). Quem
      // apagou a foto depois de usar o app por um tempo tem muito mais edicoes
      // acumuladas (posts, legendas, perfil etc) e nao cai aqui. Nao e um sinal
      // perfeito (um numero exato de edicoes concluidas nunca foi guardado), mas e
      // bem mais seguro do que exigir a versao 1 exata, que quebrava so de corrigir
      // o nome antes de terminar o cadastro.
      // Versao ausente na resposta (nao deveria acontecer num backend real, mas
      // alguns testes simulam respostas minimas): trata como "nao fresco", igual
      // ao comportamento anterior, em vez de arriscar mostrar a tela de foto a
      // toa pra quem ja usa o app ha tempo.
      needsPhoto =
          profile['photoReference'] == null &&
          (profile['version'] as int? ?? 999) <= 4;
      await status();
    } on IdentityIssue catch (error) {
      if (error.code == 'PROFILE_NOT_FOUND') {
        step = Step.profile;
      } else {
        rethrow;
      }
    }
  }

  Future<void> perform(
    Future<void> Function() action, {
    bool validate = false,
  }) async {
    if (busy || (validate && !(form.currentState?.validate() ?? false))) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await action();
    } on IdentityIssue catch (error) {
      if (error.code == 'UserNotConfirmedException') step = Step.confirm;
      if (error.code == 'INVALID_TOKEN' ||
          error.code == 'ACCOUNT_UNAVAILABLE') {
        step = Step.signIn;
      }
      message = switch (error.code) {
        'NotAuthorizedException' ||
        'INVALID_TOKEN' => 'Entre novamente e confira seu e-mail e senha.',
        'UserNotConfirmedException' =>
          'Confirme seu e-mail com o código recebido.',
        'UsernameExistsException' =>
          'Já existe uma conta com esse e-mail. Entre ou recupere sua senha.',
        'USERNAME_TAKEN' => 'Esse nome de usuário já está em uso.',
        'InvalidPasswordException' =>
          'Use pelo menos $minimumPasswordLength caracteres.',
        'CodeMismatchException' || 'ExpiredCodeException' =>
          'Confira o código recebido ou solicite outro.',
        'NOT_ELIGIBLE' => 'O app é para pessoas com 13 anos completos ou mais.',
        'BETA_FULL' => 'As vagas para novos usuários foram preenchidas. Você pode entrar na lista de espera.',
        'BETA_CLOSED' => 'As entradas de novos usuários foram encerradas.',
        'EMAIL_NOT_VERIFIED' =>
          'Confirme seu e-mail antes de continuar (saia e entre de novo).',
        'ADMISSION_INTEGRITY_FAILURE' ||
        'CAPACITY_AVAILABLE' ||
        'CONCURRENT_RETRY_REQUIRED' =>
          'Instabilidade momentânea do servidor. Toque em Continuar de novo.',
        'IMAGE_TYPE_INVALID' ||
        'IMAGE_NOT_VALID' ||
        'IMAGE_SIZE_INVALID' ||
        'UPLOAD_UNAVAILABLE' => photoError(error),
        'ACCOUNT_UNAVAILABLE' => 'Esta conta está indisponível.',
        'INVALID_INPUT' => 'Confira os campos e tente novamente.',
        // Codigo exposto de proposito enquanto o app esta em teste DEV: sem isso,
        // qualquer erro novo e inteiramente mudo sobre a causa, so "tente de novo".
        _ =>
          'Não foi possível concluir agora (código ${error.code}). Seus dados continuam nesta tela; tente novamente em instantes.',
      };
      if (error.code == 'BETA_FULL') full = true;
    } on Exception {
      message = 'Não foi possível conectar. Tente novamente.';
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
        });
      }
    }
    // Quem entrou (ou terminou o cadastro) vai direto para o app, sem tela intermediaria.
    if (mounted && step == Step.ready && (widget.gateway?.signedIn ?? false)) {
      await offerBiometrics();
      if (mounted) openHome();
    }
  }

  /// Corrige um campo da ficha editado a partir da celebracao (conta ja admitida, so
  /// PATCH /me) e volta para a celebracao, em vez de seguir a jornada de cadastro.
  Future<void> editProfile(
    IdentityGateway gateway,
    Map<String, dynamic> changes,
  ) async {
    final current = await gateway.request('/me');
    final profile = await gateway.request(
      '/me',
      method: 'PATCH',
      body: {'expectedVersion': current['version'], ...changes},
    );
    displayName = profile['displayName'] as String? ?? displayName;
    editingFromCelebration = false;
    step = Step.celebration;
  }

  Future<void> submit() => perform(() async {
    final gateway = widget.gateway!;
    switch (step) {
      case Step.signIn:
        await gateway.signIn(
          email.text.trim(),
          password.text,
          keepSignedIn: keepSignedIn,
        );
        password.clear();
        await SavedAccount.save(email.text.trim());
        await resume();
      case Step.signUp:
        await gateway.signUp(email.text.trim());
        step = Step.confirm;
      case Step.confirm:
        await gateway.confirm(email.text.trim(), code.text.trim());
        code.clear();
        step = Step.setPassword;
      case Step.setPassword:
        final weakReason = weakPasswordReason(password.text, email.text.trim());
        if (weakReason != null) {
          message = weakReason;
          return;
        }
        await gateway.setPassword(email.text.trim(), password.text);
        password.clear();
        showPasswordSetPassword = false;
        await resume();
      case Step.forgot:
        await gateway.forgot(email.text.trim());
        step = Step.reset;
      case Step.reset:
        final weakResetReason = weakPasswordReason(
          password.text,
          email.text.trim(),
        );
        if (weakResetReason != null) {
          message = weakResetReason;
          return;
        }
        await gateway.reset(email.text.trim(), code.text.trim(), password.text);
        password.clear();
        code.clear();
        step = Step.signIn;
        message = 'Senha atualizada. Entre na sua conta.';
      case Step.profile:
        if (editingFromCelebration) {
          await editProfile(gateway, {
            'displayName': name.text.trim(),
            'username': username.text.trim(),
          });
          return;
        }
        var usernameToSend = username.text.trim();
        Map<String, dynamic> profile;
        // So true quando este PUT de fato criou o perfil agora (version==1 de
        // verdade); falso quando caiu no PROFILE_EXISTS abaixo (so corrigindo
        // nome/usuario de um perfil que ja existia). So nesse primeiro caso da
        // pra confiar na versao pra saber se a foto ainda nao foi decidida —
        // corrigir nome/usuario por si so nunca decide nada sobre foto.
        var justCreated = false;
        var attempt = 0;
        while (true) {
          try {
            profile = await gateway.request(
              '/me',
              method: 'PUT',
              body: {
                'displayName': name.text.trim(),
                'username': usernameToSend,
              },
            );
            justCreated = true;
            break;
          } on IdentityIssue catch (error) {
            // So quando o usuario foi sugerido automaticamente (a pessoa nunca mexeu
            // nele): tenta garantir que fique unico sozinha, em vez de so devolver o
            // erro e deixar a pessoa escolher outro na mao.
            if (error.code == 'USERNAME_TAKEN' &&
                !usernameTouched &&
                attempt < 5) {
              attempt += 1;
              final base = suggestUsername(name.text);
              final trimmedBase = base.length > 17
                  ? base.substring(0, 17)
                  : base;
              usernameToSend = '$trimmedBase${100 + Random().nextInt(900)}';
              continue;
            }
            // O perfil ja existe (cadastro retomado apos reabrir o app, ou a pessoa
            // voltou pra corrigir nome/usuario depois de ja ter enviado uma vez):
            // PATCH /me permite corrigir so esses dois campos antes da admissao
            // (decisao de produto de 21/11/2026), entao corrige de verdade em vez
            // de so mostrar um aviso.
            if (error.code == 'PROFILE_EXISTS') {
              final current = await gateway.request('/me');
              profile = await gateway.request(
                '/me',
                method: 'PATCH',
                body: {
                  'expectedVersion': current['version'],
                  'displayName': name.text.trim(),
                  'username': usernameToSend,
                },
              );
              break;
            }
            rethrow;
          }
        }
        username.text = usernameToSend;
        displayName = profile['displayName'] as String?;
        registrationCode = profile['registrationCode'] as String?;
        // So recalcula a partir da versao quando o perfil acabou de ser criado
        // agora mesmo (version==1 de verdade); corrigir nome/usuario de um
        // perfil ja existente (PROFILE_EXISTS acima) nunca mexeu na foto, entao
        // mantem o que ja estava certo antes, em vez de reavaliar com uma
        // versao que so subiu por causa dessa correcao.
        if (justCreated) {
          needsPhoto =
              profile['photoReference'] == null && profile['version'] == 1;
        }
        freshSignup = true;
        step = Step.admission;
      case Step.admission:
        if (gender == null) {
          message = 'Selecione seu gênero.';
          return;
        }
        final birth = birthDate;
        if (birth == null) {
          message = 'Selecione sua data de nascimento.';
          return;
        }
        if (!adult) {
          message = 'Confirme que tem 13 anos completos ou mais.';
          return;
        }
        if (editingFromCelebration) {
          await editProfile(gateway, {
            'birthDate': isoBirthDate(birth),
            'gender': gender,
          });
          return;
        }
        final admissionBody = {
          'birthDate': isoBirthDate(birth),
          'declaresAdult': adult,
          'gender': gender,
        };
        try {
          await gateway.request(
            full ? '/beta/waitlist' : '/beta/admissions',
            method: 'POST',
            body: admissionBody,
          );
        } on IdentityIssue catch (error) {
          // A admissao pode ja ter sido concluida no servidor numa tentativa anterior
          // (por exemplo, se a chamada seguinte falhou por instabilidade de rede antes
          // de avancar a tela): nao trata como erro, so segue, senao a pessoa fica
          // presa aqui para sempre (toda nova tentativa recusada do mesmo jeito).
          if (error.code == 'ALREADY_ADMITTED') {
            // segue.
          } else if (error.code == 'INVALID_INPUT') {
            // Diagnostico temporario (fase de teste DEV): o servidor nao registra o
            // corpo por privacidade (pode conter data de nascimento), entao mostra
            // aqui o que foi enviado para achar a causa raiz de verdade.
            message =
                'Não foi possível concluir agora (código INVALID_INPUT). '
                'Rota: ${full ? '/beta/waitlist' : '/beta/admissions'}. '
                'Dados enviados: ${jsonEncode(admissionBody)}';
            return;
          } else {
            rethrow;
          }
        }
        // O codigo de inscricao so existe a partir da admissao (sorteado no servidor);
        // GET /me e a unica rota que devolve o campo (PUT/PATCH nao), entao busca aqui
        // para a ficha parar de mostrar "00000" dali em diante. So uma conveniencia:
        // se falhar, resume() pega o codigo normalmente na proxima vez, sem travar
        // o avanco do cadastro por causa disso.
        if (!full) {
          try {
            final admitted = await gateway.request('/me');
            registrationCode = admitted['registrationCode'] as String?;
          } on Object {
            // Ignora: ver comentario acima.
          }
        }
        step = Step.location;
        unawaited(tryAutoDetectLocation());
      case Step.location:
        if (selectedUf == null || selectedCity == null) {
          message = 'Selecione seu estado e cidade.';
          return;
        }
        if (editingFromCelebration) {
          locationSynced = true;
          await editProfile(
            gateway,
            brLocationPatch(
              selectedUf!,
              selectedCity!,
              selectedLat,
              selectedLon,
            ),
          );
          return;
        }
        // So fica guardado aqui; o envio ao servidor espera a admissao (ver status()).
        await status();
      case Step.photo:
        final photo = chosenPhoto;
        if (photo != null) {
          final reference = await uploadProfilePhoto(gateway, photo);
          final current = await gateway.request('/me');
          await gateway.request(
            '/me',
            method: 'PATCH',
            body: {
              'expectedVersion': current['version'],
              'photoReference': reference,
            },
          );
        }
        needsPhoto = false;
        // Nao limpa chosenPhoto aqui: a ficha da celebracao reaproveita o mesmo
        // bytes para mostrar a foto escolhida (sumia antes, por causa disso).
        step = freshSignup ? Step.celebration : Step.ready;
      case Step.ready || Step.waiting || Step.closed || Step.celebration:
        break;
    }
  }, validate: true);

  Widget field(
    TextEditingController controller,
    String label, {
    bool secret = false,
    int? maxLength,
    String? Function(String)? check,
    Widget? suffixIcon,
    String? prefixText,
    FocusNode? focusNode,
    ValueChanged<String>? onChanged,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextFormField(
      controller: controller,
      focusNode: focusNode,
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: suffixIcon,
        prefixText: prefixText,
      ),
      obscureText: secret,
      autocorrect: !secret,
      enableSuggestions: !secret,
      keyboardType: controller == email
          ? TextInputType.emailAddress
          : TextInputType.text,
      maxLength: maxLength,
      onChanged: onChanged,
      validator: (value) {
        if (value == null || value.trim().isEmpty) {
          return 'Preencha este campo.';
        }
        return check?.call(value);
      },
    ),
  );

  static const _signupSteps = [
    Step.profile,
    Step.admission,
    Step.location,
    Step.photo,
  ];

  static Step _previousSignupStep(Step step) => switch (step) {
    Step.admission => Step.profile,
    Step.location => Step.admission,
    Step.photo => Step.location,
    _ => Step.profile,
  };

  Widget genderButton(
    BuildContext context,
    String value,
    String label, {
    bool fullWidth = false,
  }) {
    final selected = gender == value;
    final button = OutlinedButton(
      onPressed: busy ? null : () => setState(() => gender = value),
      style: OutlinedButton.styleFrom(
        backgroundColor: selected ? context.softFill : context.panel,
        side: BorderSide(
          color: selected ? runPassOrange : Colors.transparent,
          width: 1.5,
        ),
        foregroundColor: selected
            ? runPassOrange
            : (context.isDark ? Colors.white : runPassNavy),
        // Pilula, mesma altura nas tres opcoes: igual ao prototipo, menor e uniforme.
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        shape: const StadiumBorder(),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
      ),
    );
    return fullWidth ? SizedBox(width: double.infinity, child: button) : button;
  }

  Widget celebrationView(BuildContext context) {
    final trimmedDisplay = (displayName ?? '').trim();
    final firstName = trimmedDisplay.isEmpty
        ? null
        : trimmedDisplay.split(RegExp(r'\s+')).first;
    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [runPassOrange, runPassGold],
        ),
      ),
      // Conteudo centralizado na tela toda (nao so no alto, com sobra embaixo):
      // o LayoutBuilder da a altura real disponivel para o ConstrainedBox exigir
      // pelo menos essa altura, e o Center usa a sobra pra centralizar; telas
      // mais altas que o conteudo deixam de ter espaco morto, e ainda rola se
      // precisar (telas baixas). O botao "Começar minha jornada" fica perto do
      // rodape por um espaco fixo generoso antes dele (nao por Spacer: um Spacer
      // aqui dá erro de altura indefinida dentro do SingleChildScrollView).
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 16),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight - 48),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RegistrationCard(
                      displayName: displayName,
                      username: username.text.trim().isEmpty
                          ? null
                          : username.text.trim(),
                      cityLabel: selectedUf == null || selectedCity == null
                          ? null
                          : '$selectedCity, $selectedUf',
                      birthDate: birthDate,
                      gender: gender,
                      registrationCode: registrationCode,
                      photo: chosenPhoto == null
                          ? null
                          : Uint8List.fromList(chosenPhoto!),
                      inscriptionDate: DateTime.now(),
                      onTapPhoto: () => setState(() => step = Step.photo),
                      onTapProfile: () => setState(() {
                        // Ja tem usuario definido: a sugestao automatica por nome e so para
                        // quem ainda nao escolheu um, no cadastro original.
                        usernameTouched = true;
                        editingFromCelebration = true;
                        step = Step.profile;
                      }),
                      onTapBirth: () => setState(() {
                        editingFromCelebration = true;
                        step = Step.admission;
                      }),
                      onTapCity: () => setState(() {
                        editingFromCelebration = true;
                        step = Step.location;
                      }),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Toque em qualquer valor da ficha para alterar.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        color: runPassNavy.withValues(alpha: .6),
                      ),
                    ),
                    const SizedBox(height: 22),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: .18),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Image(
                            image: AssetImage('assets/icons/verificado.png'),
                            width: 14,
                            height: 14,
                          ),
                          SizedBox(width: 6),
                          Text(
                            'INSCRIÇÃO CONFIRMADA',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              fontSize: 10.5,
                              letterSpacing: .6,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      firstName == null
                          ? 'Bem-vindo!'
                          : 'Bem-vindo\n$firstName!',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        height: 1.25,
                        color: runPassNavy,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'A partir de agora, cada corrida que você registrar entra no seu Pódio de medalhas e vira parte da sua história.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13.5,
                        color: runPassNavy.withValues(alpha: .75),
                      ),
                    ),
                    // Espaco fixo generoso antes do botao: deixa "Começar minha
                    // jornada" perto do rodape, mesma orientacao do "Continuar" das
                    // telas de cadastro.
                    const SizedBox(height: 72),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: runPassNavy,
                        minimumSize: const Size.fromHeight(54),
                      ),
                      onPressed: openHome,
                      child: const Text('Começar minha jornada'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final gateway = widget.gateway;
    if (gateway != null && !restoring) {
      if (step == Step.celebration) {
        return Scaffold(body: SafeArea(child: celebrationView(context)));
      }
      if (_signupSteps.contains(step)) {
        return _signupScaffold(context, gateway);
      }
    }
    return _authScaffold(context, gateway);
  }

  /// Entrar/criar conta, confirmar e-mail/senha, lista de espera/fechado: tela com
  /// rolagem unica, igual a antes da reformulacao do cadastro.
  Widget _authScaffold(BuildContext context, IdentityGateway? gateway) {
    final initial = [
      Step.signIn,
      Step.signUp,
      Step.confirm,
      Step.setPassword,
      Step.forgot,
      Step.reset,
    ].contains(step);
    final title = switch (step) {
      Step.signIn => 'Entre no +1Pódio',
      Step.signUp => 'Crie sua conta',
      Step.confirm => 'Confirme seu e-mail',
      Step.setPassword => 'Crie sua senha',
      Step.forgot => 'Recupere sua senha',
      Step.reset => 'Defina uma nova senha',
      Step.ready => 'Entrando, ${displayName ?? 'corredor'}…',
      Step.waiting => 'Você está na lista de espera',
      Step.closed => 'As entradas de novos usuários foram encerradas',
      _ => '',
    };
    return Scaffold(
      appBar: AppBar(title: const RunPassWordmark(compact: true)),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: gateway == null
                  ? const Text(
                      'O +1Pódio ainda não está disponível neste ambiente.',
                    )
                  : restoring
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 80),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : Form(
                      key: form,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (step == Step.signIn || step == Step.signUp)
                            Container(
                              padding: const EdgeInsets.all(20),
                              decoration: BoxDecoration(
                                color: runPassNavy,
                                borderRadius: BorderRadius.circular(24),
                              ),
                              child: const Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(
                                    Icons.emoji_events_rounded,
                                    color: Color(0xffffc144),
                                    size: 32,
                                  ),
                                  SizedBox(height: 18),
                                  // Cada frase em uma linha, por FittedBox: nunca quebra
                                  // no meio em telas estreitas (encolhe em vez de quebrar).
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      'Mais que corridas.',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w800,
                                        fontSize: 20,
                                        height: 1.15,
                                      ),
                                    ),
                                  ),
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      'São histórias para sempre.',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w800,
                                        fontSize: 20,
                                        height: 1.15,
                                      ),
                                    ),
                                  ),
                                  SizedBox(height: 10),
                                  Text(
                                    'Crie sua conta e comece a montar \nseu Pódio de Medalhas e vitórias!',
                                    style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: 14.5,
                                      height: 1.3,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          if (step == Step.signIn || step == Step.signUp)
                            const SizedBox(height: 24),
                          // Tela de entrada mais limpa e leve: sem titulo, so os campos
                          // (decisao de produto de 21/11/2026).
                          if (step != Step.signIn) ...[
                            Text(
                              title,
                              style: Theme.of(context).textTheme.headlineSmall
                                  ?.copyWith(
                                    fontWeight: FontWeight.w800,
                                    color: context.isDark
                                        ? Colors.white
                                        : runPassNavy,
                                  ),
                            ),
                            const SizedBox(height: 24),
                          ],
                          if (initial) field(email, 'E-mail'),
                          if ([
                            Step.signIn,
                            Step.setPassword,
                            Step.reset,
                          ].contains(step))
                            field(
                              password,
                              step == Step.setPassword
                                  ? 'Crie uma senha'
                                  : 'Senha',
                              // Sem campo de confirmacao: o olho mostra/oculta a senha digitada.
                              // Cada tela tem seu proprio estado de visibilidade.
                              secret: step == Step.setPassword
                                  ? !showPasswordSetPassword
                                  : step == Step.signIn
                                  ? !showPasswordSignIn
                                  : true,
                              suffixIcon:
                                  step == Step.setPassword ||
                                      step == Step.signIn
                                  ? IconButton(
                                      icon: Icon(
                                        (step == Step.setPassword
                                                ? showPasswordSetPassword
                                                : showPasswordSignIn)
                                            ? Icons.visibility_off
                                            : Icons.visibility,
                                      ),
                                      onPressed: () => setState(() {
                                        if (step == Step.setPassword) {
                                          showPasswordSetPassword =
                                              !showPasswordSetPassword;
                                        } else {
                                          showPasswordSignIn =
                                              !showPasswordSignIn;
                                        }
                                      }),
                                    )
                                  : null,
                            ),
                          if ([Step.confirm, Step.reset].contains(step))
                            field(code, 'Código recebido'),
                          if (step == Step.ready)
                            const Center(child: CircularProgressIndicator()),
                          if (message != null)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: Text(
                                message!,
                                semanticsLabel: message,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ),
                          if (![
                            Step.ready,
                            Step.waiting,
                            Step.closed,
                          ].contains(step))
                            FilledButton(
                              onPressed: busy ? null : submit,
                              child: Text(
                                busy
                                    ? 'Aguarde…'
                                    : step == Step.signIn
                                    ? 'Entrar'
                                    : 'Continuar',
                              ),
                            ),
                          if (step == Step.signIn)
                            TextButton(
                              onPressed: busy
                                  ? null
                                  : () => change(Step.forgot),
                              child: const Text('Esqueceu a senha?'),
                            ),
                          if (step == Step.signIn &&
                              (biometricLocked || (faceReady && emailIsSaved)))
                            OutlinedButton.icon(
                              key: const Key('biometric-retry'),
                              onPressed: busy ? null : restoreSession,
                              icon: const Icon(Icons.fingerprint),
                              label: const Text('Entrar com biometria'),
                            ),
                          if (step == Step.signIn) ...[
                            // Espacamento maior: "Criar conta" e uma acao secundaria, bem
                            // separada do fluxo de entrar.
                            const SizedBox(height: 32),
                            OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size.fromHeight(52),
                                side: const BorderSide(
                                  color: runPassOrange,
                                  width: 1.5,
                                ),
                                foregroundColor: runPassOrange,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(15),
                                ),
                              ),
                              onPressed: busy
                                  ? null
                                  : () => change(Step.signUp),
                              child: const Text('Criar conta'),
                            ),
                          ],
                          if (step == Step.confirm)
                            TextButton(
                              onPressed: busy
                                  ? null
                                  : () => perform(() async {
                                      await gateway.resendConfirmation(
                                        email.text.trim(),
                                      );
                                      message = 'Novo código solicitado.';
                                    }),
                              child: const Text('Reenviar código'),
                            ),
                          if (step == Step.waiting)
                            TextButton(
                              onPressed: busy
                                  ? null
                                  : () => perform(() async {
                                      await gateway.request(
                                        '/me/waitlist',
                                        method: 'DELETE',
                                      );
                                      await status();
                                    }),
                              child: const Text('Sair da lista de espera'),
                            ),
                          if (gateway.signedIn &&
                              (step == Step.waiting || step == Step.closed))
                            TextButton(
                              onPressed: busy
                                  ? null
                                  : () => perform(() async {
                                      try {
                                        await gateway.signOut();
                                      } finally {
                                        step = Step.signIn;
                                      }
                                    }),
                              child: const Text('Sair'),
                            ),
                          if (initial && step != Step.signIn)
                            TextButton(
                              onPressed: busy
                                  ? null
                                  : () => change(Step.signIn),
                              child: const Text('Voltar'),
                            ),
                        ],
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  /// Nome/usuario, genero/nascimento, cidade e foto: cabecalho (voltar, progresso,
  /// titulo e ficha) fixo no topo; so o conteudo proprio de cada passo rola, para o
  /// cabecalho nunca se mexer e a tela caber sem rolagem sempre que possivel.
  Widget _signupScaffold(BuildContext context, IdentityGateway gateway) {
    final title = switch (step) {
      Step.profile => 'Como você quer ser chamado?',
      Step.admission =>
        full ? 'Lista de espera' : 'Em qual categoria você corre?',
      Step.location => 'Qual a sua cidade?',
      Step.photo => 'Sua foto de perfil',
      _ => '',
    };
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              // Recuo do topo e mais distancia embaixo: o cabecalho ficava no limite
              // da tela, e o botao "Continuar" quase colado na borda inferior.
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
              child: Form(
                key: form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(right: 14),
                          // Espaco sempre reservado (visivel ou nao): sem isso, a linha do
                          // topo fica mais baixa so no passo do perfil (sem seta de voltar),
                          // e a ficha de inscricao muda de altura entre as telas.
                          child:
                              (step != Step.profile || editingFromCelebration)
                              ? InkWell(
                                  key: const Key('signup-back'),
                                  onTap: busy
                                      ? null
                                      : () => setState(() {
                                          if (editingFromCelebration) {
                                            editingFromCelebration = false;
                                            step = Step.celebration;
                                          } else {
                                            step = _previousSignupStep(step);
                                          }
                                        }),
                                  customBorder: const CircleBorder(),
                                  child: Container(
                                    width: 40,
                                    height: 40,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Theme.of(context).cardColor,
                                      border: Border.all(
                                        color: context.panelStrong,
                                      ),
                                    ),
                                    child: Icon(
                                      Icons.arrow_back,
                                      size: 18,
                                      color: context.isDark
                                          ? Colors.white
                                          : runPassNavy,
                                    ),
                                  ),
                                )
                              : const SizedBox(width: 40, height: 40),
                        ),
                        Expanded(
                          child: RegistrationProgress(
                            step: _signupSteps.indexOf(step) + 1,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'SUA FICHA DE INSCRIÇÃO',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1,
                        color: runPassOrange,
                      ),
                    ),
                    const SizedBox(height: 4),
                    // Altura fixa pro titulo (2 linhas): alguns titulos quebram em duas
                    // linhas em telas estreitas e outros nao, o que mudava a altura do
                    // cabecalho e empurrava a ficha de inscricao pra uma posicao diferente
                    // em cada tela do cadastro.
                    SizedBox(
                      height: 52,
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style:
                              const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 21,
                                color: runPassNavy,
                              ).copyWith(
                                color: context.isDark ? Colors.white : null,
                              ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    RegistrationCard(
                      displayName: name.text.trim().isEmpty
                          ? displayName
                          : name.text.trim(),
                      username: username.text.trim().isEmpty
                          ? null
                          : username.text.trim(),
                      cityLabel: selectedUf == null || selectedCity == null
                          ? null
                          : '$selectedCity, $selectedUf',
                      birthDate: birthDate,
                      gender: gender,
                      registrationCode: registrationCode,
                      photo: chosenPhoto == null
                          ? null
                          : Uint8List.fromList(chosenPhoto!),
                      inscriptionDate: DateTime.now(),
                    ),
                    // Distancia uniforme da ficha em todas as telas do cadastro: antes so
                    // o perfil tinha folga extra, e as outras (genero/nascimento,
                    // localizacao) ficavam coladas na ficha.
                    const SizedBox(height: 18),
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (step == Step.profile) ...[
                              // Rotulo sempre visivel (floatingLabelBehavior.always) deixa o
                              // campo com texto logo no topo; um pouco mais de distancia
                              // evita a sensacao de que o campo esta colado na ficha.
                              const SizedBox(height: 10),
                              field(
                                name,
                                'Nome e sobrenome',
                                maxLength: 30,
                                focusNode: nameFocus,
                              ),
                              field(
                                username,
                                'Nome de usuário',
                                maxLength: 20,
                                prefixText: '@',
                                focusNode: usernameFocus,
                                // onChanged tambem dispara quando a sugestao automatica escreve
                                // aqui (mudanca no controller, nao so digitacao); so conta como
                                // "mexeu por conta propria" se o campo estiver com foco.
                                onChanged: (_) {
                                  if (usernameFocus.hasFocus) {
                                    usernameTouched = true;
                                  }
                                },
                                // Mensagens curtas, que cabem em uma linha: a anterior era cortada no fim.
                                check: (value) =>
                                    RegExp(r'^[A-Za-z0-9_]{3,30}$')
                                        .hasMatch(value)
                                    ? null
                                    : value.trim().length < 3
                                    ? 'Use pelo menos 3 caracteres.'
                                    : 'Só letras sem acento, números e _.',
                              ),
                            ],
                            if (step == Step.location) ...[
                              Text(
                                'Ajuda a conectar você com corredores perto.',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: context.muted,
                                ),
                              ),
                              const SizedBox(height: 12),
                              InkWell(
                                key: const Key('location-field'),
                                onTap: busy
                                    ? null
                                    : () async {
                                        final picked = await pickBrLocation(
                                          context,
                                          initialUf: selectedUf,
                                          initialCity: selectedCity,
                                        );
                                        if (picked != null && mounted) {
                                          setState(() {
                                            selectedUf = picked.$1;
                                            selectedCity = picked.$2;
                                            selectedLat = picked.$3;
                                            selectedLon = picked.$4;
                                            message = null;
                                          });
                                        }
                                      },
                                child: InputDecorator(
                                  decoration: InputDecoration(
                                    labelText: 'Estado e cidade',
                                    // Repete a tentativa automatica, se ela nao tiver dado
                                    // certo (sem permissao ainda, GPS tardio etc).
                                    suffixIcon:
                                        selectedUf == null &&
                                            selectedCity == null
                                        ? IconButton(
                                            key: const Key('use-my-location'),
                                            tooltip: 'Usar minha localização',
                                            icon: detectingLocation
                                                ? const SizedBox(
                                                    width: 18,
                                                    height: 18,
                                                    child:
                                                        CircularProgressIndicator(
                                                          strokeWidth: 2,
                                                        ),
                                                  )
                                                : const Icon(Icons.my_location),
                                            onPressed: busy || detectingLocation
                                                ? null
                                                : () => tryAutoDetectLocation(
                                                    manual: true,
                                                  ),
                                          )
                                        : null,
                                  ),
                                  child: Text(
                                    selectedUf == null || selectedCity == null
                                        ? 'Selecionar estado e cidade'
                                        : '$selectedUf - $selectedCity',
                                  ),
                                ),
                              ),
                            ],
                            if (step == Step.admission) ...[
                              if (full)
                                const Text(
                                  'A lista de espera não garante vaga ou posição.',
                                ),
                              Padding(
                                // Mesmo recuo da esquerda do rotulo flutuante do campo
                                // "Data de nascimento" logo abaixo, pra ficar alinhado.
                                padding: const EdgeInsets.only(left: 12),
                                child: Text(
                                  'Gênero',
                                  style: TextStyle(
                                    color: context.muted,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Expanded(
                                    child: genderButton(
                                      context,
                                      'female',
                                      'Feminino',
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: genderButton(
                                      context,
                                      'male',
                                      'Masculino',
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              genderButton(
                                context,
                                'undisclosed',
                                'Prefiro não me identificar',
                                fullWidth: true,
                              ),
                              // Espaco visivel entre o bloco de genero e a data de
                              // nascimento: antes ficavam colados.
                              const SizedBox(height: 26),
                              Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: InkWell(
                                  key: const Key('birth-date-field'),
                                  onTap: busy ? null : pickBirthDate,
                                  child: InputDecorator(
                                    decoration: const InputDecoration(
                                      labelText: 'Data de nascimento',
                                    ),
                                    child: birthDate == null
                                        ? Text(
                                            'DD/MM/AAAA',
                                            style: TextStyle(
                                              fontSize: 13,
                                              color: context.muted,
                                            ),
                                          )
                                        : Text(formatBirthDate(birthDate!)),
                                  ),
                                ),
                              ),
                              CheckboxListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                minVerticalPadding: 0,
                                visualDensity: VisualDensity.compact,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                value: adult,
                                onChanged: busy
                                    ? null
                                    : (value) => setState(
                                        () => adult = value ?? false,
                                      ),
                                title: Text(
                                  'Declaro ter 13 anos completos ou mais.',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color: context.isDark
                                        ? Colors.white
                                        : runPassNavy,
                                  ),
                                ),
                              ),
                            ],
                            if (step == Step.photo) ...[
                              Text(
                                'Para seus amigos reconhecerem você. Você pode pular e adicionar depois, no perfil.',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: context.muted,
                                ),
                              ),
                              // A fita do MedalAvatar (redesenhada em tons neutros) pinta
                              // acima do proprio circulo, fora da caixa (Clip.none, de
                              // proposito, pra nao cortar a fita); esse espaco evita que
                              // ela sobreponha o texto acima, com uma distancia mais
                              // harmonica do que o minimo necessario.
                              const SizedBox(height: 56),
                              Center(
                                child: InkWell(
                                  key: const Key('choose-photo'),
                                  customBorder: const CircleBorder(),
                                  // Com foto ja escolhida, tocar reajusta o enquadramento dela;
                                  // sem foto, abre a escolha (camera/galeria/web).
                                  onTap: busy
                                      ? null
                                      : (chosenPhoto == null
                                            ? choosePhoto
                                            : repositionChosenPhoto),
                                  child: MedalAvatar(
                                    radius: 56,
                                    child: CircleAvatar(
                                      radius: MedalAvatar.innerRadius(56),
                                      backgroundColor: context.softFill,
                                      backgroundImage: chosenPhoto == null
                                          ? null
                                          : MemoryImage(
                                              Uint8List.fromList(chosenPhoto!),
                                            ),
                                      child: chosenPhoto == null
                                          ? const Icon(
                                              Icons.add_a_photo_outlined,
                                              size: 32,
                                              color: runPassOrange,
                                            )
                                          : null,
                                    ),
                                  ),
                                ),
                              ),
                              TextButton(
                                onPressed: busy ? null : choosePhoto,
                                child: Text(
                                  chosenPhoto == null
                                      ? 'Escolher foto'
                                      : 'Trocar foto',
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    if (message != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          message!,
                          semanticsLabel: message,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: FilledButton(
                        onPressed: busy ? null : submit,
                        child: Text(
                          busy
                              ? 'Aguarde…'
                              : step == Step.admission &&
                                    full &&
                                    !editingFromCelebration
                              ? 'Entrar na lista de espera'
                              : step == Step.photo && chosenPhoto == null
                              ? 'Pular por enquanto'
                              : 'Continuar',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

const _accentedChars =
    'áàâãäåāăąèéêëēĕėęěìíîïĩīĭįòóôõöøōŏőùúûüũūŭůűçñÁÀÂÃÄÅĀĂĄÈÉÊËĒĔĖĘĚÌÍÎÏĨĪĬĮÒÓÔÕÖØŌŎŐÙÚÛÜŨŪŬŮŰÇÑ';
const _plainChars =
    'aaaaaaaaaeeeeeeeeiiiiiiiiooooooooouuuuuuuuucnAAAAAAAAAEEEEEEEEIIIIIIIIOOOOOOOOOUUUUUUUUUCN';

/// Sugestao de nome de usuario a partir do "Nome e Sobrenome": sem acento, minusculo,
/// palavras separadas por "_", so letras/numeros/"_" (mesma regra do campo), 3-30
/// caracteres. So uma sugestao de partida; a pessoa pode mudar livremente.
String suggestUsername(String displayName) {
  final buffer = StringBuffer();
  for (final char in displayName.trim().toLowerCase().split('')) {
    final accentIndex = _accentedChars.indexOf(char);
    buffer.write(accentIndex >= 0 ? _plainChars[accentIndex] : char);
  }
  final slug = buffer
      .toString()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .join('_')
      .replaceAll(RegExp(r'[^a-z0-9_]'), '');
  return slug.length > 20 ? slug.substring(0, 20) : slug;
}

String isoBirthDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

String formatBirthDate(DateTime date) =>
    '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
