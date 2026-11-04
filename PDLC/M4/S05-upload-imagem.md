# S05 — Upload e imagem validada

Data: 29/10/2026. Estado: **em execução**. Dependências locais S02 e S04 disponíveis; integração AWS permanece condicionada ao S09 e à autorização de custo.

## Backend local entregue

O corredor admitido pode iniciar uma sessão privada para JPEG ou PNG de até 10 MB. A autorização dura 15 minutos e a finalização fixa a versão efetivamente observada do objeto antes do processamento. Repetições usam a mesma operação idempotente e uma gravação posterior pela URL ainda válida não substitui a versão já fixada.

A consulta de estado e a finalização são exclusivas do titular. A titularidade é verificada antes de consultar metadados do blob, evitando usar um identificador opaco como autorização. A finalização rejeita ausência do objeto, tamanho ou tipo declarado divergente e sessão vencida. Pending nunca é tratado como imagem válida.

O processador decodifica o conteúdo real com Pillow, aceita somente JPEG/PNG coerente com a declaração, limita a 25 milhões de pixels, aplica a orientação EXIF, remove metadados no derivado e tenta reduzir o resultado para até 1 MB. Falhas fecham o upload como `failed`; timeout de 15 minutos após a finalização também falha. Apenas o derivado sanitizado recebe referência opaca, privada, com contador inicial de referências zero. O original não é servido.

O adaptador `MemoryBlobStore` é sintético, privado ao processo e versionado para testes. As três rotas canônicas estão ligadas ao harness local: iniciar, finalizar e consultar estado. A composição AWS só habilita uploads quando recebe explicitamente um adaptador de blobs; não há fallback que simule S3 em DEV/produção.

## Evidências

- Seis testes específicos de upload passaram: orientação/remoção de EXIF, versão fixada apesar de sobrescrita, bytes inválidos, divergência de formato/tamanho, expiração, timeout, isolamento entre titulares, admissão/idempotência e limite de pixels.
- A suíte completa passou com 63 testes backend.
- Ruff, formatação e `git diff --check` passaram nos arquivos verificados.
- O harness regenerou o ambiente Bruno `Local` com tokens efêmeros e expõe 18 operações locais. Ele usa dados sintéticos e memória; reiniciar troca tokens e apaga dados.

## Aplicativo local

O rascunho agora oferece seleção pela biblioteca usando o plugin oficial `image_picker`. A solicitação limita dimensões a 5.000 × 5.000, qualidade a 85 e desabilita metadados completos. O cliente inspeciona a assinatura dos bytes resultantes, aceita apenas JPEG/PNG e limita 10 MB antes de iniciar a sessão. Depois envia os bytes com método/cabeçalhos retornados pela API e só então finaliza. Se o processamento continuar pendente, consulta o estado por alguns segundos e mantém uma ação explícita para consultar novamente; `failed` nunca é promovido a imagem válida. Falha, cancelamento, formato incompatível ou timeout preservam os campos do rascunho.

O caminho de demonstração possui transporte binário sintético, sem rede ou armazenamento real. Um teste novo verifica a ordem iniciar → enviar bytes → finalizar, inclusive cabeçalho e URL. A suíte mobile passou com 14 testes e análise estática limpa. A compilação iOS com o plugin foi instalada no simulador e o login reapareceu após relançamento; a primeira captura ocorreu antes do primeiro frame e ficou branca, mas uma repetição automatizada após cinco segundos confirmou conteúdo visível. Isso não comprova a seleção de HEIC no simulador nem em câmera real.

## Pendências para concluir o slice

- Testar no iPhone real se a solicitação de redução do `image_picker` converte HEIC para JPEG; o próprio plugin documenta limitação conhecida do simulador iOS para HEIC. Se os bytes retornados não forem JPEG/PNG, o cliente falha fechado e preserva o rascunho.
- Implementar e testar o adaptador privado S3 com versionamento, URL assinada e políticas IAM apenas quando a integração DEV for autorizada.
- Medir a meta p95 de cinco segundos no cenário de carga do S09; execução síncrona local não é evidência de latência operacional.
- Definir/executar a limpeza de originais abandonados e imagens validadas não vinculadas com rechecagem de referências.

Falha ou timeout de imagem não altera nem remove o rascunho do S04. Nenhuma imagem é vinculada a participação ou publicada neste slice; essa transação pertence ao S06.


## Aceite humano — 03/11/2026

Aceita pelo usuário como aceite local, com as ressalvas registradas em `implementation-slices.md` (seção "Aceite humano de S05, S06 e S08"). Integração real permanece na S09.
