# Galaxy Fit3 – notas de protocolo (atualizado 19/11/2026, sessão 2)

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

## Em aberto
- ~~Qual mensagem conclui a configuração~~ → **01/84 01** ✅
- Reconexão com a chave salva: a pulseira derruba em 0,1 s. Por enquanto: despear + parear a cada conexão.
- Depois de muitos ciclos de parear/despear, o scan do Windows chegou a travar (0 dispositivos) → reiniciar o Bluetooth.
- Idioma: a pulseira ficou em espanhol (os frames de config vieram do Fit3 Bridge). Bridge manda 0B/20 e 0B/01 `04 0D 00` ("en-BR id 13").
- O que o `0A/A2` periódico espera de resposta.
- Significado de `0x3A` (aparece em 01/43, 0B/42 e 1F) – bateria 58%?
