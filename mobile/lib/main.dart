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
import 'safety.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ThemeController.load();
  const api = String.fromEnvironment('RUNPASS_API_URL');
  const cognito = String.fromEnvironment('RUNPASS_COGNITO_URL');
  const client = String.fromEnvironment('RUNPASS_COGNITO_CLIENT_ID');
  // Opcional: so DEV tem Hosted UI/login social configurado ate agora (S11).
  // Sem esse define, os botoes de Google/Facebook ficam escondidos (ver IdentityScreen).
  const hostedUiDomain = String.fromEnvironment(
    'RUNPASS_COGNITO_HOSTED_UI_DOMAIN',
  );
  IdentityGateway? gateway;
  if (api.isNotEmpty && cognito.isNotEmpty && client.isNotEmpty) {
    try {
      gateway = IdentityGateway(
        api: Uri.parse(api),
        cognito: Uri.parse(cognito),
        clientId: client,
        tokenStore: SecureTokenStore(),
        hostedUiDomain: hostedUiDomain.isEmpty
            ? null
            : Uri.parse(hostedUiDomain),
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
  // true so depois que a pessoa toca em "Continuar" na tela "Qual a sua
  // cidade?" nesta sessao — e a UNICA coisa que autoriza `status()` a enviar
  // a localizacao ao servidor. `selectedUf`/`selectedCity` sozinhos NAO
  // bastam: eles tambem ficam preenchidos por um rascunho local restaurado
  // ou pela deteccao automatica por GPS, nenhum dos dois e uma confirmacao
  // de verdade da pessoa.
  bool locationConfirmed = false;
  // So para o botao manual de localizacao mostrar um indicador de carregamento.
  bool detectingLocation = false;
  String? message;
  String? displayName;
  // Cadastro novo ainda sem foto: oferece a tela de foto antes de entrar (ela e
  // opcional — "Continuar" sem escolher nenhuma avanca normalmente).
  bool needsPhoto = false;
  // Cadastro novo ainda sem localizacao: diferente da foto, estado/cidade sao
  // obrigatorios — sem este sinal, reabrir o app depois da admissao mas antes
  // de escolher a cidade pulava `Step.location` pra sempre.
  bool needsLocation = false;
  // Id da conta (de `/me`), so pra marcar em `WelcomeSeenPrefs` quando a
  // celebracao for de fato concluida.
  String? welcomeAccountId;
  // A foto ja esta confirmada no servidor (`photoReference` em `/me`): a
  // ficha da celebracao pode mostrar via `SignedPhoto` quando `chosenPhoto`
  // (so em memoria) ja se perdeu por ter fechado o app depois do envio mas
  // antes de "Começar minha jornada" (bug real, reportado em 24/11/2026).
  bool hasServerPhoto = false;
  // "Manter conectado": guarda so o token de renovacao, nunca a senha.
  bool keepSignedIn = true;
  // Entrando com a sessao guardada: mostra um indicador em vez do formulario.
  bool restoring = false;
  List<int>? chosenPhoto;
  // "Ver senha": vale pra qualquer tela com campo de senha (entrar, criar conta,
  // definir/redefinir senha — so uma fica ativa por vez, nao precisa de uma flag
  // por tela) e deve estar sempre disponivel, nunca escondida em alguma etapa.
  bool showPassword = false;
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
    // Troca manual de etapa (Criar conta / Esqueceu a senha / Voltar): campo
    // de codigo e de senha sempre vazios na etapa de destino, nunca com o que
    // sobrou de uma tentativa anterior (outro fluxo, ou o mesmo abandonado).
    code.clear();
    password.clear();
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
    // `locationConfirmed` exige que a pessoa tenha tocado "Continuar" na tela
    // de localizacao NESTA sessao: sem isso, um rascunho local restaurado ou
    // a deteccao automatica por GPS (que tambem preenchem selectedUf/selectedCity,
    // sem a pessoa ter visto essa tela) enviavam a localizacao sozinhos e
    // pulavam a etapa pra sempre (bug real, reportado mais de uma vez).
    if (response['myStatus'] == 'admitted' &&
        !locationSynced &&
        locationConfirmed &&
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
      // Sem isso, o switch abaixo mandava de volta pra Step.location de novo,
      // mesmo location acabando de ser salva com sucesso (needsLocation so e
      // recalculada em resume(), nunca aqui).
      needsLocation = false;
      final syncedId = welcomeAccountId;
      if (syncedId != null) {
        unawaited(OnboardingDraftPrefs.clearLocation(syncedId));
      }
    }
    step = switch (response['myStatus']) {
      'admitted' => Step.ready,
      'waiting' => Step.waiting,
      'closed' => Step.closed,
      _ => Step.admission,
    };
    // Localizacao e obrigatoria e vem antes da foto (que e opcional) na ordem
    // do cadastro.
    if (step == Step.ready && needsLocation) step = Step.location;
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
      final id = welcomeAccountId;
      if (id != null) {
        OnboardingDraftPrefs.saveLocation(
          id,
          parts[0],
          parts[1],
          lat: coordinate.lat,
          lon: coordinate.lon,
        );
      }
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
    // Sem data anterior, a roda abre em ~25 anos atrás (uma idade qualquer, nunca a mínima) e o
    // "Concluído" só vale depois de a pessoa girar alguma roda: tocar direto nele não confirma uma data
    // que ela não escolheu.
    final initial = birthDate ?? DateTime(now.year - 25, now.month, now.day);
    var touched = birthDate != null;
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
                        onPressed: touched
                            ? () => Navigator.pop(sheetContext, true)
                            : null,
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
                          onChanged: (i) => setSheetState(() {
                            day = i + 1;
                            touched = true;
                          }),
                        ),
                        wheelColumn(
                          label: 'Mês',
                          controller: monthController,
                          itemCount: 12,
                          text: (i) => _monthNames[i],
                          onChanged: (i) => setSheetState(() {
                            touched = true;
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
                            touched = true;
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
      final id = welcomeAccountId;
      if (id != null) OnboardingDraftPrefs.saveBirthDate(id, birthDate!);
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
        final id = welcomeAccountId;
        if (id != null) unawaited(ChosenPhotoDraftPrefs.save(id, bytes));
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
      final id = welcomeAccountId;
      if (id != null) unawaited(ChosenPhotoDraftPrefs.save(id, cropped));
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
      // Mesma logica de nome/usuario, agora pra genero/nascimento: depois que a
      // admissao e aceita, esses dois ficam salvos no servidor (o rascunho local
      // ja foi apagado, de proposito, por nao fazer mais falta) — sem repopular
      // aqui, reabrir o app depois da admissao (ja em Step.location ou mais
      // adiante) mostrava a ficha de inscricao sem genero nem nascimento.
      final savedGender = profile['gender'] as String?;
      if (savedGender != null) gender = savedGender;
      final savedBirthDate = profile['birthDate'] as String?;
      if (savedBirthDate != null) {
        try {
          birthDate = DateTime.parse(savedBirthDate);
        } on FormatException {
          // Ignora: mantem o que ja estava (rascunho local ou nenhum).
        }
      }
      // Poucas edicoes no perfil: o cadastro provavelmente nao foi concluido (so a
      // criacao, mais talvez uma correcao de nome/usuario antes da admissao, o patch
      // de localizacao ou o da foto, nunca mais que isso nesta fase). Quem edita o
      // perfil depois de usar o app por um tempo tem muito mais edicoes acumuladas
      // (posts, legendas, perfil etc) e nao cai aqui. Nao e um sinal perfeito (um
      // numero exato de edicoes concluidas nunca foi guardado), mas e bem mais seguro
      // do que exigir a versao exata de cada etapa.
      // Versao ausente na resposta (nao deveria acontecer num backend real, mas
      // alguns testes simulam respostas minimas): trata como "nao fresco", igual
      // ao comportamento anterior, em vez de arriscar mostrar essas telas a toa pra
      // quem ja usa o app ha tempo.
      final stillOnboarding = (profile['version'] as int? ?? 999) <= 4;
      needsPhoto = profile['photoReference'] == null && stillOnboarding;
      hasServerPhoto = profile['photoReference'] != null;
      // Mesmo sinal da foto, mas pra localizacao: sem isso, reabrir o app depois da
      // admissao mas antes de escolher estado/cidade pulava `Step.location` pra
      // sempre (essa etapa, sozinha, nao tinha nenhum sinal vindo do backend).
      needsLocation = profile['state'] == null && stillOnboarding;
      final savedState = profile['state'] as String?;
      final savedCity = profile['city'] as String?;
      if (savedState != null && savedCity != null) {
        selectedUf = savedState;
        selectedCity = savedCity;
        locationSynced = true;
      }
      // Antes, "freshSignup" so virava true dentro da MESMA sessao em que o perfil
      // era criado (Step.profile); fechar o app entre a admissao e a foto/celebracao
      // zerava essa flag na proxima sessao, e a pessoa nunca mais via a tela de
      // "Boas-vindas" — ela e a ultima etapa do cadastro e nao pode ser pulada.
      // `PendingCelebrationPrefs` persiste essa pendencia no aparelho desde a
      // criacao do perfil (ver Step.profile) ate a celebracao de fato ser
      // concluida; diferente de usar a versao do perfil, nao marca como
      // "fresca" uma conta antiga de verdade que so nunca editou o perfil.
      welcomeAccountId = profile['id'] as String?;
      freshSignup =
          welcomeAccountId != null &&
          await PendingCelebrationPrefs.isPending(welcomeAccountId!);
      // Restaura o rascunho da admissao (genero/nascimento/maioridade) ainda
      // nao confirmado no servidor quando o app fechou antes de tocar
      // "Continuar" naquela tela — sem sobrescrever o que ja estiver
      // preenchido nesta mesma sessao. So a admissao: ela nunca e enviada
      // sozinha, so quando a pessoa toca "Continuar" na tela de admissao, por
      // isso e seguro repopular antes de `status()`. O rascunho e apagado
      // assim que a admissao de fato for aceita no servidor.
      final draftId = welcomeAccountId;
      if (draftId != null) {
        gender ??= await OnboardingDraftPrefs.loadGender(draftId);
        birthDate ??= await OnboardingDraftPrefs.loadBirthDate(draftId);
        if (!adult) {
          adult = await OnboardingDraftPrefs.loadAdult(draftId) ?? false;
        }
      }
      await status();
      // O rascunho de LOCALIZACAO so pode ser restaurado depois de `status()`
      // decidir a etapa, e so quando ela de fato for `Step.location` — nunca
      // antes. `status()` envia a localizacao ao servidor automaticamente na
      // primeira vez que ve a conta admitida, so checando se
      // `selectedUf`/`selectedCity` nao sao nulos; preencher esses campos
      // ANTES dessa checagem (com um rascunho de uma tentativa anterior, ou
      // so de uma deteccao de GPS em segundo plano) enviava a localizacao
      // sem a pessoa nunca ter visto essa tela, pulando-a de vez (bug real,
      // reportado em 24/11/2026).
      if (draftId != null && step == Step.location) {
        final draftUf = await OnboardingDraftPrefs.loadUf(draftId);
        final draftCity = await OnboardingDraftPrefs.loadCity(draftId);
        if (draftUf != null && draftCity != null) {
          selectedUf = draftUf;
          selectedCity = draftCity;
          selectedLat = await OnboardingDraftPrefs.loadLat(draftId);
          selectedLon = await OnboardingDraftPrefs.loadLon(draftId);
        }
      }
      // A foto escolhida (e ja recortada) na tela de foto so e enviada ao
      // servidor quando a pessoa toca em "Continuar" ali; antes disso fica
      // so em memoria, e fechar o app nessa etapa perdia a foto, mesmo a
      // etapa certa voltando a aparecer (24/11/2026). Restaura o rascunho em
      // arquivo so quando `status()` de fato decidiu `Step.photo`.
      if (draftId != null && step == Step.photo && chosenPhoto == null) {
        chosenPhoto = await ChosenPhotoDraftPrefs.load(draftId);
      }
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
      if (error.code == 'UserNotConfirmedException') {
        // Campo de codigo sempre vazio ao entrar numa tela que o usa, nunca
        // com um valor de uma tentativa anterior (usada ou nao).
        code.clear();
        step = Step.confirm;
        // Reenvia o codigo sozinho: a pessoa tentou logar sem saber que
        // ainda faltava confirmar o e-mail, nao devia precisar tocar em
        // "Reenviar código" na tela seguinte so pra receber o primeiro.
        try {
          await widget.gateway?.resendConfirmation(email.text.trim());
        } on IdentityIssue {
          // Falhou por outro motivo (limite de tentativas etc.): o botao de
          // reenviar continua disponivel na tela de confirmacao.
        }
      }
      if (error.code == 'INVALID_TOKEN' ||
          error.code == 'ACCOUNT_UNAVAILABLE') {
        step = Step.signIn;
      }
      message = switch (error.code) {
        // Mensagem unica de proposito: o Cognito recusa (PreventUserExistenceErrors)
        // dizer se o e-mail nao existe ou se so a senha esta errada, pra nao dar
        // pra descobrir quais e-mails tem conta so testando no login.
        'NotAuthorizedException' || 'INVALID_TOKEN' => 'E-mail ou senha incorretos. Se ainda não tem conta, toque em Criar conta.',
        'UserNotConfirmedException' =>
          'Confirme seu e-mail. Enviamos um novo código de confirmação.',
        'UsernameExistsException' =>
          'Já existe uma conta com esse e-mail. Entre ou recupere sua senha.',
        // O Cognito recusa "esqueci minha senha" com esse código quando a conta
        // existe mas ainda não foi confirmada; mandar pra tela de cadastro de
        // novo com o mesmo e-mail reenvia o código de confirmação pendente
        // (ver signUp()/resumedSignUp), em vez de travar aqui.
        'InvalidParameterException' => 'Esse cadastro ainda não foi confirmado. Toque em "Criar conta" com o mesmo e-mail para receber um novo código.',
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
        'SOCIAL_LOGIN_CANCELLED' => null,
        'SOCIAL_LOGIN_FAILED' =>
          'Não foi possível entrar com essa conta agora. Tente novamente.',
        'SOCIAL_LOGIN_UNAVAILABLE' =>
          'Login social indisponível neste ambiente.',
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

  /// Login via Google/Facebook (Hosted UI). `provider` e o nome do Identity Provider
  /// no User Pool ("Google"/"Facebook"). Mesmo destino de `submit()` no caso
  /// `Step.signIn`: `resume()` decide a proxima tela (perfil, se for a primeira vez
  /// da conta federada; ready, se ja estiver admitida).
  Future<void> signInWithSocialProvider(String provider) => perform(() async {
    await widget.gateway!.signInWithProvider(provider);
    await resume();
  });

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
        // So coleta o e-mail aqui; a senha e o SignUp de verdade acontecem na
        // proxima etapa (ver Step.setPassword), nessa ordem de proposito: sem
        // isso, um fechar o app bem ali deixava um e-mail registrado no
        // Cognito sem senha nenhuma, numa zona cinzenta dificil de recuperar.
        code.clear();
        password.clear();
        step = Step.setPassword;
      case Step.setPassword:
        final weakReason = weakPasswordReason(password.text, email.text.trim());
        if (weakReason != null) {
          message = weakReason;
          return;
        }
        await gateway.signUp(email.text.trim(), password.text);
        code.clear();
        step = Step.confirm;
        if (gateway.resumedSignUp) {
          // E-mail ja tinha um cadastro pendente, so sem confirmar: a senha
          // dessa tentativa NAO vale (a conta ja tem a senha definida na
          // primeira vez, e nao ha como troca-la antes de confirmar). Avisa
          // e nao usa o valor digitado.
          password.clear();
          message =
              'Encontramos um cadastro não finalizado com esse e-mail. '
              'Enviamos um novo código de confirmação — a senha continua '
              'sendo a que você já tinha criado.';
        }
      case Step.confirm:
        await gateway.confirm(email.text.trim(), code.text.trim());
        code.clear();
        if (gateway.resumedSignUp) {
          // Senha pode ser de uma tentativa anterior (perdida ao fechar o
          // app); sem como saber qual das duas digitadas e a que vale, pede
          // login normal em vez de entrar direto.
          password.clear();
          step = Step.signIn;
          message =
              'E-mail confirmado! Entre com sua senha (ou toque em '
              '"Esqueceu a senha?" se não lembrar).';
        } else {
          // Mesma sessao, senha digitada ha pouco e a senha real da conta.
          await gateway.signIn(
            email.text.trim(),
            password.text,
            keepSignedIn: keepSignedIn,
          );
          password.clear();
          showPassword = false;
          await SavedAccount.save(email.text.trim());
          await resume();
        }
      case Step.forgot:
        await gateway.forgot(email.text.trim());
        code.clear();
        password.clear();
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
        welcomeAccountId = profile['id'] as String?;
        // Persiste a pendencia da celebracao no aparelho desde ja: fechar o
        // app em qualquer etapa seguinte (admissao, localizacao, foto) nao
        // deve fazer a pessoa perder a tela de "Boas-vindas" no fim.
        final id = welcomeAccountId;
        if (id != null) PendingCelebrationPrefs.markPending(id);
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
        // Admitido de verdade: o rascunho local de genero/nascimento/maioridade
        // nao faz mais falta.
        final admittedId = welcomeAccountId;
        if (admittedId != null) {
          unawaited(OnboardingDraftPrefs.clearAdmission(admittedId));
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
        // So aqui a pessoa de fato CONFIRMOU a localizacao, tocando em
        // "Continuar" nesta tela — e a UNICA coisa que autoriza `status()` a
        // enviar isso ao servidor (ver locationConfirmed). Nunca inferir
        // essa confirmacao so pelo campo estar preenchido: um rascunho local
        // restaurado ou a deteccao automatica por GPS tambem preenchem
        // selectedUf/selectedCity, sem a pessoa ter visto ou aceitado essa
        // tela (bug real, reportado mais de uma vez, em 23-24/11/2026).
        locationConfirmed = true;
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
          hasServerPhoto = true;
        }
        needsPhoto = false;
        // Nao limpa chosenPhoto aqui: a ficha da celebracao reaproveita o mesmo
        // bytes para mostrar a foto escolhida (sumia antes, por causa disso).
        // So limpa o RASCUNHO EM ARQUIVO: a foto ja esta confirmada no
        // servidor (photoReference), nao precisa mais do arquivo local.
        final id = welcomeAccountId;
        if (id != null) unawaited(ChosenPhotoDraftPrefs.clear(id));
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
      onPressed: busy
          ? null
          : () => setState(() {
              gender = value;
              final id = welcomeAccountId;
              if (id != null) OnboardingDraftPrefs.saveGender(id, value);
            }),
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
      // Mesma estrutura das telas de cadastro (_signupScaffold): bloco de cima
      // (aviso, ficha, "Bem-vindo") dentro da area que rola se precisar, nunca
      // usando Expanded/Spacer ali dentro (altura indefinida dentro de scroll
      // da erro); o texto final e o botao ficam fixos fora da rolagem, no
      // mesmo recuo do rodape que o "Continuar" das telas anteriores.
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  // LayoutBuilder+ConstrainedBox(minHeight)+Column com
                  // mainAxisAlignment.spaceBetween (em vez de Expanded/Spacer
                  // aqui dentro, que da erro de altura indefinida dentro de
                  // scroll): com 3 "filhos" (bloco de cima, "Bem-vindo" e um
                  // marcador invisivel no fim), os dois espacos que sobram
                  // ficam iguais — "Bem-vindo" fica centralizado entre a ficha
                  // e o fim deste bloco (ali comeca "A partir de agora...",
                  // fora da rolagem). Sem espaco de sobra (tela baixa), os
                  // espacos encolhem a zero e o bloco todo rola normalmente.
                  child: LayoutBuilder(
                    builder: (context, constraints) => SingleChildScrollView(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: constraints.maxHeight,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Mesmo recuo do topo das telas de cadastro antes
                                // da ficha (ali ocupado pela seta de voltar,
                                // progresso, titulo etc.): sem isso, a ficha
                                // ficava mais alta aqui que nas outras.
                                const SizedBox(height: 94),
                                // "INSCRIÇÃO CONFIRMADA" logo acima da ficha, com
                                // um espaco pequeno: destaca que o cadastro deu
                                // certo, coladinho nela.
                                Center(
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withValues(
                                        alpha: .18,
                                      ),
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: const [
                                        Image(
                                          image: AssetImage(
                                            'assets/icons/verificado.png',
                                          ),
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
                                ),
                                const SizedBox(height: 16),
                                RegistrationCard(
                                  displayName: displayName,
                                  username: username.text.trim().isEmpty
                                      ? null
                                      : username.text.trim(),
                                  cityLabel:
                                      selectedUf == null || selectedCity == null
                                      ? null
                                      : '$selectedCity, $selectedUf',
                                  birthDate: birthDate,
                                  gender: gender,
                                  registrationCode: registrationCode,
                                  photo: chosenPhoto == null
                                      ? null
                                      : Uint8List.fromList(chosenPhoto!),
                                  gateway: widget.gateway,
                                  accountId: welcomeAccountId,
                                  hasServerPhoto: hasServerPhoto,
                                  inscriptionDate: DateTime.now(),
                                  onTapPhoto: () =>
                                      setState(() => step = Step.photo),
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
                              ],
                            ),
                            Text(
                              firstName == null
                                  ? 'Bem-vindo!'
                                  : 'Bem-vindo\n$firstName!',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w900,
                                height: 1.25,
                                color: runPassNavy,
                              ),
                            ),
                            const SizedBox.shrink(),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Text(
                  // Fora da area que rola, sempre visivel logo acima do botao.
                  'A partir de agora, cada corrida que você registrar entra no seu Pódio de medalhas e vira parte da sua história.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13.5,
                    color: runPassNavy.withValues(alpha: .75),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: runPassNavy,
                      minimumSize: const Size.fromHeight(54),
                    ),
                    onPressed: () {
                      // So limpa a pendencia aqui, quando a pessoa de fato
                      // concluiu a celebracao — fechar o app antes disso deve
                      // mostrar a mesma tela de novo, nunca pular pra Home.
                      final id = welcomeAccountId;
                      if (id != null) PendingCelebrationPrefs.clearPending(id);
                      openHome();
                    },
                    child: const Text('Começar minha jornada'),
                  ),
                ),
              ],
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
                          // Login social (Google/Facebook): so na tela de criar conta
                          // (padrao combinado em 25/11/2026), e so quando o ambiente tem
                          // Hosted UI configurada (hoje, so DEV — ver infra/identity.template.json).
                          if (step == Step.signUp &&
                              widget.gateway?.hostedUiDomain != null) ...[
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                _SocialCircleButton(
                                  asset: 'assets/icons/google-icon.png',
                                  tooltip: 'Continuar com Google',
                                  onPressed: busy
                                      ? null
                                      : () =>
                                            signInWithSocialProvider('Google'),
                                ),
                                const SizedBox(width: 16),
                                _SocialCircleButton(
                                  asset: 'assets/icons/facebook-icon.png',
                                  tooltip: 'Continuar com Facebook',
                                  onPressed: busy
                                      ? null
                                      : () => signInWithSocialProvider(
                                          'Facebook',
                                        ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 20),
                            Row(
                              children: [
                                Expanded(
                                  child: Divider(color: context.panelStrong),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                  ),
                                  child: Text(
                                    'ou',
                                    style: TextStyle(
                                      color: context.isDark
                                          ? Colors.white70
                                          : Colors.black54,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: Divider(color: context.panelStrong),
                                ),
                              ],
                            ),
                            const SizedBox(height: 20),
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
                              // Sem campo de confirmacao: o olho mostra/oculta a senha digitada,
                              // sempre disponivel em qualquer tela com campo de senha.
                              secret: !showPassword,
                              suffixIcon: IconButton(
                                icon: Icon(
                                  showPassword
                                      ? Icons.visibility_off
                                      : Icons.visibility,
                                ),
                                onPressed: () => setState(() {
                                  showPassword = !showPassword;
                                }),
                              ),
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
                          if (step == Step.signUp)
                            const LegalLinks(acceptance: true),
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
                            const SizedBox(height: 8),
                            const LegalLinks(),
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
                    // Cabecalho (voltar, progresso, titulo, ficha) agora dentro da
                    // mesma area que rola que os campos: sozinho, fixo fora da
                    // rolagem, ele nao cedia espaco quando o teclado aparecia, e o
                    // botao "Continuar" ficava colado no campo focado. Sem foco, a
                    // rolagem comeca no topo, entao a posicao inicial da ficha nao
                    // muda.
                    Expanded(
                      child: SingleChildScrollView(
                        // Folga embaixo do conteudo: sem ela, o campo focado encosta
                        // bem na borda da area rolavel quando o teclado aparece,
                        // ficando colado (quase escondido) no botao "Continuar" logo
                        // abaixo, fora da area que rola.
                        padding: const EdgeInsets.only(bottom: 24),
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
                                      (step != Step.profile ||
                                          editingFromCelebration)
                                      ? InkWell(
                                          key: const Key('signup-back'),
                                          onTap: busy
                                              ? null
                                              : () => setState(() {
                                                  if (editingFromCelebration) {
                                                    editingFromCelebration =
                                                        false;
                                                    step = Step.celebration;
                                                  } else {
                                                    step = _previousSignupStep(
                                                      step,
                                                    );
                                                  }
                                                }),
                                          customBorder: const CircleBorder(),
                                          child: Container(
                                            width: 40,
                                            height: 40,
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              color: Theme.of(context)
                                                  .cardColor,
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
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1,
                                color: runPassOrange,
                              ),
                            ),
                            const SizedBox(height: 4),
                            // Altura fixa (1 linha sempre, nunca quebra): alguns
                            // titulos sao bem mais longos que outros ("Em qual
                            // categoria você corre?" vs "Crie sua senha"), entao o
                            // FittedBox encolhe so os titulos longos o quanto for
                            // preciso pra caber numa linha so, sem quebrar nem
                            // cortar texto, com uma unica altura de cabecalho em
                            // todas as etapas do cadastro.
                            SizedBox(
                              height: 32,
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    title,
                                    maxLines: 1,
                                    style:
                                        const TextStyle(
                                          fontWeight: FontWeight.w800,
                                          fontSize: 24,
                                          color: runPassNavy,
                                        ).copyWith(
                                          color: context.isDark
                                              ? Colors.white
                                              : null,
                                        ),
                                  ),
                                ),
                              ),
                            ),
                            // Texto mais proximo da ficha (decisao de produto de
                            // 24/11/2026): so o espaco minimo pro titulo nao colar
                            // visualmente na ficha, sem a folga de antes. A ficha em
                            // si (RegistrationCard) nao muda.
                            const SizedBox(height: 4),
                            RegistrationCard(
                              displayName: name.text.trim().isEmpty
                                  ? displayName
                                  : name.text.trim(),
                              username: username.text.trim().isEmpty
                                  ? null
                                  : username.text.trim(),
                              cityLabel:
                                  selectedUf == null || selectedCity == null
                                  ? null
                                  : '$selectedCity, $selectedUf',
                              birthDate: birthDate,
                              gender: gender,
                              registrationCode: registrationCode,
                              photo: chosenPhoto == null
                                  ? null
                                  : Uint8List.fromList(chosenPhoto!),
                              gateway: widget.gateway,
                              accountId: welcomeAccountId,
                              hasServerPhoto: hasServerPhoto,
                              inscriptionDate: DateTime.now(),
                            ),
                            // Distancia uniforme da ficha em todas as telas do cadastro: antes so
                            // o perfil tinha folga extra, e as outras (genero/nascimento,
                            // localizacao) ficavam coladas na ficha.
                            const SizedBox(height: 18),
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
                                          final id = welcomeAccountId;
                                          if (id != null) {
                                            OnboardingDraftPrefs.saveLocation(
                                              id,
                                              picked.$1,
                                              picked.$2,
                                              lat: picked.$3,
                                              lon: picked.$4,
                                            );
                                          }
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
                                    : (value) {
                                        setState(() => adult = value ?? false);
                                        final id = welcomeAccountId;
                                        if (id != null) {
                                          OnboardingDraftPrefs.saveAdult(
                                            id,
                                            adult,
                                          );
                                        }
                                      },
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
                              Align(
                                alignment: Alignment.centerLeft,
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    'Foto opcional, pode ser adicionada depois no menu do perfil',
                                    maxLines: 1,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: context.muted,
                                    ),
                                  ),
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
                              // A foto e a unica etapa opcional do cadastro; mesmo sem
                              // foto escolhida, o botao e sempre "Continuar" — nunca um
                              // "Pular" separado (decisao de produto de 23/11/2026).
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

/// Botao circular pequeno e discreto para login social (Google/Facebook): mesmo desenho
/// sempre que aparecer, sem texto (padrao unico por funcao, AGENTS.md). As logomarcas sao
/// PNG com fundo transparente — por isso o fundo e so uma cor neutra bem sutil, sem borda
/// (uma borda ao redor de um circulo colorido de marca ficaria pesado/chamativo demais).
class _SocialCircleButton extends StatelessWidget {
  final String asset;
  final String tooltip;
  final VoidCallback? onPressed;

  const _SocialCircleButton({
    required this.asset,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        customBorder: const CircleBorder(),
        child: Container(
          width: 44,
          height: 44,
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: context.isDark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.black.withValues(alpha: 0.04),
          ),
          child: Image.asset(asset, fit: BoxFit.contain),
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
