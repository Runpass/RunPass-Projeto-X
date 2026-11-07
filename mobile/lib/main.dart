import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'identity_gateway.dart';
import 'catalog_screen.dart';
import 'biometrics.dart';
import 'home_screen.dart';
import 'notifications.dart';
import 'password_policy.dart';
import 'profile_photo.dart';
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
      title: 'RunPass',
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
  photo,
  ready,
  waiting,
  closed,
}

class IdentityScreen extends StatefulWidget {
  final IdentityGateway? gateway;

  /// Aviso mostrado na tela de entrada (por exemplo, depois de excluir a conta).
  final String? notice;
  final ProfilePhotoPicker photoPicker;
  const IdentityScreen({
    super.key,
    this.gateway,
    this.notice,
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
  final form = GlobalKey<FormState>();
  Step step = Step.signIn;
  bool busy = false, adult = false, full = false;
  // Seletor nativo de rolagem (dia/mes/ano), igual ao Instagram; sem campo de texto livre.
  DateTime? birthDate;
  String? message;
  String? displayName;
  // Cadastro novo ainda sem foto: a foto de perfil e obrigatoria antes de entrar.
  bool needsPhoto = false;
  // "Manter conectado": guarda so o token de renovacao, nunca a senha.
  bool keepSignedIn = true;
  // Entrando com a sessao guardada: mostra um indicador em vez do formulario.
  bool restoring = false;
  List<int>? chosenPhoto;
  // "Crie sua senha": o olho mostra/oculta em vez de um campo de confirmacao.
  bool showPassword = false;

  @override
  void initState() {
    super.initState();
    message = widget.notice;
    if (widget.gateway?.canRestore ?? false) restoreSession();
  }

  /// Mostra "Entrar com biometria" quando a trava esta ligada e ha sessao guardada.
  bool biometricLocked = false;

  Future<void> restoreSession() async {
    setState(() => restoring = true);
    try {
      if (await BiometricPrefs.enabled()) {
        // Trava ligada: a biometria vem antes de renovar o acesso. Falhou ou cancelou:
        // cai na tela de entrada (senha) com o botao para tentar de novo.
        final ok = await biometricGate.authenticate(
          'Entrar no RunPass com a biometria',
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
    if (mounted) setState(() => restoring = false);
  }

  @override
  void dispose() {
    for (final field in [email, password, code, name, username]) {
      field.dispose();
    }
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
    step = switch (response['myStatus']) {
      'admitted' => Step.ready,
      'waiting' => Step.waiting,
      'closed' => Step.closed,
      _ => Step.admission,
    };
    if (step == Step.ready && needsPhoto) step = Step.photo;
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

  /// Seletor nativo de rolagem (dia/mes/ano), igual ao Instagram: evita erro de formato,
  /// mas o servidor segue como a unica fonte confiavel da idade (contrato BetaAdmissionInput).
  Future<void> pickBirthDate() async {
    final now = DateTime.now();
    var selected = birthDate ?? DateTime(now.year - 18, now.month, now.day);
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: 300,
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: const Key('birth-date-done'),
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Concluído'),
                ),
              ),
              Expanded(
                child: CupertinoDatePicker(
                  mode: CupertinoDatePickerMode.date,
                  initialDateTime: selected,
                  minimumYear: now.year - 100,
                  maximumDate: now,
                  onDateTimeChanged: (value) => selected = value,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (confirmed == true && mounted) {
      setState(() {
        birthDate = selected;
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

  Future<void> resume() async {
    try {
      final profile = await widget.gateway!.request('/me');
      displayName = profile['displayName'] as String?;
      // Versao 1 sem foto: o cadastro nao foi concluido. Quem apagou a foto depois, nao.
      needsPhoto = profile['photoReference'] == null && profile['version'] == 1;
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
        'NOT_ELIGIBLE' => 'O período de avaliação é destinado a pessoas com 18 anos completos ou mais.',
        'BETA_FULL' => 'As vagas do período de avaliação foram preenchidas. Você pode entrar na lista de espera.',
        'IMAGE_TYPE_INVALID' ||
        'IMAGE_NOT_VALID' ||
        'IMAGE_SIZE_INVALID' ||
        'UPLOAD_UNAVAILABLE' => photoError(error),
        'ACCOUNT_UNAVAILABLE' => 'Esta conta está indisponível.',
        'INVALID_INPUT' => 'Confira os campos e tente novamente.',
        _ => 'Não foi possível concluir agora (falta de conexão ou instabilidade do serviço). Seus dados continuam nesta tela; tente novamente em instantes.',
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
        await resume();
      case Step.signUp:
        await gateway.signUp(email.text.trim());
        step = Step.confirm;
      case Step.confirm:
        await gateway.confirm(email.text.trim(), code.text.trim());
        code.clear();
        step = Step.setPassword;
        message = 'E-mail confirmado. Agora crie sua senha.';
      case Step.setPassword:
        final weakReason = weakPasswordReason(password.text, email.text.trim());
        if (weakReason != null) {
          message = weakReason;
          return;
        }
        await gateway.setPassword(email.text.trim(), password.text);
        password.clear();
        showPassword = false;
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
        final profile = await gateway.request(
          '/me',
          method: 'PUT',
          body: {'displayName': name.text.trim(), 'username': username.text},
        );
        displayName = profile['displayName'] as String?;
        needsPhoto = true;
        await status();
      case Step.photo:
        final photo = chosenPhoto;
        if (photo == null) {
          message = 'Escolha uma foto para continuar.';
          return;
        }
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
        needsPhoto = false;
        chosenPhoto = null;
        step = Step.ready;
      case Step.admission:
        final birth = birthDate;
        if (birth == null) {
          message = 'Selecione sua data de nascimento.';
          return;
        }
        if (!adult) {
          message = 'Confirme que tem 18 anos completos ou mais.';
          return;
        }
        await gateway.request(
          full ? '/beta/waitlist' : '/beta/admissions',
          method: 'POST',
          body: {'birthDate': isoBirthDate(birth), 'declaresAdult': adult},
        );
        birthDate = null;
        await status();
      case Step.ready || Step.waiting || Step.closed:
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
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextFormField(
      controller: controller,
      decoration: InputDecoration(labelText: label, suffixIcon: suffixIcon),
      obscureText: secret,
      autocorrect: !secret,
      enableSuggestions: !secret,
      keyboardType: controller == email
          ? TextInputType.emailAddress
          : TextInputType.text,
      maxLength: maxLength,
      validator: (value) {
        if (value == null || value.trim().isEmpty) {
          return 'Preencha este campo.';
        }
        return check?.call(value);
      },
    ),
  );

  @override
  Widget build(BuildContext context) {
    final gateway = widget.gateway;
    final initial = [
      Step.signIn,
      Step.signUp,
      Step.confirm,
      Step.setPassword,
      Step.forgot,
      Step.reset,
    ].contains(step);
    final title = switch (step) {
      Step.signIn => 'Entre no RunPass',
      Step.signUp => 'Crie sua conta',
      Step.confirm => 'Confirme seu e-mail',
      Step.setPassword => 'Crie sua senha',
      Step.forgot => 'Recupere sua senha',
      Step.reset => 'Defina uma nova senha',
      Step.profile => 'Seu perfil de corredor',
      Step.admission =>
        full ? 'Lista de espera' : 'Participe do período de avaliação',
      Step.photo => 'Sua foto de perfil',
      Step.ready => 'Entrando, ${displayName ?? 'corredor'}…',
      Step.waiting => 'Você está na lista de espera',
      Step.closed => 'As admissões do período de avaliação foram encerradas',
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
                      'O RunPass ainda não está disponível neste ambiente.',
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
                                  Text(
                                    'Mais que corridas.\nSão histórias para sempre.',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w800,
                                      fontSize: 23,
                                      height: 1.08,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          if (step == Step.signIn || step == Step.signUp)
                            const SizedBox(height: 24),
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
                              secret: step == Step.setPassword
                                  ? !showPassword
                                  : true,
                              suffixIcon: step == Step.setPassword
                                  ? IconButton(
                                      icon: Icon(
                                        showPassword
                                            ? Icons.visibility_off
                                            : Icons.visibility,
                                      ),
                                      onPressed: () => setState(
                                        () => showPassword = !showPassword,
                                      ),
                                    )
                                  : null,
                            ),
                          if (step == Step.signIn)
                            CheckboxListTile(
                              key: const Key('keep-signed-in'),
                              contentPadding: EdgeInsets.zero,
                              controlAffinity: ListTileControlAffinity.leading,
                              value: keepSignedIn,
                              onChanged: busy
                                  ? null
                                  : (value) => setState(
                                      () => keepSignedIn = value ?? true,
                                    ),
                              title: const Text('Manter conectado'),
                            ),
                          if ([Step.confirm, Step.reset].contains(step))
                            field(code, 'Código recebido'),
                          if (step == Step.profile) ...[
                            field(name, 'Nome de exibição', maxLength: 80),
                            field(
                              username,
                              'Nome de usuário',
                              maxLength: 30,
                              check: (value) =>
                                  RegExp(r'^[A-Za-z0-9_]{3,30}$')
                                      .hasMatch(value)
                                  ? null
                                  : 'Use de 3 a 30 letras sem acento, números ou _.',
                            ),
                          ],
                          if (step == Step.admission) ...[
                            Text(
                              full
                                  ? 'A lista de espera não garante vaga ou posição.'
                                  : 'Período de avaliação gratuito para maiores de 18 anos.',
                            ),
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: InkWell(
                                key: const Key('birth-date-field'),
                                onTap: busy ? null : pickBirthDate,
                                child: InputDecorator(
                                  decoration: const InputDecoration(
                                    labelText: 'Data de nascimento',
                                  ),
                                  child: Text(
                                    birthDate == null
                                        ? 'Selecionar data de nascimento'
                                        : formatBirthDate(birthDate!),
                                  ),
                                ),
                              ),
                            ),
                            if (birthDate != null)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Text(
                                  '${ageInYears(birthDate!)} anos',
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(fontWeight: FontWeight.w600),
                                ),
                              ),
                            // Visivel so para o proprio titular (perfil); nunca publica.
                            const Text(
                              'Sua data de nascimento não é pública. Você pode vê-la depois no seu perfil.',
                            ),
                            CheckboxListTile(
                              value: adult,
                              onChanged: busy
                                  ? null
                                  : (value) =>
                                        setState(() => adult = value ?? false),
                              title: const Text(
                                'Declaro ter 18 anos completos ou mais.',
                              ),
                            ),
                          ],
                          if (step == Step.photo) ...[
                            const Text(
                              'Para seus amigos reconhecerem você, adicione uma foto. Ela é obrigatória e você poderá trocar ou remover depois, no perfil.',
                            ),
                            const SizedBox(height: 16),
                            Center(
                              child: InkWell(
                                key: const Key('choose-photo'),
                                customBorder: const CircleBorder(),
                                onTap: busy ? null : choosePhoto,
                                child: CircleAvatar(
                                  radius: 64,
                                  backgroundColor: context.softFill,
                                  backgroundImage: chosenPhoto == null
                                      ? null
                                      : MemoryImage(
                                          Uint8List.fromList(chosenPhoto!),
                                        ),
                                  child: chosenPhoto == null
                                      ? const Icon(
                                          Icons.add_a_photo_outlined,
                                          size: 40,
                                          color: runPassOrange,
                                        )
                                      : null,
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
                                    : step == Step.admission && full
                                    ? 'Entrar na lista de espera'
                                    : step == Step.signIn
                                    ? 'Entrar no RunPass'
                                    : 'Continuar',
                              ),
                            ),
                          if (step == Step.signIn && biometricLocked)
                            OutlinedButton.icon(
                              key: const Key('biometric-retry'),
                              onPressed: busy ? null : restoreSession,
                              icon: const Icon(Icons.fingerprint),
                              label: const Text('Entrar com biometria'),
                            ),
                          if (step == Step.signIn) ...[
                            TextButton(
                              onPressed: busy
                                  ? null
                                  : () => change(Step.signUp),
                              child: const Text('Criar conta'),
                            ),
                            TextButton(
                              onPressed: busy
                                  ? null
                                  : () => change(Step.forgot),
                              child: const Text('Esqueci minha senha'),
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
}

String isoBirthDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

String formatBirthDate(DateTime date) =>
    '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';

/// So para mostrar na tela (ex.: "18 anos"); o servidor e a unica fonte confiavel da idade.
int ageInYears(DateTime birth, {DateTime? today}) {
  final now = today ?? DateTime.now();
  var age = now.year - birth.year;
  if (now.month < birth.month ||
      (now.month == birth.month && now.day < birth.day)) {
    age--;
  }
  return age;
}
