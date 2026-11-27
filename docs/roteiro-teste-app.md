# Roteiro de testes do app (DEV) e coleta de feedback

Para Thiago (iPhone) e Rafael Moura (Android). Versão do app: branch `dev` do repositório, commit `e3e5dda` ou mais novo (05/11/2026). Dados de teste, ambiente DEV, nada aqui é produção.

**Objetivo.** Validar as telas e os fluxos em aparelho real e trazer um feedback objetivo do que funciona, do que está quebrado e do que falta. **Tempo estimado:** 45 a 60 minutos.

**Regra de ouro.** Anote o que **viu**, não o que supôs. Quando algo falhar, anote a **mensagem exata**, a **hora aproximada** (eu cruzo com os logs da AWS) e tire um print.

---

## 1. Antes de começar

### 1.1 Divisão
| Pessoa | Aparelho | O que faz |
| --- | --- | --- |
| Thiago | iPhone 17 | Seção 2 (instalar) e todos os casos da seção 4; casos marcados **iOS** |
| Rafael | Android | Seção 3 (instalar) e todos os casos da seção 4; casos marcados **Android** |

Cada um usa **uma conta de teste própria** (e-mail real, para receber o código de confirmação). Os dois dividem o mesmo catálogo de corridas sintéticas, e cada conta tem os seus registros.

### 1.2 Corridas de teste e datas
| Corrida | Data | Serve para |
| --- | --- | --- |
| Corrida Sintética São Paulo 2024 | 10/11/2024 | Jornada completa (passada) |
| Corrida Sintética São Paulo 2025 | 09/11/2025 | Jornada completa (passada) |
| Desafio Sintético da Orla (RJ 2026) | 20/09/2026 | Jornada completa (passada) |
| Corrida Sintética São Paulo 2026 | **08/11/2026** | **Corrida futura** (rascunho, sem conclusão). Depois de 08/11 ela vira passada e dá para concluir |
| Prova Sintética Arquivada | 18/05/2025 | Edição arquivada (cinza, sem registro). Motivo esperado: "corrida cancelada pela organização" |

### 1.3 Já sabemos que **não existe** (não precisa reportar de novo)
Estas lacunas estão no backend ou no escopo; reporte só se **o comportamento for diferente** do descrito.
- **A foto enviada não aparece em lugar nenhum.** Ela é guardada, mas a API não tem rota para exibir a imagem. Medalhas e Início mostram uma arte desenhada.
- **Avaliações de outros corredores, lista de participantes e aba Fotos:** a aba Avaliações mostra a **sua** avaliação, a nota geral e uma mensagem de indisponível; Participantes e Fotos dizem "em breve".
- **Início como feed de verdade:** só aparecem as **suas** corridas e rascunhos. Curtir, comentar e compartilhar dizem "em breve".
- "Quero correr" (coração), compartilhar, Avisos (sino), Configurações, foto de perfil, Passaporte e "Ver todas": "em breve".
- **Foto de câmera:** o app só abre a **galeria**.
- **Corridas desejadas** (wishlist) e stories: não existem no backend real.
- **Sair e Excluir minha conta** ficam no **Perfil**, no fim da tela, a partir do PR que os adiciona ("Sair e Excluir minha conta no Perfil"); nas versões anteriores eles só existiam na tela "Olá, <nome>!", antes do Início. Confirme no teste onde aparecem.

### 1.4 Verifique se o DEV está de pé (opcional, Thiago)
```sh
cd ~/dev/RunPass-Projeto-X
export AWS_PROFILE=runpass-dev-sa SSL_CERT_FILE=/etc/ssl/cert.pem
aws login --profile runpass-dev-sa   # só se a sessão tiver expirado
```

---

## 2. Instalar no iPhone (Thiago)

1. iPhone com **Modo Desenvolvedor** ligado (Ajustes → Privacidade e Segurança), cabo ao Mac, desbloqueado e "Confiar".
2. Xcode com o seu Apple ID e o **Team** escolhido em `mobile/ios/Runner.xcworkspace` (Signing & Capabilities). Não commite essa mudança.
3. No terminal:
   ```sh
   cd ~/dev/RunPass-Projeto-X
   git checkout dev && git pull runpass dev
   export AWS_PROFILE=runpass-dev-sa SSL_CERT_FILE=/etc/ssl/cert.pem
   scripts/run-device-dev.sh 00008150-000670193E7B401C
   ```
   O id é o do seu iPhone (`flutter devices` confirma). Se o `git pull` reclamar do arquivo do Xcode, rode antes `git stash` e depois `git stash pop`.
4. Primeira vez: no iPhone, **Ajustes → Geral → VPN e Gerenciamento de Dispositivo → seu Apple ID → Confiar**. A instalação gratuita vale 7 dias.

## 3. Instalar no Android (Rafael)

Há dois caminhos. O **A** é o mais simples e não exige instalar nada de desenvolvimento.

### Caminho A: instalar um APK pronto (recomendado)
O Thiago gera o APK e envia a você por mensagem ou Drive. Ele contém o endereço do ambiente de teste, então **não publique o arquivo**.
1. No Android, ative **Instalar apps desconhecidos** para o app que vai abrir o arquivo (Drive, Arquivos ou o navegador): Configurações → Apps → *esse app* → Instalar apps desconhecidos.
2. Baixe o `app-release.apk` e toque nele. Se o **Play Protect** avisar que o app não foi verificado, escolha **Instalar mesmo assim** (o app está assinado com chave de teste).
3. Abra o **RunPass**.
4. Para atualizar para uma versão nova, instale o APK novo por cima. Os dados da conta continuam no servidor.

### Caminho B: compilar e instalar pelo computador
Requisitos: Git, **Flutter 3.47** (`flutter --version`, mesma versão do Thiago), **Android Studio** (SDK e platform-tools), **AWS CLI 2.32+** e o seu usuário IAM com MFA.
1. **Aparelho:** Configurações → Sobre o telefone → toque 7 vezes em **Número da versão**. Depois Configurações → Opções do desenvolvedor → ligue **Depuração USB**. Conecte o cabo, escolha **Transferência de arquivos** e aceite a janela "Permitir depuração USB".
2. Confirme que o computador o enxerga:
   ```sh
   flutter doctor            # Android toolchain com ✓ (aceite as licenças: flutter doctor --android-licenses)
   flutter devices           # copie o id do aparelho
   ```
3. Clone e entre no repositório e use o **seu** perfil AWS:
   ```sh
   git clone https://github.com/Runpass/RunPass-Projeto-X.git && cd RunPass-Projeto-X
   git checkout dev && git pull
   aws login --profile runpass-dev-rafael      # use o nome do seu perfil e entre com o MFA
   export AWS_PROFILE=runpass-dev-rafael
   scripts/run-device-dev.sh <id-do-aparelho>
   ```
   O script lê a URL da API e o client do Cognito das saídas das stacks (precisa de permissão `cloudformation:DescribeStacks`, que a política de operador já dá). Em **Windows**, rode pelo Git Bash ou WSL, ou use o Caminho A.
4. Se a compilação falhar, anote a mensagem exata e mande para o Thiago.

---

## 4. Casos de teste

Marque cada linha com **OK**, **Falha** ou **Parcial** e escreva a observação. "Esperado" é o que o app deve fazer hoje.

### A. Conta e entrada
| ID | Passos | Esperado | Resultado | Observação |
| --- | --- | --- | --- | --- |
| A1 | **Criar conta** com e-mail seu e senha fraca (ex.: `abc123`) | Mensagem explicando a regra: 12+ caracteres com maiúscula, minúscula, número e símbolo | | |
| A2 | Criar conta com senha forte | Pede o **código de confirmação** enviado ao e-mail (olhe o spam) | | |
| A3 | Digitar o código errado, depois o certo | Erro claro no errado; segue no certo. Teste **Reenviar código** | | |
| A4 | Entrar com a conta criada | Vai ao perfil de corredor ou à admissão do beta | | |
| A5 | Preencher o perfil (nome e `@usuário`). Repetir com um `@usuário` já usado por outra conta | Aceita o primeiro; no repetido diz que o nome já está em uso | | |
| A6 | Admissão ao beta (data de nascimento e declaração de maioridade) | Admite a conta e mostra "Olá, <nome>!" | | |
| A7 | **Esqueci minha senha** com o seu e-mail | Envia código e permite definir senha nova | | |
| A8 | Tocar em **Entrar no RunPass** | Abre o **Início** | | |

### B. Início
| ID | Passos | Esperado | Resultado | Observação |
| --- | --- | --- | --- | --- |
| B1 | Abrir o Início com conta nova (sem corridas) | Boas-vindas e botão "Encontrar corridas" | | |
| B2 | Voltar ao Início depois de criar um rascunho | O rascunho aparece sem precisar rolar a tela | | |
| B3 | Rascunho de corrida **passada** | Fica em "Rascunhos em andamento", com lixeira | | |
| B4 | Rascunho da corrida **SP 2026** (futura) | Fica em "Minhas corridas futuras", com a data | | |
| B5 | Tocar no rascunho / tocar na lixeira | Abre o rascunho / pede confirmação e exclui | | |
| B6 | Corrida **concluída** | Aparece como cartão "concluiu <corrida>" com medalha desenhada | | |
| B7 | Filtros (Todos, Amigos, Minha rede, São Paulo, Trilhas) | Todos e Minha rede mostram as suas; os demais, vazio ou conforme o filtro. Anote o que parecer errado | | |
| B8 | Puxar para atualizar | Recarrega sem erro | | |

### C. Corridas (busca)
| ID | Passos | Esperado | Resultado | Observação |
| --- | --- | --- | --- | --- |
| C1 | Abrir **Corridas** | Lista com as 5 corridas sintéticas | | |
| C2 | Filtrar por nome, cidade, UF, distância e data; **Limpar busca** | Resultados conforme o filtro; limpar volta à lista completa | | |
| C3 | Filtro inválido (data errada) | Mensagem diz qual campo está errado | | |
| C4 | A **arquivada** na lista | Cartão cinza com "Arquivada: corrida cancelada pela organização" | | |
| C5 | Corrida em que você já tem registro | Ícone de confirmação e "Já está na sua lista" | | |
| C6 | Tocar em **qualquer** corrida, inclusive as que já são suas | Abre a **página da corrida** | | |

### D. Página da corrida
| ID | Passos | Esperado | Resultado | Observação |
| --- | --- | --- | --- | --- |
| D1 | Ver as abas Sobre, Avaliações, Fotos, Participantes | Navega entre elas sem travar; Fotos e Participantes dizem "em breve" | | |
| D2 | Escolher uma distância | A distância fica destacada | | |
| D3 | Tocar em **Criar rascunho** (corrida passada ou SP 2026) | Abre o rascunho com a mensagem "Rascunho criado..." | | |
| D4 | Voltar e abrir a mesma corrida | Mostra "Esta corrida está na sua lista" e o botão **Editar meu rascunho** | | |
| D5 | A **arquivada**: tentar escolher distância | Seletor cinza e bloqueado, com o motivo escrito | | |
| D6 | Barra de baixo: tocar em **Corridas** de dentro do rascunho | Volta à lista de corridas | | |

### E. Rascunho: meus dados
| ID | Passos | Esperado | Resultado | Observação |
| --- | --- | --- | --- | --- |
| E1 | Digitar **tempo** `1:30:00`, colocação e número de peito; **Salvar rascunho** | Mensagem "Rascunho salvo. Nada foi publicado." logo abaixo do título | | |
| E2 | Tempo inválido (`1:75:00`) ou colocação `0` | Mensagem explica o formato aceito | | |
| E3 | Trocar a **distância** no rascunho e salvar | Salva a nova distância | | |
| E4 | **Teclado:** tocar fora do campo e arrastar a lista | O teclado fecha (**iOS:** o teclado numérico não tem tecla de fim) | | |
| E5 | Corrida **futura** (SP 2026) | Aviso com a data; **sem** botão de foto, avaliação nem conclusão | | |
| E6 | **Excluir rascunho** | Pede confirmação e remove; depois é possível criar outro | | |

### F. Foto
| ID | Passos | Esperado | Resultado | Observação |
| --- | --- | --- | --- | --- |
| F1 | **Selecionar foto** da galeria (JPEG) | "Imagem validada para uso na conclusão." Anote o **tempo** (meta: até 5 s) | | |
| F2 | Foto **PNG** (captura de tela) | Também é validada | | |
| F3 | **iOS:** foto tirada pelo iPhone (HEIC) | O iOS entrega JPEG e valida | | |
| F4 | **Android:** foto da câmera salva na galeria, e uma grande (acima de 10 MB, se tiver) | Valida; a grande dá a mensagem de limite de 10 MB | | |
| F5 | Cancelar a escolha na galeria | Nada muda, sem erro | | |
| F6 | Ativar o **modo avião** e tentar enviar | Mensagem diz que é conexão ou serviço e que o rascunho foi preservado | | |
| F7 | Sair e voltar ao mesmo rascunho **sem fechar o app** | A foto validada e as notas continuam lá | | |

### G. Conclusão e avaliação
| ID | Passos | Esperado | Resultado | Observação |
| --- | --- | --- | --- | --- |
| G1 | Com foto validada, dar notas por **estrelas** nos 8 critérios e um comentário | Cada critério tem ícone e 5 estrelas | | |
| G2 | Tentar concluir **sem marcar** "Declaro que concluí" | Mensagem diz o que falta | | |
| G3 | **Concluir participação** | Confirmação e vai para **Medalhas** | | |
| G4 | Tentar concluir uma corrida **futura** | Não oferece (E5) | | |

### H. Medalhas
| ID | Passos | Esperado | Resultado | Observação |
| --- | --- | --- | --- | --- |
| H1 | Abrir **Medalhas** | A medalha da corrida concluída aparece | | |
| H2 | Tocar numa medalha | Abre a participação concluída | | |
| H3 | Na participação concluída | Mostra o cartão **Minha avaliação** (8 critérios com estrelas e comentário) | | |

### I. Participação concluída: editar
| ID | Passos | Esperado | Resultado | Observação |
| --- | --- | --- | --- | --- |
| I1 | Em "Meus dados desta corrida": mudar **distância**, **tempo**, colocação, número; **Salvar dados da corrida** | Mensagem "Dados da corrida salvos." | | |
| I2 | **Editar avaliação**: mudar estrelas e comentário, salvar; voltar | O cartão "Minha avaliação" mostra os novos valores | | |
| I3 | Alternar **Exibir meu tempo** / **Exibir minha colocação** e **Salvar visibilidade** | A tela fica no lugar e mostra a confirmação | | |
| I4 | Aba **Avaliações** da página da mesma corrida | Mostra **Minha avaliação** acima da nota geral | | |

### J. Perfil
| ID | Passos | Esperado | Resultado | Observação |
| --- | --- | --- | --- | --- |
| J1 | Abrir **Perfil** | Seu nome, `@usuário` e estatísticas das corridas concluídas | | |
| J2 | Itens "em breve" (Configurações, foto, Passaporte) | Mensagem de "em breve", sem erro | | |
| J3 | No fim do Perfil: **Sair** e depois **Excluir minha conta** (com uma conta que você pode perder) | Sair volta à tela de entrada e pede login; Excluir pede confirmação, bloqueia o acesso e volta à entrada com o aviso "Exclusão aceita" | | |

### K. Exclusão
| ID | Passos | Esperado | Resultado | Observação |
| --- | --- | --- | --- | --- |
| K1 | **Excluir participação** concluída | Confirmação, depois "A participação foi ocultada..." | | |
| K2 | Excluir a **conta** (Perfil, fim da tela) e tentar entrar de novo com ela | O acesso é bloqueado na hora; em até uns 5 minutos os dados são apagados e a conta deixa de existir | | |

### L. Resiliência e navegação
| ID | Passos | Esperado | Resultado | Observação |
| --- | --- | --- | --- | --- |
| L1 | Abrir o app **sem internet** | Mensagem diz que é falta de conexão, sem travar | | |
| L2 | **Android:** botão voltar do sistema em cada tela | Volta uma tela por vez, sem fechar o app de repente | | |
| L3 | **Android:** girar o aparelho com formulário aberto | Não perde o que foi digitado, ou anote o que perde | | |
| L4 | Fechar o app e reabrir | Pede login de novo (o token não é guardado) | | |
| L5 | Barra de baixo: Início, Corridas, Medalhas, Perfil, em qualquer tela | Sempre leva à tela principal da aba | | |
| L6 | Textos longos e telas pequenas | Nada cortado ou sobreposto | | |

---

## 5. Feedback

### 5.1 Cada problema encontrado (copie este bloco)
```
ID do caso:      (ex.: F1)
Aparelho / SO:   (ex.: iPhone 17 / iOS 27.0.1, ou Android modelo / versão)
Versão do app:   (commit ou data da instalação)
Hora aproximada: (ex.: 21h37)
O que fiz:       (passos)
O que esperava:
O que aconteceu: (mensagem exata)
Gravidade:       Bloqueia a jornada / Atrapalha / Cosmético
Print:           (anexe)
```

### 5.2 O que está faltando (preencha ao final)
| Pergunta | Resposta |
| --- | --- |
| Qual foi o **passo mais confuso** do app? | |
| Onde você **ficou sem saber o que fazer** a seguir? | |
| Que **informação** esperava ver e não viu? (ex.: foto da medalha, avaliações dos outros, lista de participantes) | |
| Que **botão ou ação** esperava e não existia? | |
| Alguma **mensagem de erro vaga** que não explicou o motivo? | |
| O app ficou **lento** em algum ponto? Onde e quanto? | |
| Algo que **funcionou bem** e deve ser mantido? | |
| Em uma frase: você **usaria isso** hoje? O que impediria? | |

### 5.3 Como entregar
Envie o preenchimento (este arquivo copiado, ou um e-mail com as tabelas), os prints e os problemas no formato 5.1 para o Thiago. Ele consolida os dois aparelhos, e eu cruzo as horas anotadas com os logs e os dados do DEV para achar a causa de cada falha.

## 6. Depois do teste
- **As contas de teste ficam no DEV** com os seus dados (e-mail, resultados, fotos). Peça para **apagarmos** as contas e as fotos ao terminar, em vez de deixá-las. Se você não achou a exclusão de conta no app (J3), a limpeza é feita por quem administra o ambiente.
- Não compartilhe prints com e-mail, senha ou código de confirmação visíveis fora do grupo.
