import 'package:flutter/material.dart';

import 'biometrics.dart';
import 'catalog_screen.dart';
import 'friends.dart';
import 'identity_gateway.dart';
import 'main.dart' show IdentityScreen;
import 'notifications.dart';
import 'runpass_theme.dart';

/// Configuracoes da conta (engrenagem do Perfil): privacidade, avisos, sair e excluir conta.
class SettingsScreen extends StatefulWidget {
  final IdentityGateway gateway;
  const SettingsScreen({super.key, required this.gateway});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final Future<Map<String, dynamic>> profile = widget.gateway.request(
    '/me',
  );

  void soon(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  void toSignIn([String? notice, bool autoRestore = true]) =>
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(
          builder: (_) => IdentityScreen(
            gateway: widget.gateway,
            notice: notice,
            autoRestore: autoRestore,
          ),
        ),
        (route) => false,
      );

  /// `forget`: encerra de vez neste aparelho (token revogado, biometria e e-mail salvo
  /// apagados); sem ele, com biometria ligada, so tranca a sessao.
  Future<void> signOut({bool forget = false}) async {
    NotificationCenter.instance.stop();
    if (forget) await SavedAccount.clear();
    if (!forget &&
        await BiometricPrefs.enabled() &&
        await widget.gateway.hasStoredSession) {
      // Biometria ligada: sai daqui, mas o rosto/digital entra de novo sem a senha.
      await widget.gateway.lockSession();
      if (mounted) {
        toSignIn(
          'Você saiu. Digite seu e-mail e entre com o rosto ou a digital.',
          false,
        );
      }
      return;
    }
    await BiometricPrefs.clear();
    try {
      await widget.gateway.signOut();
    } on Exception {
      // A sessão local já foi encerrada; falha de rede não impede sair.
    }
    if (mounted) toSignIn();
  }

  Future<void> deleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Excluir sua conta?'),
        content: const Text(
          'O acesso será bloqueado imediatamente e a limpeza dos seus dados (perfil, participações, avaliações e fotos) será agendada. Isso não pode ser desfeito.',
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
    try {
      await widget.gateway.request('/me', method: 'DELETE');
    } on IdentityIssue catch (issue) {
      if (mounted) soon(catalogError(issue));
      return;
    }
    NotificationCenter.instance.stop();
    await BiometricPrefs.clear();
    await SavedAccount.clear();
    await widget.gateway.forgetSession();
    if (mounted) {
      toSignIn('Exclusão aceita. O acesso à conta foi encerrado.');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Configurações')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: FutureBuilder<Map<String, dynamic>>(
            future: profile,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return const ListTile(
                  key: Key('settings-error'),
                  leading: Icon(Icons.lock_outline),
                  title: Text('Perfil privado'),
                  subtitle: Text(
                    'Não foi possível carregar agora. Volte e abra de novo.',
                  ),
                );
              }
              if (!snapshot.hasData) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              return PrivacyTile(
                gateway: widget.gateway,
                profile: snapshot.data!,
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        const Card(child: BiometricSwitch()),
        const SizedBox(height: 12),
        const Card(child: OsAlertsSwitch()),
        const SizedBox(height: 12),
        Card(
          child: ValueListenableBuilder<bool>(
            valueListenable: ThemeController.dark,
            builder: (context, dark, _) => SwitchListTile(
              key: const Key('dark-mode-switch'),
              secondary: const Icon(Icons.dark_mode_outlined),
              title: const Text('Modo escuro'),
              subtitle: const Text(
                'Fundo escuro em todo o app, mais confortável à noite e em lugares com pouca luz.',
              ),
              value: dark,
              onChanged: ThemeController.set,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Column(
            children: [
              ListTile(
                key: const Key('sign-out'),
                leading: const Icon(Icons.logout_rounded),
                title: const Text('Sair'),
                subtitle: const Text('Encerra a sessão neste aparelho.'),
                onTap: signOut,
              ),
              const Divider(height: 1),
              ListTile(
                key: const Key('sign-out-forget'),
                leading: const Icon(Icons.phonelink_erase_rounded),
                title: const Text('Sair e esquecer este aparelho'),
                subtitle: const Text(
                  'Revoga o acesso, apaga o e-mail salvo e desliga a entrada por rosto ou digital. Use ao emprestar ou vender o celular.',
                ),
                onTap: () => signOut(forget: true),
              ),
              const Divider(height: 1),
              ListTile(
                key: const Key('delete-account'),
                leading: const Icon(
                  Icons.delete_forever_outlined,
                  color: Colors.red,
                ),
                title: const Text(
                  'Excluir minha conta',
                  style: TextStyle(color: Colors.red),
                ),
                subtitle: const Text(
                  'Bloqueia o acesso na hora e agenda a limpeza dos seus dados.',
                ),
                onTap: deleteAccount,
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// "Entrar com biometria": so aparece se o aparelho tem biometria cadastrada.
class BiometricSwitch extends StatefulWidget {
  const BiometricSwitch({super.key});

  @override
  State<BiometricSwitch> createState() => _BiometricSwitchState();
}

class _BiometricSwitchState extends State<BiometricSwitch> {
  bool? available;
  bool value = false;

  @override
  void initState() {
    super.initState();
    Future.wait([biometricGate.available(), BiometricPrefs.enabled()])
        .then((r) {
          if (mounted) {
            setState(() {
              available = r[0];
              value = r[1];
            });
          }
        });
  }

  Future<void> change(bool next) async {
    if (next &&
        !await biometricGate.authenticate('Confirme para ativar a biometria')) {
      return;
    }
    await BiometricPrefs.setEnabled(next);
    if (mounted) setState(() => value = next);
  }

  @override
  Widget build(BuildContext context) => available == true
      ? SwitchListTile(
          key: const Key('biometric-switch'),
          secondary: const Icon(Icons.fingerprint),
          title: const Text('Entrar com biometria'),
          subtitle: const Text(
            'Use o rosto ou a digital do aparelho ao abrir o app, em vez da senha.',
          ),
          value: value,
          onChanged: change,
        )
      : const SizedBox.shrink(key: Key('biometric-unavailable'));
}
