# Galaxy Fit3 – notas de protocolo (atualizado 25/11/2026, análise do plugin oficial)

## ✅ Configuração inicial concluída pelo PC (sessão 2)
- Comando **`01 40 01 01 84 01`** (canal 01, cmd 0x84, dado 01) → pulseira responde `01/44` e sai de
  "Revise o tel. para terminar" para "Conheça sua pulseira – Iniciar / Omitir".
- Junto vem uma rajada: `04/86`, `08/0C`, `08/0D`, `08/07`, e um canal novo **`0x18` cmd C0** (lista de pares).
- Sequência mínima que funcionou: handshake SAP → 01/01 → 01/02 → 01/83 (horário) → 08/4C (fuso) → 0A/A1 (config)
  → 0B/02 → 07/0D → 07/0E → … → **01/84 01**.
- Respostas testadas sem efeito visível: 04/46, 07/50 (pulseira respondeu 07/D0), 0A/49, 0A/62 (eco do A2),
  09/41, 09/01, 09/02, 01/04, 01/05.
- Depois do eco 0A/62 os A2 periódicos pararam por ~50 s → 0A/62 provavelmente é a resposta certa ao A2.

## ✅ Notificação enviada pelo PC (sessão 3)
- Canal 07, cmd **0x80**. Campos conhecidos: id em texto (5 dígitos), **02 = horário em ms (8 B LE)**,
  **03 = título** (1 B de tamanho), **04 = texto** (2 B LE), **0E = nome do app**, 09 = `APP_ICON_<id>`.
- Testado: "Ana" / "Tô chegando!! 🏃💨 Me espera 😄" → apareceu com acento certo.
- Emojis: 😄 em cores; 🏃 e 💨 em versão monocromática (a fonte da pulseira tem um conjunto limitado de emojis coloridos).
- Ícone: sem o ícone enviado, a pulseira usa um ícone genérico de mensagem.
- Implementado em `fit3_sniffer_v8.py notificar --de ... --texto ... --app ...`.

## Idioma (canal 0B, cmd 01, dados `04 <id> 00`)
- Pulseira confirma com `0B/41 20 01`; a troca na tela demora alguns segundos.
- Ids em ordem alfabética do código do idioma. Mapeados: 0 es · 1 en · 2 az · 3 be · 4 bg · 5 bn · 8 ca · 9 cs · 10 da ·
  11 de · 12 el · 13 en · 14 es · 15 et · 16 eu · 17 fa (RTL, travou a pulseira) · 48 es · 50 en · 52 nb · 54 pl ·
  **55 pt (Portugal)** · 56 ro · 57 ru · 59 sk · 60 sl · 61 sv · 62 sr · 63 sv.
  Ids que voltam "english" provavelmente são idiomas sem pacote instalado.
- A pulseira anuncia `en_GB` e `pt_BR` no `0A/89` → pt_BR talvez esteja numa faixa acima de 65 (não testado).

## Bateria
- `01/43` (2º byte) e último byte de `0B/42` = % de bateria.
- A pulseira **avisa sozinha** quando a bateria muda: `0B/02` com o mesmo formato (`06 00 05 <pct>`).

## Pareamento
- Tipo exigido pela pulseira: **comparação numérica** (`CONFIRM_PIN_MATCH`), proteção **Encryption + Authentication**.
- Em modo de configuração, a chave **não sobrevive a uma desconexão**: parear e usar na **mesma conexão**.
- Implementado em `fit3_sniffer_v6.py` (`pair_with_pin`).

## Transporte
- Serviço `0x1A1A`: notify `797AE4E9…` (pulseira → app), write `63E30BAD…` (app → pulseira).
- 1º frame de cada lado é o handshake SAP (`68 15 …` app / `68 14 … "SAMSUNG_ACCESSARY__" …` pulseira).

## Frame
| Campo | Tamanho | Conteúdo |
|---|---|---|
| LEN | 2 B BE | tamanho do payload |
| CRC(LEN) | 2 B BE | CRC-16/ARC dos 2 bytes de LEN |
| PAYLOAD | LEN | `DIR 40 CH CH CMD dados…` |
| CRC(PAYLOAD) | 2 B BE | CRC-16/ARC do payload |

- `DIR`: `01` app → pulseira, `00` pulseira → app.
- Resposta = `CMD | 0x40` (01→41, 02→42, 83→43, 0D→4D, 0E→4E).
- ACK da pulseira: payload `88 40 80 00` / `88 50 80 00` (bit 0x10 alterna).
- Validado: 45/45 frames do Fit3 Bridge + 52/52 frames da sessão 1.

## Canais vistos
| Canal | Sentido | Observação |
|---|---|---|
| 01 | ↔ | 01→41 identificação (firmware, modelo SM-R390, bateria 208 mAh, nº de série*), 02→42 lista de recursos, 83→43 horário (Unix time em texto) |
| 04 | ← | 86 logo após o handshake |
| 05 | → | clima (TLV) |
| 07 | ↔ | notificações; 0D→4D e 0E→4E configurações; 90, 16 espontâneos |
| 08 | ↔ | fuso horário (4C); pulseira manda 0C/0D/07 |
| 09 | ← | **01 com `01 02` e depois `01 01`** → candidato a estado da configuração |
| 0A | ↔ | A1 config grande; pulseira manda 89 (idiomas `en_GB`, `pt_BR`), 04 e **A2 a cada ~19,5 s com contador +2** (sem resposta nossa) |
| 0B | ↔ | 02→42 `06 00 05 3A`; 23 espontâneo |
| 0F | ← | 00 lista de pares (ordem de telas/apps?) |
| 1F | ↔ | achar pulseira: 0D liga → 4E 10 01; 0F desliga → 50 10 01; 51 14 02 |

\* Não publicar nº de série / TWID no repositório.

## Tipo do comando (2 bits altos do CMD) – visto nos logs de 19/11
- `cmd & 0x3F` = id do comando; `cmd & 0xC0` = tipo. Respostas: 01/01→41, 01/83→43, 07/50→**D0**, 07/0D→4D.
- A pulseira também inicia mensagens (tipo `0x80`): `04/86`, `07/90`, `0A/89`, `0A/A2`, `18/C0`, `1A/80`.
- `0A/A2` (`02 e0 SS SS e1 2d 01`) repete a cada ~19,6 s enquanto não é respondido. O eco em `0A/62` só calava a
  pulseira; o significado real está na seção do canal 0x0A abaixo.
- **Canal 0x18 (AppsSAPAgent = lista de apps, não saúde)**: aparece só depois do `01/84 01`. `18/C0` traz uma tabela
  `02 01 03 0a` + 10 pares `00 <tipo> 01 <id>`: 01→01, 02→02, 03→03, 04→04, 05→05, 07→06, 08→07, 09→08, 0C→09, 06→0A.
  São os apps da pulseira (ordem/ids). As sondas no 0x18 estavam no canal errado.
- `0A/04` e `0A/89` começam com `e0 SS SS` (mesmo contador do A2) → o canal 0A tem um sub-protocolo com número de sequência.
- Sonda rodada 1 (20/11): pedidos tipo 00 no 0x18 (18/01..0F, com 01 e 00 01) → só ACK de transporte, sem resposta.
  `18/80` e `18/40 02 01` → pulseira reenviou `18/C0` (tabela). Conclusão: o 0x18 responde a pedidos tipo 0x80/0x40
  com respostas tipo 0xC0. Rodada 2: 18/81..8F, 18/81 <tipo>, 18/82 <tipo>.
- `04/86 00` chega em pares a cada poucos segundos em alguns momentos (pulseira esperando resposta?).

## Mapa de canais (do plugin oficial, `res/xml/hmaccessoryservices_new.xml`)
O canal é o `serviceId` do SAP. Isso corrige os palpites anteriores: **0x0F são widgets** e **0x18 é a lista de apps**.

| ID | Serviço | ID | Serviço | ID | Serviço |
|---|---|---|---|---|---|
| 01 | OOBE | 0B | FullSetting | 15–16 | — |
| 02 | FMD | 0C | Debug | 17 | CC |
| 03 | SACall | 0D | alarm | 18 | AppsSAPAgent |
| 04 | lbs-server | 0E | Reminder | 19 | SOS |
| 05 | Weather | 0F | WidgetsService | 1A | SharedInfo |
| 06 | **WatchfaceSerevice** | 10 | Runestone | 1B | worldclock |
| 07 | Notification | 11 | BandAlarm | 1C | timer |
| 08 | SACalendar | 12 | QuickMessage | 1D | medicalinfo |
| 09 | music | 13 | QS | 1E | OtaTransfer |
| 0A | **HealthService** | 14 | BandSALogging | 1F | Find |

## Canal 0x06 = mostradores (BandFace)
- Byte 0 = tipo (`0x40` = resposta) | comando (6 bits). Depois pares `parâmetro valor` (1 byte), ou
  `parâmetro tamanho bytes` para textos. Little endian.
- Comandos: 00 GET_ALL_INFO, 01 GET_LIST, 02 GET_CURRENT, 03 SET_CURRENT, 04 INSTALL, 05 DELETE, 06 GET_EDIT_INFO,
  07 SET_EDIT_INFO, 08 CANCEL_EDIT, 09 GET_ORDER, 0A SET_ORDER, 0B ADD_IMAGE_LIST, 0C DELETE_IMAGE_LIST, 0E GET_IMAGE_LIST.
- Parâmetros: 00 atual, 01 máximo, 02 qtd, 03 lista, 04 WF_ID, 05 versão, 06 nome, 07 descrição, 08 STYLE_ID (sampler),
  09 posição, 0A estilo, 0B é atual, 0C editável, 0D tipo de relógio, 0E–10 ponteiros, 11 widgets, 13 fundo,
  18 NUM_OF_PARAMS, 19 ordem, 1A resultado, 1D WF_SAMPLER_ID, 1E cor do relógio.
- `GET_ALL_INFO` = `00` → `40 00 <atual> 01 <máx> 02 <qtd> 03 <n> {18 <k> params…} x n`.
- `SET_CURRENT_BANDFACE` = `03 04 <id> 1D <sampler>` → resposta `43 04 <id> 1D <sampler>`.
- `SET_CURRENT_ORDER` = `0A 19 <tipo> [qtd] {04 id 1D sampler}…`.
- Foto de fundo e complicações: `ADD_IMAGE_LIST` / `SET_EDIT_INFO` + transferência de arquivo (`safiletransfer`). Em aberto.

## Canal 0x0F = widgets
- Ao conectar a pulseira manda `0F/00 01 <n> {03 <id> 02 <posição>} x n` (`ff` = fora do carrossel).

## Canal 0x0A = saúde (HealthService)
Cabeçalho de 1 byte: bit7 frameType, bit6 0 pedido / 1 resposta, bits 0–5 msgId. Inteiros little endian.

| msgId | Mensagem |
|---|---|
| 2 | SYNC_DATA (pulseira manda `82`, confirmação `42`) |
| 3 | REQUEST_DATA (pedido `03`, resposta `43`) |
| 4 | WEARABLE_MSG |
| 32/33 | capacidade |
| 34 | GM_REQUEST_CAPABILITY (`A2`) |
| 35 | resposta de GM capability noti |
| 49/50/51 | pedir instalação / atualização / loja do Samsung Health |
| 62 | ACK/NACK de dados grandes |
| 63 | pedaço de dados grandes |

- **`0A/A2` não é keep-alive**: é `GM_REQUEST_CAPABILITY` = `A2 02 E0 <seq 2B> E1 <versão 2B>` (versão 0x012D = 301).
  A pulseira repete até receber a resposta certa:
  `E2 <n> E0 <seq> E1 <min(versão, 301)> D0 02 D2 <versionCode do Samsung Health, 4B>` (n = parâmetros + 2).
  Sem Samsung Health o plugin manda `D0 01` (n = parâmetros + 1) e a pulseira não sincroniza.
  Depois o plugin manda `34` (pedido de capacidade de saúde).
- **Confirmação do SYNC_DATA**: `42 02 E0 <seq> 04 02 01 01` (01 = SUCCESS; o plugin manda `… 01 09` quando não entende).
- **Dados grandes**: `3F <flag> <nº do pedaço 4B> <corpo>`, flag bits 0–1 = 0 primeiro, 1 meio, 2 último
  (`| 0x08 | janela<<2`). Junta os corpos e só no fim manda `3E 09 <qtd de pedaços 4B>` (NACK `3E 08 <nº>`).
- **Corpo do SYNC_DATA**: `82 <n params>` e cada parâmetro começa com o tipo: E0 sequência (2B), 04 MSG_INFO e
  05 DEVICE_INFO (tamanho 1B + bytes), 07 passos, 0A frequência, 10 sono, 11 estágios do sono, 13 estresse,
  17 calorias, 70 SpO₂, 7E resumo do dia, 80 exercício, 89 sono combinado…
  - Tipos antigos (07–1D): lista `[continua 0/1]{tag valor} x N campos`. Passos (07) = 12 campos:
    01 início, 02 fim, 03 fuso, 05 atualização (4B, segundos), 10 passos, 11 distância (float), 12 velocidade,
    13 calorias, 14 corrida, 15 caminhada, 16 duração (4B), 17 versão (1B), 75 uuid (16B).
  - Tipos novos (≥ 0x70): `[continua 0/1][tamanho 4B][corpo]`. Resumo do dia (7E): 2C dia, 31 passos, 32 calorias,
    33 distância, 34 meta (4B cada), 40/41/42 listas com tamanho.

## Em aberto
- ~~Qual mensagem conclui a configuração~~ → **01/84 01** ✅
- Reconexão com a chave salva: a pulseira derruba em 0,1 s. Por enquanto: despear + parear a cada conexão.
- Depois de muitos ciclos de parear/despear, o scan do Windows chegou a travar (0 dispositivos) → reiniciar o Bluetooth.
- Idioma: a pulseira ficou em espanhol (os frames de config vieram do Fit3 Bridge). Bridge manda 0B/20 e 0B/01 `04 0D 00` ("en-BR id 13").
- ~~O que o `0A/A2` periódico espera de resposta~~ → resposta `E2` de capacidade ✅ (testar no app v0.3).
- Significado de `0x3A` (aparece em 01/43, 0B/42 e 1F) – bateria 58%?
