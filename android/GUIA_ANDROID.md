# Captura do Galaxy Fit3 pelo Android – guia

Objetivo: gravar a conversa **Galaxy Wearable / Samsung Health ↔ pulseira** para descobrir:

1. como o app oficial **reconecta sem pedir código**;
2. o pedido e o formato do **histórico de saúde** (passos, sono, calorias, SpO₂);
3. de quebra: troca de mostrador, resposta rápida, achar pulseira.

O Android grava tudo o que passa pelo Bluetooth **já sem criptografia** (o log é feito antes do rádio cifrar). O nosso analisador decodifica no mesmo formato que já usamos.

---

## O que precisa

- Um Android 10 ou mais novo, com Google Play (de preferência sem nenhum outro relógio/pulseira pareado).
- Cabo USB que transfira dados.
- Esta pasta `revEngFIT3\android` no PC, com Python.

> ⚠️ A pulseira vai ser **resetada** e configurada no Android. Depois, para voltar a usar pelo PC, é só resetar de novo.

---

## Parte A – Preparar o Android (uma vez só)

1. **Configurações › Sobre o telefone › Informações do software** › toque 7 vezes em **Número de compilação**.
2. **Configurações › Opções do desenvolvedor**:
   - ligue **Depuração USB**;
   - ligue **Ativar registro de rastreamento HCI do Bluetooth** (se pedir um modo, escolha **Ativado / Completo**, não "filtrado").
3. **Desligue e ligue o Bluetooth** do celular (o registro só começa depois disso).
4. Instale pela Play Store: **Galaxy Wearable** e **Samsung Health**. O plugin do Fit3 o próprio Wearable baixa.
5. Entre na conta Samsung quando o Samsung Health pedir (sem isso ele não sincroniza os dados de saúde).

## Parte B – Liberar a pulseira

1. **PC:** Configurações › Bluetooth › remova o **Galaxy Fit3** e **desligue o Bluetooth do PC** durante toda a captura.
2. **iPhone:** Bluetooth desligado.
3. **Pulseira:** resete (Configurações › Geral › Redefinir).

## Parte C – Parear pelo Galaxy Wearable

1. Abra o Galaxy Wearable › Galaxy Fit3 e siga **até o fim** (até a pulseira mostrar o relógio).
2. Aceite todas as permissões (notificações, Samsung Health etc.).
3. Anote a hora em que terminou: ________

## Parte D – Roteiro de ações (anote a hora de cada uma)

Faça com calma, esperando uns 30 s entre um passo e outro. A hora ajuda a achar cada coisa no log.

| # | Ação | Hora |
|---|---|---|
| 1 | Esperar 1 minuto parado com o app aberto | |
| 2 | Abrir o **Samsung Health** e puxar a tela para baixo para sincronizar | |
| 3 | Andar ~50 passos com a pulseira no pulso e sincronizar de novo | |
| 4 | Medir **batimentos** na pulseira | |
| 5 | Medir **SpO₂** na pulseira (se tiver o atalho) | |
| 6 | No Wearable: **trocar o mostrador** e depois voltar para o original | |
| 7 | No Wearable: **Encontrar minha pulseira** (vibrar) | |
| 8 | Receber uma mensagem (peça para alguém mandar, ou mande de outro número) e **responder pela pulseira** com uma resposta rápida | |
| 9 | **Desligar o Bluetooth do celular**, esperar 20 s e **ligar de novo** (testa a reconexão) | |
| 10 | Esperar a pulseira reconectar e sincronizar de novo no Samsung Health | |

Se tiver uma noite com a pulseira configurada, o sono aparece no passo 2 do dia seguinte. Não é obrigatório agora: dá para fazer uma segunda captura depois.

## Parte E – Puxar o log para o PC

1. Ligue o celular no USB e aceite **Permitir depuração USB** na tela do celular.
2. No PowerShell, dentro de `revEngFIT3\android`:

```
python pegar_log_android.py
```

O script baixa o `adb` sozinho se precisar, gera um bugreport (1 a 3 min) e extrai o log para `capturas\<data_hora>\`.

3. Decodifique:

```
python analisar_btsnoop.py capturas\<data_hora>\btsnoop_hci.log
```

Saem três arquivos ao lado do log: `_timeline.txt` (linha do tempo), `_frames.jsonl` (cada frame) e `_resumo.md` (pareamento, reconexões, canais).

4. Me avise com a tabela de horas da Parte D preenchida. Eu leio os arquivos direto da pasta.

---

## Problemas comuns

- **"nenhum celular encontrado"**: cabo só de carga, ou Depuração USB desligada.
- **"unauthorized"**: desbloqueie o celular e aceite o aviso de depuração.
- **log vazio / não encontrado**: o registro HCI estava desligado ou você não reiniciou o Bluetooth depois de ligar. Ligue, reinicie o Bluetooth e **refaça o roteiro**.
- **Celular Samsung sem o log no bugreport**: disque `*#9900#`, toque em **Run dumpstate/logcat** e depois **Copy to sdcard**, e rode o script de novo.

## Privacidade

O log grava **todo** o Bluetooth do celular naquele período (fones, carro etc.) e o **conteúdo das notificações** enviadas à pulseira. O analisador já filtra só a conexão da pulseira, mas **não suba os arquivos brutos (`capturas\`) para o GitHub**.
