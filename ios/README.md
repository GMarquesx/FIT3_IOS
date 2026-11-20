# Elo – app iOS para a Galaxy Fit3 (versão 0.1)

Primeira versão do app: faz no iPhone o mesmo que os scripts Python já fazem no PC.

- Procura e conecta na pulseira
- Pareia (o **próprio iOS** mostra o código para confirmar)
- Abre a sessão SAP e conclui a configuração (`01/84`)
- Vibrar (achar pulseira)
- Notificação de teste (de / mensagem / app)
- Bateria e batimentos ao vivo
- Console com tudo que entra e sai

O projeto Xcode **não fica no repositório**: o GitHub Actions gera com o XcodeGen (`project.yml`) e compila numa máquina macOS da nuvem. Nenhum Mac é necessário.

## 1. Subir para o GitHub (uma vez)

1. Crie um repositório **público** no GitHub (ex.: `fit3-elo`). Repositório público tem os minutos de macOS do Actions grátis.
2. No PowerShell, dentro da pasta `revEngFIT3`:

```
git init
git add .
git commit -m "Galaxy Fit3: protocolo, scripts e app iOS"
git branch -M main
git remote add origin https://github.com/GMarquesx/fit3-elo.git
git push -u origin main
```

O `.gitignore` já deixa de fora os `logs/` e as capturas do Android (têm número de série e conteúdo de notificações).

## 2. Baixar o .ipa

1. No GitHub, aba **Actions** › "iOS - gerar .ipa" › a execução mais recente.
2. Se ficou verde ✅: em **Artifacts**, baixe **Elo-ipa** (vem um .zip com o `Elo.ipa` dentro).
3. Se ficou vermelho ❌: baixe o artifact **xcodebuild-log** ou copie o erro da etapa "Compilar" e me mande. Como o código foi escrito sem um Mac para testar, é normal o primeiro build precisar de ajuste.

Toda vez que algo dentro de `ios/` mudar e você der `git push`, ele compila de novo sozinho. Também dá para rodar na mão pelo botão **Run workflow**.

## 3. Instalar no iPhone com o SideStore (grátis)

1. Siga o guia oficial em **sidestore.io** para instalar o SideStore. A configuração inicial usa o PC com Windows **uma vez só**.
2. Confira antes se o SideStore já funciona na versão do iOS do seu iPhone.
3. Mande o `Elo.ipa` para o iPhone (AirDrop não rola do Windows: use o iCloud Drive, Google Drive ou WhatsApp para você mesmo) e abra pelo **SideStore › My Apps › +**.
4. O SideStore assina com o seu Apple ID. A cada 7 dias ele renova **no próprio iPhone**, pelo Wi-Fi.

## 4. Primeiro teste

1. Bluetooth do PC desligado (para ele não disputar a pulseira).
2. Abra o Elo › **Conectar**.
3. Quando o iOS mostrar o pedido de pareamento, confira o código com o da pulseira e confirme.
4. Quando o status ficar **Pronta**: teste **Vibrar** e **Enviar para a pulseira**.
5. Se der algo errado, tire print do **Console** e me mande.

## v0.2 – telas do design, Atalhos e idiomas

- **Telas**: Hoje (modelo 3D com as mesmas transformações CSS do design), Saúde, Treino (GPS do iPhone),
  Avisos, Console (frames SAP ao vivo, exportar `.jsonl`, ferramentas de teste) e, a partir do Hoje,
  Perfil e "Sua Galaxy Fit3" (personalização do modelo 3D).
- **Pulseira em inglês**: depois de abrir a sessão o app manda `0B/01 04 <id> 00` (padrão id 13 = English).
  Dá para trocar em Console → Idioma da pulseira.
- **App em inglês e português (Brasil)**: segue o idioma do iPhone (`pt-BR.lproj/Localizable.strings`).
- **Atalhos** (App Intents): "Enviar para a Galaxy Fit3", "Achar minha Galaxy Fit3", "Mostrar ligação na
  Galaxy Fit3" e "Bateria da Galaxy Fit3".
  - No iOS 27: Atalhos → Automação → Nova → **Notificação** → escolha o app → Executar Imediatamente →
    ação "Enviar para a Galaxy Fit3" com De = Título, Mensagem = Corpo e App = nome do app.
  - Respostas rápidas (Avisos) abrem o atalho **"Elo Reply"** com o texto `contato|resposta|app`.
- **Ainda sem dados da pulseira** (canal não decodificado): passos, sono, calorias, SpO₂, histórico para o
  Saúde, mostrador real e espelhamento do treino. Essas áreas aparecem com "—" ou "em breve".
- Fontes embutidas: Inter, Space Grotesk e JetBrains Mono (licença OFL em `Elo/Fonts/*-OFL.txt`).
