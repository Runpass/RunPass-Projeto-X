"""Relatorio de qualidade da busca do catalogo (medicao manual de 10/11/2026), servido ao portal so-leitura.

Os numeros vem da conferencia feita contra a pagina oficial da prefeitura e contra as fontes que a rotina citou
(documento `MEDICAO-ACERTO.md` do repositorio do catalogo). E uma AMOSTRA de um dia: nao e a meta do PRD e nao
mede a revocacao do enriquecimento. Atualize este arquivo quando houver nova conferencia.
"""

REPORT = {
    "date": "2026-11-10",
    "scope": (
        "Rotina do catalogo em DEV: extracao do calendario da prefeitura e enriquecimento (distancia, local, "
        "inscricao). Amostra de um dia, conferida por uma pessoa."
    ),
    "extraction": {
        "source": "https://prefeitura.sp.gov.br/web/esportes/w/corridas_de_rua/8722",
        "inPage": 48,
        "extracted": 42,
        "matched": 42,
        "notExtracted": [
            {
                "name": "BTG Pactual Bike Series",
                "date": "2026-11-01",
                "reason": "ciclismo",
                "decision": "ok",
            },
            {
                "name": "Passeio Ciclistico Pedala Green",
                "date": "2026-11-29",
                "reason": "ciclismo",
                "decision": "ok",
            },
            {
                "name": "Storm Challenge SP 15a edicao",
                "date": "2026-12-05",
                "reason": "crossfit",
                "decision": "ok",
            },
            {
                "name": "Storm Challenge SP 15a edicao",
                "date": "2026-12-06",
                "reason": "crossfit",
                "decision": "ok",
            },
            {
                "name": "Bike e Running Porto Autodromo",
                "date": "2026-11-15",
                "reason": "tem corrida no nome",
                "decision": "decidir",
            },
            {
                "name": "USP | Distrito de Inovacao de Sao Paulo",
                "date": "2026-11-29",
                "reason": "tipo nao verificado",
                "decision": "decidir",
            },
        ],
    },
    "enrichment": {
        "total": 44,
        "ready": 22,
        "notFound": 18,
        "partial": 4,
        "filled": {
            "distances": 22,
            "venue": 22,
            "organizer": 20,
            "registrationUrl": 7,
            "startTime": 0,
        },
    },
    "spotCheck": [
        {
            "name": "Tricolor Run (06/12)",
            "result": "confere",
            "note": "Data, Morumbi, 5 e 10 km. Fonte em dominio portugues, conteudo de Sao Paulo.",
        },
        {
            "name": "Circuito Caixa Etapa SP",
            "result": "confere",
            "note": "15/11, Parque da Independencia, 5 e 10 km. A URL e /manutencao/, mas o regulamento esta nela.",
        },
        {
            "name": "Disney Magic Run",
            "result": "confere",
            "note": "22/11, Obelisco do Ibirapuera, 8 km. Um FAQ da mesma pagina cita 6 km.",
        },
        {
            "name": "25 Corrida pela Cidadania",
            "result": "confere",
            "note": "13/12, Parque do Povo, 5, 10 e 15 km.",
        },
        {
            "name": "Novembro Diabetes Azul",
            "result": "confere",
            "note": "08/11, Parque CERET, 5 km.",
        },
        {
            "name": "STFRS Vila Olimpia II",
            "result": "parcial",
            "note": "Data e distancias conferem; o local nao foi confirmado pela fonte (listagem so diz Sao Paulo/SP).",
        },
        {
            "name": "Meia de Sampa",
            "result": "nao_verificado",
            "note": "A fonte devolveu HTTP 403 ao acesso automatico.",
        },
        {
            "name": "101 Corrida Internacional de Sao Silvestre",
            "result": "nao_verificado",
            "note": "A fonte devolveu HTTP 403 ao acesso automatico.",
        },
    ],
    "notCovered": [
        "Revocacao do enriquecimento: as 18 provas com 'nada encontrado' nao foram conferidas a mao.",
        "As 14 provas 'prontas' fora da amostra e as 2 nao verificaveis.",
        "A busca por frase livre e os pedidos de usuarios.",
        "Estabilidade: uma unica execucao, um unico dia.",
    ],
    "nextSteps": [
        "Conferir a mao as 18 provas sem informacao (a informacao existe na web?).",
        "Decidir a regra para 'Bike e Running' e eventos de tipo duvidoso.",
        "Conferir manualmente Meia de Sampa e Sao Silvestre.",
        "Repetir a conferencia por amostra todo mes.",
    ],
}
