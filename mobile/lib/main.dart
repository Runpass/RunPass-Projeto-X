import 'package:flutter/material.dart';

import 'identity_gateway.dart';
import 'catalog_screen.dart';
import 'runpass_theme.dart';

void main() {
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
      );
    } on ArgumentError {
      gateway = null;
    }
  }
  runApp(MainApp(gateway: gateway));
}

class MainApp extends StatelessWidget {
  final IdentityGateway? gateway;
  final bool demonstration;
  const MainApp({super.key, this.gateway, this.demonstration = false});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'RunPass',
    builder: (context, child) => !demonstration
        ? child!
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
              Expanded(child: child!),
            ],
          ),
    theme: runPassTheme(),
    home: IdentityScreen(gateway: gateway),
  );
}

enum Step {
  signIn,
  signUp,
  confirm,
  forgot,
  reset,
  profile,
  admission,
  ready,
  waiting,
  closed,
}

class IdentityScreen extends StatefulWidget {
  final IdentityGateway? gateway;
  const IdentityScreen({super.key, this.gateway});
  @override
  State<IdentityScreen> createState() => _IdentityScreenState();
}

class _IdentityScreenState extends State<IdentityScreen> {
  final email = TextEditingController();
  final password = TextEditingController();
  final code = TextEditingController();
  final name = TextEditingController();
  final username = TextEditingController();
  final birth = TextEditingController();
  final form = GlobalKey<FormState>();
  Step step = Step.signIn;
  bool busy = false, adult = false, full = false;
  String? message;
  String? displayName;

  @override
  void dispose() {
    for (final field in [email, password, code, name, username, birth]) {
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
  }

  Future<void> resume() async {
    try {
      final profile = await widget.gateway!.request('/me');
      displayName = profile['displayName'] as String?;
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
        'InvalidPasswordException' => 'Use ao menos 12 caracteres, com maiúscula, minúscula, número e símbolo.',
        'CodeMismatchException' || 'ExpiredCodeException' =>
          'Confira o código recebido ou solicite outro.',
        'NOT_ELIGIBLE' =>
          'O beta é destinado a pessoas com 18 anos completos ou mais.',
        'BETA_FULL' => 'As vagas do beta foram preenchidas. Você pode entrar na lista de espera.',
        'ACCOUNT_UNAVAILABLE' => 'Esta conta está indisponível.',
        'INVALID_INPUT' => 'Confira os campos e tente novamente.',
        _ => 'Não foi possível concluir. Seus dados continuam nesta tela; tente novamente.',
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
  }

  Future<void> submit() => perform(() async {
    final gateway = widget.gateway!;
    switch (step) {
      case Step.signIn:
        await gateway.signIn(email.text.trim(), password.text);
        password.clear();
        await resume();
      case Step.signUp:
        await gateway.signUp(email.text.trim(), password.text);
        password.clear();
        step = Step.confirm;
      case Step.confirm:
        await gateway.confirm(email.text.trim(), code.text.trim());
        code.clear();
        step = Step.signIn;
        message = 'E-mail confirmado. Entre na sua conta.';
      case Step.forgot:
        await gateway.forgot(email.text.trim());
        step = Step.reset;
      case Step.reset:
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
        await status();
      case Step.admission:
        if (!adult) {
          message = 'Confirme que tem 18 anos completos ou mais.';
          return;
        }
        await gateway.request(
          full ? '/beta/waitlist' : '/beta/admissions',
          method: 'POST',
          body: {'birthDate': birth.text, 'declaresAdult': adult},
        );
        birth.clear();
        await status();
      case Step.ready || Step.waiting || Step.closed:
        break;
    }
  }, validate: true);

  Future<void> deleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Excluir sua conta?'),
        content: const Text(
          'O acesso será bloqueado imediatamente e a limpeza dos seus dados será agendada.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Excluir minha conta'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await perform(() async {
      await widget.gateway!.request('/me', method: 'DELETE');
      widget.gateway!.clearSession();
      step = Step.signIn;
      message = 'Exclusão aceita. O acesso à conta foi encerrado.';
    });
  }

  Widget field(
    TextEditingController controller,
    String label, {
    bool secret = false,
    int? maxLength,
    String? Function(String)? check,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextFormField(
      controller: controller,
      decoration: InputDecoration(labelText: label),
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
      Step.forgot,
      Step.reset,
    ].contains(step);
    final title = switch (step) {
      Step.signIn => 'Entre no RunPass',
      Step.signUp => 'Crie sua conta',
      Step.confirm => 'Confirme seu e-mail',
      Step.forgot => 'Recupere sua senha',
      Step.reset => 'Defina uma nova senha',
      Step.profile => 'Seu perfil de corredor',
      Step.admission => full ? 'Lista de espera' : 'Participe do beta',
      Step.ready => 'Olá, ${displayName ?? 'corredor'}!',
      Step.waiting => 'Você está na lista de espera',
      Step.closed => 'As admissões do beta foram encerradas',
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
                                  color: runPassNavy,
                                ),
                          ),
                          const SizedBox(height: 24),
                          if (initial) field(email, 'E-mail'),
                          if ([
                            Step.signIn,
                            Step.signUp,
                            Step.reset,
                          ].contains(step))
                            field(password, 'Senha', secret: true),
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
                                  : 'Beta gratuito para maiores de 18 anos.',
                            ),
                            field(
                              birth,
                              'Data de nascimento (AAAA-MM-DD)',
                              check: (value) =>
                                  RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)
                                  ? null
                                  : 'Informe no formato AAAA-MM-DD.',
                            ),
                            const Text('Sua data de nascimento é privada.'),
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
                          if (step == Step.ready)
                            const Text(
                              'Sua participação no beta está confirmada.',
                            ),
                          if (step == Step.ready)
                            FilledButton(
                              onPressed: busy
                                  ? null
                                  : () => Navigator.of(context).pushReplacement(
                                      MaterialPageRoute<void>(
                                        builder: (_) =>
                                            RunPassHomeScreen(gateway: gateway),
                                      ),
                                    ),
                              child: const Text('Entrar no RunPass'),
                            ),
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
                                    : 'Continuar',
                              ),
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
                          if (gateway.signedIn)
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
                          if (gateway.signedIn && step == Step.ready)
                            TextButton(
                              onPressed: busy ? null : deleteAccount,
                              child: const Text('Excluir minha conta'),
                            ),
                          if (initial && step != Step.signIn)
                            TextButton(
                              onPressed: busy
                                  ? null
                                  : () => change(Step.signIn),
                              child: const Text('Voltar para entrar'),
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
