import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'identity_gateway.dart';
import 'my_races.dart' show SignedPhoto;
import 'runpass_theme.dart';

/// Letra do genero para a ficha ('F'/'M'); 'undisclosed' e sem genero nao aparecem.
String? genderLetter(String? gender) => switch (gender) {
  'female' => 'F',
  'male' => 'M',
  _ => null,
};

/// Faixa etaria em intervalos de 5 anos (mesma regra do protótipo), cobrindo todas as idades.
String? ageBucket(DateTime? birthDate) {
  if (birthDate == null) return null;
  final now = DateTime.now();
  var age = now.year - birthDate.year;
  if (now.month < birthDate.month ||
      (now.month == birthDate.month && now.day < birthDate.day)) {
    age -= 1;
  }
  if (age < 18) return 'Menor de 18';
  if (age < 80) {
    final start = (age ~/ 5) * 5;
    return '$start-${start + 4}';
  }
  return '80+';
}

String _pad2(int n) => n.toString().padLeft(2, '0');

String formatBirthLabel(DateTime? birthDate) {
  if (birthDate == null) return '';
  return '${_pad2(birthDate.day)}/${_pad2(birthDate.month)}/${birthDate.year}';
}

/// Barra de progresso de 4 segmentos do cadastro (passo atual em laranja).
class RegistrationProgress extends StatelessWidget {
  final int step;
  const RegistrationProgress({super.key, required this.step});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      for (var i = 1; i <= 4; i++) ...[
        if (i > 1) const SizedBox(width: 7),
        Expanded(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            height: 6,
            decoration: BoxDecoration(
              color: i <= step ? runPassOrange : context.track,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ),
      ],
    ],
  );
}

/// Ficha de inscrição do corredor: se preenche conforme os dados chegam, nos passos do
/// cadastro, e aparece completa na celebração final.
class RegistrationCard extends StatelessWidget {
  final String? displayName;
  final String? username;
  final String? cityLabel;
  final DateTime? birthDate;
  final String? gender;
  final String? registrationCode;
  final Uint8List? photo;
  // Quando `photo` (so em memoria) ainda nao foi escolhido nesta sessao mas
  // a foto ja esta confirmada no servidor, busca pelo mesmo canal que o
  // resto do app usa (`SignedPhoto`) em vez de ficar sem foto — sem isso, a
  // ficha da celebracao perdia a foto ao fechar o app depois do envio mas
  // antes de "Começar minha jornada" (bug real, reportado em 24/11/2026).
  final IdentityGateway? gateway;
  final String? accountId;
  final bool hasServerPhoto;
  final DateTime inscriptionDate;
  // So preenchidos na celebracao: tocar no bloco volta para o passo que o edita.
  final VoidCallback? onTapPhoto;
  final VoidCallback? onTapProfile;
  final VoidCallback? onTapBirth;
  final VoidCallback? onTapCity;
  const RegistrationCard({
    super.key,
    this.displayName,
    this.username,
    this.cityLabel,
    this.birthDate,
    this.gender,
    this.registrationCode,
    this.photo,
    this.gateway,
    this.accountId,
    this.hasServerPhoto = false,
    required this.inscriptionDate,
    this.onTapPhoto,
    this.onTapProfile,
    this.onTapBirth,
    this.onTapCity,
  });

  static const _monthAbbr = [
    'JAN',
    'FEV',
    'MAR',
    'ABR',
    'MAI',
    'JUN',
    'JUL',
    'AGO',
    'SET',
    'OUT',
    'NOV',
    'DEZ',
  ];

  @override
  Widget build(BuildContext context) {
    final name = displayName?.trim();
    final hasName = name != null && name.isNotEmpty;
    final letter = genderLetter(gender);
    final bucket = ageBucket(birthDate);
    // Formato do prototipo aprovado: letra e faixa etaria juntas, so com espaco
    // ("M 35-39"), sem traco entre elas.
    final category = [?letter, ?bucket].join(' ');
    final initials = hasName
        ? name
              .split(RegExp(r'\s+'))
              .take(2)
              .map((w) => w[0].toUpperCase())
              .join()
        : '';
    final dateText =
        '${inscriptionDate.day.toString().padLeft(2, '0')} '
        '${_monthAbbr[inscriptionDate.month - 1]} ${inscriptionDate.year}';

    Widget tappable(Widget child, VoidCallback? onTap, {Key? key}) =>
        onTap == null
        ? child
        : InkWell(
            key: key,
            onTap: onTap,
            borderRadius: BorderRadius.circular(14),
            child: child,
          );

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .1),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 128,
              padding: const EdgeInsets.symmetric(vertical: 24),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [runPassOrange, runPassGold],
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  tappable(
                    () {
                      final placeholder = initials.isNotEmpty
                          ? Text(
                              initials,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                                fontSize: 20,
                              ),
                            )
                          : const Icon(
                              Icons.person_outline,
                              color: Colors.white,
                            );
                      final networkFallback =
                          photo == null &&
                          hasServerPhoto &&
                          gateway != null &&
                          accountId != null;
                      return CircleAvatar(
                        radius: 30,
                        backgroundColor: Colors.white.withValues(alpha: .2),
                        backgroundImage: photo == null
                            ? null
                            : MemoryImage(photo!),
                        child: photo != null
                            ? null
                            : (networkFallback
                                  ? ClipOval(
                                      child: SizedBox(
                                        width: 60,
                                        height: 60,
                                        child: SignedPhoto(
                                          gateway: gateway!,
                                          endpoint:
                                              '/profiles/${Uri.encodeComponent(accountId!)}/photo',
                                          fallback: Center(
                                            child: placeholder,
                                          ),
                                        ),
                                      ),
                                    )
                                  : placeholder),
                      );
                    }(),
                    onTapPhoto,
                    key: const Key('registration-card-photo'),
                  ),
                  Column(
                    children: [
                      const Text(
                        'Nº INSCRIÇÃO',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: .5,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        registrationCode ?? '00000',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 23,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 20, 16, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Opacity(
                          opacity: .7,
                          child: Image.asset(
                            context.isDark
                                ? 'assets/brand/logo-dark.png'
                                : 'assets/brand/logo-light.png',
                            height: 20,
                            fit: BoxFit.contain,
                          ),
                        ),
                        // Expanded (em vez de Spacer + Flexible competindo pelo mesmo
                        // espaco em partes iguais): a data/cidade ganha todo o espaco que
                        // sobrar do logo, nao so a metade, pra nao cortar cidades com nome
                        // longo. O Align mantem o bloco encostado na direita.
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: tappable(
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    dateText,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      color: context.muted,
                                    ),
                                  ),
                                  Text(
                                    (cityLabel ?? '— cidade').toUpperCase(),
                                    // Duas linhas em vez de uma: cidade e estado com nome
                                    // longo quebram a linha em vez de cortar com "...".
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.right,
                                    style: const TextStyle(
                                      fontSize: 7,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: .3,
                                    ),
                                  ),
                                ],
                              ),
                              onTapCity,
                              key: const Key('registration-card-city'),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    tappable(
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            hasName ? name : 'Seu nome aqui',
                            maxLines: 2,
                            overflow: TextOverflow.visible,
                            style: TextStyle(
                              fontSize: 21,
                              fontWeight: FontWeight.w800,
                              color: hasName ? null : context.muted,
                            ),
                          ),
                          Text(
                            username != null && username!.isNotEmpty
                                ? '@$username'
                                : '@usuario',
                            style: TextStyle(
                              fontSize: 10,
                              color: context.muted,
                            ),
                          ),
                        ],
                      ),
                      onTapProfile,
                      key: const Key('registration-card-profile'),
                    ),
                    const SizedBox(height: 10),
                    tappable(
                      Row(
                        // Sem isso, a categoria (1 linha) ficava centralizada no
                        // cruzamento com o bloco "NASCIMENTO" (2 linhas) em vez de
                        // alinhada com a linha da data de nascimento.
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(
                            flex: 3,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'NASCIMENTO',
                                  style: TextStyle(
                                    fontSize: 8.5,
                                    fontWeight: FontWeight.w800,
                                    color: context.archivedText,
                                  ),
                                ),
                                Text(
                                  birthDate == null
                                      ? '—'
                                      : formatBirthLabel(birthDate),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: Text(
                              category.isEmpty ? '—' : category,
                              textAlign: TextAlign.right,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                      onTapBirth,
                      key: const Key('registration-card-birth'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
