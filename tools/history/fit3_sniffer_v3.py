#!/usr/bin/env python3
"""
fit3_sniffer.py - Explorador / sniffer BLE do Samsung Galaxy Fit3 (etapa 1)

Objetivo: conectar na pulseira pelo PC e registrar em hex TUDO que ela manda,
principalmente os frames do canal SAP (servico 1A1A) que o Fit3 Bridge rejeita.

Requisitos:
    Python 3.10+
    pip install bleak

Uso:
    python fit3_sniffer.py scan                      # procura a pulseira
    python fit3_sniffer.py explore [--pair]          # lista servicos/caracteristicas e le o que for legivel
    python fit3_sniffer.py listen  [--pair] [--init] [--seconds 180]
                                                     # inscreve em todas as notificacoes e registra RX/TX

    --address XX:XX:XX:XX:XX:XX   usa um endereco especifico (senao procura por nome "Fit3")
    --pair                        pede pareamento/bond ao Windows antes de usar o canal SAP
    --init                        envia o frame de abertura de sessao SAP visto no log do Fit3 Bridge

Antes de rodar: desligue o Bluetooth do iPhone (a pulseira so aceita uma conexao por vez).
Os logs ficam em ./logs/fit3_<comando>_AAAAMMDD_HHMMSS.jsonl (uma linha JSON por evento).
"""

import argparse
import asyncio
import datetime as dt
import json
import sys
from pathlib import Path

from bleak import BleakClient, BleakScanner
from bleak.backends.characteristic import BleakGATTCharacteristic

# --------------------------------------------------------------------------
# O que ja sabemos pelo log do Fit3 Bridge
# --------------------------------------------------------------------------
SAP_SERVICE = "00001a1a-0000-1000-8000-00805f9b34fb"

CHAR_NAMES = {
    "797ae4e9-2e58-4fe8-b48d-b5c79599fb9b": "SAP_797A",
    "63e30bad-4206-4596-839f-e47cbf7a4b5d": "SAP_63E3",
    "00002a37-0000-1000-8000-00805f9b34fb": "HR_MEAS",
    "00002a38-0000-1000-8000-00805f9b34fb": "HR_LOC",
    "00002a39-0000-1000-8000-00805f9b34fb": "HR_CTRL",
    "00002a29-0000-1000-8000-00805f9b34fb": "MANUF",
    "00002a24-0000-1000-8000-00805f9b34fb": "MODEL",
    "00002a25-0000-1000-8000-00805f9b34fb": "SERIAL",
    "00002a27-0000-1000-8000-00805f9b34fb": "HW_REV",
    "00002a26-0000-1000-8000-00805f9b34fb": "FW_REV",
    "00002a28-0000-1000-8000-00805f9b34fb": "SW_REV",
    "00002a23-0000-1000-8000-00805f9b34fb": "SYS_ID",
    "00002a2a-0000-1000-8000-00805f9b34fb": "REG_CERT",
    "00002a50-0000-1000-8000-00805f9b34fb": "PNP_ID",
}

# Primeiro TX do Fit3 Bridge depois de "canal SAP listo -> iniciando sesion"
# (116 bytes: cabecalho 68 15 04 01 00 FF 03 + "SAP_<id>" + "iPhone" + "samsung" + "samsung" + parametros)
SESSION_OPEN_HEX = (
    "68 15 04 01 00 FF 03 53 41 50 5F 39 37 37 30 30 31 44 45 42 35 35 31 34 30 31 38 41 43 33 41 35 "
    "31 32 34 42 36 32 33 34 45 31 38 01 01 F4 00 00 03 D4 69 50 68 6F 6E 65 00 00 00 00 00 00 00 00 "
    "00 00 73 61 6D 73 75 6E 67 00 00 00 00 00 00 00 00 00 73 61 6D 73 75 6E 67 00 00 00 00 00 00 00 "
    "00 00 02 00 00 00 08 00 00 00 08 00 00 00 03 00 00 00 00 00"
)

BAND_NAME_HINTS = ("fit3", "galaxy fit")


# --------------------------------------------------------------------------
# Utilitarios
# --------------------------------------------------------------------------
def hexs(data: bytes) -> str:
    return " ".join(f"{b:02X}" for b in data)


def ascii_view(data: bytes) -> str:
    return "".join(chr(b) if 32 <= b < 127 else "." for b in data)


def short_uuid(uuid: str) -> str:
    uuid = uuid.lower()
    return CHAR_NAMES.get(uuid, uuid[:8])


class Logger:
    """Imprime no console e grava JSONL para analisarmos depois."""

    def __init__(self, cmd: str) -> None:
        logs = Path("logs")
        logs.mkdir(exist_ok=True)
        stamp = dt.datetime.now().strftime("%Y%m%d_%H%M%S")
        self.path = logs / f"fit3_{cmd}_{stamp}.jsonl"
        self._f = self.path.open("a", encoding="utf-8")
        self._t0 = dt.datetime.now()

    def _write(self, rec: dict) -> None:
        rec["t"] = round((dt.datetime.now() - self._t0).total_seconds(), 3)
        rec["ts"] = dt.datetime.now().isoformat(timespec="milliseconds")
        self._f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        self._f.flush()

    def event(self, msg: str) -> None:
        print(f"[{dt.datetime.now():%H:%M:%S}] {msg}")
        self._write({"kind": "event", "msg": msg})

    def data(self, direction: str, uuid: str, data: bytes) -> None:
        print(f"[{dt.datetime.now():%H:%M:%S}] {direction} {short_uuid(uuid):<9} {len(data):>4} B  {hexs(data)}")
        print(f"{'':>30}|{ascii_view(data)}|")
        self._write({"kind": direction, "uuid": uuid, "name": short_uuid(uuid),
                     "len": len(data), "hex": hexs(data)})


async def find_band(address: str | None):
    if address:
        print(f"[..] procurando {address} ...")
        dev = await BleakScanner.find_device_by_address(address, timeout=20.0)
    else:
        print("[..] procurando pulseira com 'Fit3' no nome (20 s) ...")
        dev = await BleakScanner.find_device_by_filter(
            lambda d, adv: bool(d.name) and any(h in d.name.lower() for h in BAND_NAME_HINTS),
            timeout=20.0,
        )
    if dev is None:
        print("[erro] pulseira nao encontrada. Confira:\n"
              "  - Bluetooth do iPhone DESLIGADO (ela so aceita uma conexao)\n"
              "  - pulseira acordada e perto do PC\n"
              "  - rode 'scan' e use --address com o endereco que aparecer")
        sys.exit(1)
    print(f"[ok] encontrada: {dev.name}  {dev.address}")
    return dev


def make_client(dev, pair: bool, **kw) -> BleakClient:
    """Com --pair, tenta parear JUNTO com a conexao (bleak >= 1.0, Windows).
    Em versoes antigas do bleak cai no pair() depois de conectar."""
    if pair:
        try:
            c = BleakClient(dev, pair=True, **kw)
            c._fit3_paired_on_connect = True
            return c
        except TypeError:
            pass
    c = BleakClient(dev, **kw)
    c._fit3_paired_on_connect = False
    return c


async def maybe_pair(client: BleakClient, log: Logger, pair: bool) -> None:
    if not pair:
        return
    if getattr(client, "_fit3_paired_on_connect", False):
        log.event("pareamento feito junto com a conexao (pair=True)")
        return
    try:
        log.event(f"pair() -> {await client.pair()}")
    except Exception as e:  # noqa: BLE001
        log.event(f"pair() falhou: {e}")


def safe_mtu(client: BleakClient):
    try:
        return client.mtu_size
    except Exception:  # noqa: BLE001
        return None


def still_connected(client: BleakClient, log: Logger) -> bool:
    if client.is_connected:
        return True
    log.event("a pulseira derrubou a conexao (provavelmente recusou o pareamento). Encerrando.")
    return False


# --------------------------------------------------------------------------
# scan
# --------------------------------------------------------------------------
async def cmd_scan(args) -> None:
    print("[..] escaneando BLE por 12 s ...")
    found = await BleakScanner.discover(timeout=12.0, return_adv=True)
    rows = sorted(found.values(), key=lambda da: da[1].rssi, reverse=True)
    for dev, adv in rows:
        name = dev.name or adv.local_name or "-"
        mark = "  <== provavel Fit3" if any(h in name.lower() for h in BAND_NAME_HINTS) else ""
        print(f"{dev.address}  RSSI {adv.rssi:>4}  {name}{mark}")
        if adv.service_uuids:
            print(f"{'':>19}servicos: {', '.join(short_uuid(u) for u in adv.service_uuids)}")
        if adv.manufacturer_data:
            for cid, payload in adv.manufacturer_data.items():
                print(f"{'':>19}fabricante 0x{cid:04X}: {hexs(payload)}")
    print(f"\n[ok] {len(rows)} dispositivos")


# --------------------------------------------------------------------------
# explore
# --------------------------------------------------------------------------
async def cmd_explore(args) -> None:
    dev = await find_band(args.address)
    log = Logger("explore")
    try:
        client_cm = make_client(dev, args.pair)
        async with client_cm as client:
            await explore_body(client, dev, log, args)
    except Exception as e:  # noqa: BLE001
        log.event(f"falha na conexao/pareamento: {e}")
    print(f"\n[log] pronto. Me manda o arquivo: {log.path.resolve()}")


async def explore_body(client: BleakClient, dev, log: Logger, args) -> None:
        log.event(f"conectado: {dev.name} {dev.address}  MTU={safe_mtu(client)}")
        await maybe_pair(client, log, args.pair)
        if not still_connected(client, log):
            return
        for svc in client.services:
            tag = "  <== canal SAP" if svc.uuid.lower() == SAP_SERVICE else ""
            log.event(f"SERVICO {svc.uuid} ({svc.description}){tag}")
            for ch in svc.characteristics:
                log.event(f"   CHAR {short_uuid(ch.uuid):<9} {ch.uuid} handle={ch.handle} props={','.join(ch.properties)}")
                if "read" in ch.properties:
                    try:
                        val = bytes(await client.read_gatt_char(ch))
                        log.data("READ", ch.uuid, val)
                    except Exception as e:  # noqa: BLE001
                        log.event(f"       leitura falhou: {e}")
                for d in ch.descriptors:
                    log.event(f"       DESC {d.uuid} handle={d.handle}")


# --------------------------------------------------------------------------
# Escutar notificacoes (e opcionalmente abrir a sessao SAP)
# --------------------------------------------------------------------------
async def cmd_listen(args) -> None:
    dev = await find_band(args.address)
    log = Logger("listen_init" if args.init else "listen")
    disconnected = asyncio.Event()

    def on_disconnect(_client) -> None:
        log.event("desconectada")
        disconnected.set()

    def on_notify(sender: BleakGATTCharacteristic, data: bytearray) -> None:
        log.data("RX", sender.uuid, bytes(data))

    try:
        async with make_client(dev, args.pair, disconnected_callback=on_disconnect) as client:
            await listen_body(client, dev, log, args, on_notify, disconnected)
    except Exception as e:  # noqa: BLE001
        log.event(f"falha na conexao/pareamento: {e}")
    print(f"\n[log] pronto. Me manda o arquivo: {log.path.resolve()}")


async def listen_body(client: BleakClient, dev, log: Logger, args, on_notify, disconnected) -> None:
        log.event(f"conectado: {dev.name} {dev.address}  MTU={safe_mtu(client)}")
        await maybe_pair(client, log, args.pair)
        if not still_connected(client, log):
            return

        # 1) acha as caracteristicas
        sap_notify, sap_write, others = None, None, []
        for svc in client.services:
            for ch in svc.characteristics:
                props = set(ch.properties)
                is_sap = svc.uuid.lower() == SAP_SERVICE
                if is_sap and props & {"notify", "indicate"}:
                    sap_notify = ch
                elif is_sap and props & {"write", "write-without-response"}:
                    sap_write = ch
                elif props & {"notify", "indicate"} and ch.uuid.lower() != "00002a05-0000-1000-8000-00805f9b34fb":
                    others.append(ch)

        async def sub(ch) -> None:
            try:
                await asyncio.wait_for(client.start_notify(ch, on_notify), timeout=4.0)
                log.event(f"inscrito em {short_uuid(ch.uuid)} ({','.join(ch.properties)})")
            except asyncio.TimeoutError:
                log.event(f"timeout ao inscrever em {short_uuid(ch.uuid)} (pulei)")
            except Exception as e:  # noqa: BLE001
                log.event(f"falha ao inscrever em {short_uuid(ch.uuid)}: {e}")

        # 2) canal SAP primeiro, sem esperar nada
        if sap_notify:
            await sub(sap_notify)
        else:
            log.event("SAP notify nao encontrado")
        if not still_connected(client, log):
            return

        if args.init and sap_write:
            frame = bytes.fromhex(SESSION_OPEN_HEX)
            mtu = safe_mtu(client)
            log.event(f"MTU agora = {mtu}")
            log.data("TX", sap_write.uuid, frame)
            try:
                await client.write_gatt_char(sap_write, frame, response="write" in sap_write.properties)
                log.event("escrita OK")
            except Exception as e:  # noqa: BLE001
                log.event(f"escrita falhou: {e}")
        elif args.init:
            log.event("nenhuma caracteristica de escrita encontrada no servico SAP")

        # 3) o resto so depois (pode ser desligado com --sap-only)
        if not args.sap_only:
            for ch in others:
                if not client.is_connected:
                    break
                await sub(ch)

        log.event(f"escutando por ate {args.seconds} s (Ctrl+C para parar)")
        try:
            await asyncio.wait_for(disconnected.wait(), timeout=args.seconds)
        except asyncio.TimeoutError:
            log.event("tempo esgotado, encerrando")


# --------------------------------------------------------------------------
# unpair: apaga um vinculo antigo do Windows com a pulseira
# --------------------------------------------------------------------------
async def cmd_unpair(args) -> None:
    dev = await find_band(args.address)
    try:
        async with BleakClient(dev) as client:
            print(f"[ok] unpair() -> {await client.unpair()}")
    except Exception as e:  # noqa: BLE001
        print(f"[aviso] unpair falhou: {e}  (pode remover em Configuracoes > Bluetooth)")


# --------------------------------------------------------------------------
def main() -> None:
    p = argparse.ArgumentParser(description="Sniffer BLE do Galaxy Fit3")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("scan", help="procura dispositivos BLE")
    up = sub.add_parser("unpair", help="remove vinculo antigo do Windows com a pulseira")
    up.add_argument("--address", help="endereco BLE da pulseira")

    for name in ("explore", "listen"):
        sp = sub.add_parser(name)
        sp.add_argument("--address", help="endereco BLE da pulseira")
        sp.add_argument("--pair", action="store_true", help="pede bond ao Windows")
        if name == "listen":
            sp.add_argument("--init", action="store_true", help="envia o frame de abertura de sessao SAP")
            sp.add_argument("--seconds", type=int, default=180, help="tempo de escuta (padrao 180)")
            sp.add_argument("--sap-only", action="store_true", help="so o canal SAP (nao se inscreve no resto)")

    args = p.parse_args()
    handler = {"scan": cmd_scan, "explore": cmd_explore, "listen": cmd_listen, "unpair": cmd_unpair}[args.cmd]
    try:
        asyncio.run(handler(args))
    except KeyboardInterrupt:
        print("\n[ok] interrompido pelo usuario")


if __name__ == "__main__":
    main()
