#!/usr/bin/env python3
"""
pegar_log_android.py - Puxa o log HCI do Bluetooth de um Android ligado no USB (Windows).

O que faz:
  1. Acha o adb (no PATH, em ./platform-tools ou baixa o Platform Tools oficial do Google).
  2. Confere se o celular esta conectado e autorizado.
  3. Mostra se o registro HCI esta ligado.
  4. Gera um bugreport (1 a 3 minutos) e extrai o btsnoop_hci.log de dentro dele.
     Se o aparelho guardar o log so no formato resumido (btsnooz), decodifica para btsnoop.
  5. Salva tudo em ./capturas/<data_hora>/

Uso (no PowerShell, dentro da pasta revEngFIT3\\android):
    python pegar_log_android.py
    python pegar_log_android.py --sem-bugreport     # so tenta o adb pull direto (mais rapido, nem todo aparelho deixa)

Depois rode:
    python analisar_btsnoop.py capturas\\<data_hora>\\btsnoop_hci.log
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import io
import shutil
import struct
import subprocess
import sys
import urllib.request
import zipfile
import zlib
from pathlib import Path

AQUI = Path(__file__).resolve().parent
PT_URL = "https://dl.google.com/android/repository/platform-tools-latest-windows.zip"


# --------------------------------------------------------------------------
# adb
# --------------------------------------------------------------------------
def achar_adb() -> str:
    for cand in (shutil.which("adb"), AQUI / "platform-tools" / "adb.exe", AQUI / "platform-tools" / "adb"):
        if cand and Path(cand).exists():
            return str(cand)
    print("[..] adb nao encontrado. Baixando o Android Platform Tools oficial do Google...")
    destino = AQUI / "platform-tools.zip"
    urllib.request.urlretrieve(PT_URL, destino)
    with zipfile.ZipFile(destino) as z:
        z.extractall(AQUI)
    destino.unlink(missing_ok=True)
    adb = AQUI / "platform-tools" / ("adb.exe" if sys.platform == "win32" else "adb")
    if not adb.exists():
        sys.exit("[erro] nao consegui instalar o adb. Baixe manualmente: " + PT_URL)
    print(f"[ok] adb em {adb}")
    return str(adb)


def run(adb: str, *args: str, timeout: int = 60, check: bool = False) -> subprocess.CompletedProcess:
    return subprocess.run([adb, *args], capture_output=True, text=True, timeout=timeout, check=check,
                          encoding="utf-8", errors="replace")


def conferir_aparelho(adb: str) -> None:
    out = run(adb, "devices").stdout.strip().splitlines()[1:]
    linhas = [l for l in out if l.strip()]
    if not linhas:
        sys.exit("[erro] nenhum celular encontrado. Confira o cabo USB e a 'Depuracao USB' nas Opcoes do desenvolvedor.")
    if any("unauthorized" in l for l in linhas):
        sys.exit("[erro] o celular nao autorizou este PC. Desbloqueie a tela e aceite 'Permitir depuracao USB'.")
    if len(linhas) > 1:
        print("[aviso] mais de um aparelho conectado; usando o primeiro.")
    modelo = run(adb, "shell", "getprop", "ro.product.model").stdout.strip()
    versao = run(adb, "shell", "getprop", "ro.build.version.release").stdout.strip()
    print(f"[ok] celular: {modelo} (Android {versao})")
    modo = run(adb, "shell", "getprop", "persist.bluetooth.btsnooplogmode").stdout.strip()
    print(f"[..] registro HCI (persist.bluetooth.btsnooplogmode) = {modo or '(vazio)'}")
    if modo and modo != "full":
        print("[aviso] o registro nao esta em 'full'. Ligue 'Registro de rastreamento HCI do Bluetooth' nas Opcoes do\n"
              "        desenvolvedor, desligue e ligue o Bluetooth, e REPITA a captura. Senao o log pode vir vazio ou filtrado.")


# --------------------------------------------------------------------------
# btsnooz -> btsnoop (formato resumido que alguns Androids guardam no bugreport)
# Baseado no btsnooz.py do AOSP.
# --------------------------------------------------------------------------
IN_EVT, IN_ACL, IN_SCO, IN_ISO = 0x10, 0x11, 0x12, 0x17
OUT_CMD, OUT_ACL, OUT_SCO, OUT_ISO = 0x20, 0x21, 0x22, 0x2D
BTSNOOP_EPOCH_DELTA_US = 0x00DCDDB30F2F8000


def _dir(t: int) -> int:
    return 1 if t in (IN_EVT, IN_ACL, IN_SCO, IN_ISO) else 0


def _flags(t: int) -> int:
    # bit0 = recebido, bit1 = comando/evento
    return {OUT_CMD: 2, IN_EVT: 3}.get(t, _dir(t))


def _h4(t: int) -> bytes:
    return {OUT_CMD: b"\x01", IN_ACL: b"\x02", OUT_ACL: b"\x02", IN_SCO: b"\x03", OUT_SCO: b"\x03",
            IN_EVT: b"\x04", IN_ISO: b"\x05", OUT_ISO: b"\x05"}.get(t, b"\x00")


def btsnooz_para_btsnoop(snooz: bytes) -> bytes:
    version, last_ts_ms = struct.unpack_from("=bQ", snooz)
    if version not in (1, 2):
        raise ValueError(f"versao btsnooz desconhecida: {version}")
    data = zlib.decompress(snooz[9:])
    hdr_fmt, hdr_len = ("=HIb", 7) if version == 1 else ("=HHIb", 9)

    def ler(off):
        if version == 1:
            length, delta, typ = struct.unpack_from(hdr_fmt, data, off)
            plen = length
        else:
            length, plen, delta, typ = struct.unpack_from(hdr_fmt, data, off)
        return length, plen, delta, typ

    ts = last_ts_ms
    off = 0
    while off < len(data):
        length, _, delta, _ = ler(off)
        off += hdr_len + length - 1
        ts -= delta
    out = io.BytesIO()
    out.write(b"btsnoop\x00" + struct.pack(">II", 1, 1002))
    off = 0
    while off < len(data):
        length, plen, delta, typ = ler(off)
        ts += delta
        off += hdr_len
        payload = data[off: off + length - 1]
        off += length - 1
        ts_us = ts * 1000 + BTSNOOP_EPOCH_DELTA_US
        out.write(struct.pack(">IIIIq", plen, length, _flags(typ), 0, ts_us))
        out.write(_h4(typ) + payload)
    return out.getvalue()


def extrair_btsnooz_do_texto(texto: str) -> bytes | None:
    ini = texto.find("--- BEGIN:BTSNOOP_LOG_SUMMARY")
    if ini < 0:
        return None
    ini = texto.find("\n", ini) + 1
    fim = texto.find("--- END:BTSNOOP_LOG_SUMMARY", ini)
    b64 = "".join(l.strip() for l in texto[ini:fim].splitlines() if l.strip())
    return base64.standard_b64decode(b64)


# --------------------------------------------------------------------------
def main() -> None:
    ap = argparse.ArgumentParser(description="Puxa o log HCI do Bluetooth do Android")
    ap.add_argument("--sem-bugreport", action="store_true", help="so tenta adb pull direto")
    args = ap.parse_args()

    adb = achar_adb()
    conferir_aparelho(adb)
    pasta = AQUI / "capturas" / dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    pasta.mkdir(parents=True, exist_ok=True)
    achados: list[Path] = []

    # 1) tentativa direta (funciona em alguns aparelhos / Androids antigos)
    for remoto in ("/sdcard/btsnoop_hci.log", "/sdcard/Android/data/btsnoop_hci.log",
                   "/data/misc/bluetooth/logs/btsnoop_hci.log", "/data/log/bt/btsnoop_hci.log"):
        destino = pasta / ("pull_" + remoto.strip("/").replace("/", "_"))
        r = run(adb, "pull", remoto, str(destino))
        if r.returncode == 0 and destino.exists() and destino.stat().st_size > 16:
            print(f"[ok] puxei direto: {remoto}")
            achados.append(destino)

    # 2) bugreport
    if not args.sem_bugreport:
        zip_path = pasta / "bugreport.zip"
        print("[..] gerando bugreport (pode levar de 1 a 3 minutos, nao desconecte o cabo)...")
        r = run(adb, "bugreport", str(zip_path), timeout=900)
        if not zip_path.exists():
            print("[aviso] o bugreport nao foi gerado:\n" + (r.stderr or r.stdout)[-800:])
        else:
            with zipfile.ZipFile(zip_path) as z:
                for nome in z.namelist():
                    base = nome.lower().rsplit("/", 1)[-1]
                    if "btsnoop" in base and not base.endswith(".txt"):
                        destino = pasta / base
                        destino.write_bytes(z.read(nome))
                        print(f"[ok] extraido do bugreport: {nome}")
                        achados.append(destino)
                if not achados:
                    for nome in z.namelist():
                        if nome.lower().startswith("bugreport") and nome.lower().endswith(".txt"):
                            snooz = extrair_btsnooz_do_texto(z.read(nome).decode("utf-8", "replace"))
                            if snooz:
                                destino = pasta / "btsnoop_hci_do_btsnooz.log"
                                destino.write_bytes(btsnooz_para_btsnoop(snooz))
                                print("[ok] log resumido (btsnooz) encontrado e convertido para btsnoop")
                                achados.append(destino)
                            break

    print()
    if achados:
        print("[pronto] arquivos de captura:")
        for f in achados:
            print(f"   {f}  ({f.stat().st_size} bytes)")
        print("\nAgora rode:")
        print(f"   python analisar_btsnoop.py \"{achados[0]}\"")
    else:
        print("[erro] nao achei o log HCI.\n"
              " - Confira se o 'Registro de rastreamento HCI do Bluetooth' esta ligado e se voce desligou/ligou o Bluetooth.\n"
              " - Em celulares Samsung: disque *#9900# > 'Run dumpstate/logcat' e depois 'Copy to sdcard', e rode de novo.\n"
              f" - A pasta {pasta} tem o bugreport; pode me mandar ele que eu procuro manualmente.")


if __name__ == "__main__":
    main()
