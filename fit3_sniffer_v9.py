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

import contextlib
import time

try:
    import fit3_frame_v2 as ff  # versao que entende o sentido (00/01) e os ACKs
except ImportError:
    import fit3_frame as ff
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
        rec = {"kind": direction, "uuid": uuid, "name": short_uuid(uuid), "len": len(data), "hex": hexs(data)}
        p = ff.parse(data)
        if p.get("ok") and "canal" in p:
            print(f"{'':>30}frame OK  canal=0x{p['canal']:02X} cmd=0x{p['cmd']:02X} dados={hexs(p['dados'])}")
            rec.update({"canal": p["canal"], "cmd": p["cmd"], "dados": hexs(p["dados"])})
        self._write(rec)


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
# vibrar: repete o inicio de sessao do Fit3 Bridge e manda "achar pulseira"
# --------------------------------------------------------------------------
TZ_FRAME = bytes.fromhex(
    "00 27 1A 40 01 40 08 08 4C 27 01 09 01 30 2A 28 1A 68 6F 72 61 20 65 73 74 C3 A1 6E 64 61 72 20 "
    "64 65 20 42 72 61 73 69 6C 69 61 F3 29")
CONFIG_FRAME = bytes.fromhex(
    "00 42 31 80 01 40 0A 0A A1 0B A1 04 33 C0 01 C1 00 C2 02 A2 3B E7 6A 00 B1 01 AE 01 04 03 00 AC 03 "
    "AD 02 01 C3 01 01 03 01 02 05 03 04 10 27 B3 15 03 0D 01 70 17 02 0A 00 03 08 00 0C E9 03 0A FC 03 "
    "01 01 01 00 A2 89")


def _winrt_enum():
    try:
        from winrt.windows.devices import enumeration as en  # bleak >= 0.22
    except ImportError:  # pragma: no cover
        from bleak_winrt.windows.devices import enumeration as en  # bleak antigo
    return en


async def pair_with_pin(client: BleakClient, log: Logger) -> bool:
    """Pareamento do jeito do iPhone: a pulseira mostra um numero e voce digita aqui.
    Usa o pareamento customizado do Windows (WinRT) na MESMA conexao."""
    req = getattr(getattr(client, "_backend", None), "_requester", None)
    if req is None:
        log.event("nao achei o objeto WinRT do bleak (so funciona no Windows)")
        return False
    en = _winrt_enum()
    K, PL, ST = en.DevicePairingKinds, en.DevicePairingProtectionLevel, en.DevicePairingResultStatus
    info = req.device_information
    if info.pairing.is_paired:
        log.event("AVISO: o Windows ja tem um pareamento salvo. Remova em Configuracoes > Bluetooth e rode de novo.")
    custom = info.pairing.custom

    def on_request(_sender, args) -> None:
        kind = args.pairing_kind
        log.event(f"pedido de pareamento: tipo={kind!r} pin_do_pc={getattr(args, 'pin', '')!r}")
        if kind == K.PROVIDE_PIN:
            deferral = args.get_deferral()
            try:
                pin = input("\n>>> Digite o numero que apareceu na pulseira e aperte Enter: ").strip()
                log.event(f"PIN digitado ({len(pin)} digitos)")
                args.accept(pin)
            finally:
                deferral.complete()
        elif kind == K.CONFIRM_PIN_MATCH:
            print(f"\n>>> Confira: a pulseira deve mostrar {args.pin}. Confirme na pulseira tambem.")
            args.accept()
        elif kind == K.DISPLAY_PIN:
            print(f"\n>>> Digite na pulseira: {args.pin}")
            args.accept()
        else:
            args.accept()

    token = custom.add_pairing_requested(on_request)
    try:
        wanted = int(K.CONFIRM_ONLY) | int(K.DISPLAY_PIN) | int(K.PROVIDE_PIN) | int(K.CONFIRM_PIN_MATCH)
        try:
            kinds = K(wanted)
        except ValueError:
            kinds = K.PROVIDE_PIN
        for level in (PL.ENCRYPTION_AND_AUTHENTICATION, PL.ENCRYPTION):
            if not client.is_connected:
                break
            res = await custom.pair_with_protection_level_async(kinds, level)
            log.event(f"pareamento ({level!r}) -> {res.status!r}")
            if res.status in (ST.PAIRED, ST.ALREADY_PAIRED):
                return True
    except Exception as e:  # noqa: BLE001
        log.event(f"pareamento com PIN falhou: {e!r}")
    finally:
        custom.remove_pairing_requested(token)
    return False


async def pair_inline(client: BleakClient, log: Logger) -> bool:
    if await pair_with_pin(client, log):
        return True
    log.event("tentando o pareamento padrao do bleak como ultimo recurso")
    try:
        return bool(await client.pair())
    except Exception as e:  # noqa: BLE001
        log.event(f"pair() falhou: {e!r}")
        return False


async def cmd_vibrar(args) -> None:
    dev = await find_band(args.address)
    log = Logger("vibrar")
    disconnected = asyncio.Event()

    def on_disconnect(_c) -> None:
        log.event("desconectada")
        disconnected.set()

    def on_notify(sender: BleakGATTCharacteristic, data: bytearray) -> None:
        log.data("RX", sender.uuid, bytes(data))

    try:
        async with BleakClient(dev, disconnected_callback=on_disconnect) as client:
            log.event(f"conectado: {dev.name} {dev.address}  MTU={safe_mtu(client)}")
            sap_notify = sap_write = None
            for svc in client.services:
                if svc.uuid.lower() != SAP_SERVICE:
                    continue
                for ch in svc.characteristics:
                    props = set(ch.properties)
                    if props & {"notify", "indicate"}:
                        sap_notify = ch
                    if props & {"write", "write-without-response"}:
                        sap_write = ch
            if not (sap_notify and sap_write):
                log.event("canal SAP nao encontrado")
                return
            if not args.no_pair:
                if not await pair_inline(client, log):
                    log.event("pareamento na mesma conexao falhou")
                    return
                await asyncio.sleep(0.5)
                if not still_connected(client, log):
                    return
            try:
                await asyncio.wait_for(client.start_notify(sap_notify, on_notify), timeout=8.0)
                log.event("SAP notify ativo")
            except Exception as e:  # noqa: BLE001
                log.event(f"nao consegui ativar o SAP notify: {e!r}")
                return

            async def send(label: str, frame: bytes, pause: float = 0.15) -> bool:
                if not client.is_connected:
                    return False
                log.data("TX", sap_write.uuid, frame)
                try:
                    await client.write_gatt_char(sap_write, frame, response="write" in sap_write.properties)
                except Exception as e:  # noqa: BLE001
                    log.event(f"{label}: escrita falhou: {e!r}")
                    return False
                await asyncio.sleep(pause)
                return True

            seq = [
                ("abrir sessao", bytes.fromhex(SESSION_OPEN_HEX)),
                ("setup 1", ff.build(bytes.fromhex("01 40 01 01 01 04 02 05 00 0E"))),
                ("setup 2", ff.build(bytes.fromhex("01 40 01 01 02 01 01"))),
                ("horario", ff.time_sync(time.time())),
                ("fuso", TZ_FRAME),
                ("config", CONFIG_FRAME),
                ("0B/02", ff.cmd(0x0B, b"\x02")),
                ("07/0D", ff.cmd(0x07, b"\x0D")),
                ("07/0E", ff.cmd(0x07, b"\x0E")),
            ]
            for label, fr in seq:
                if not await send(label, fr):
                    return
            log.event("sessao enviada; esperando 2 s antes de vibrar")
            await asyncio.sleep(2.0)
            for _ in range(2):
                await send("vibrar ON", ff.FIND_VIBRAR_ON, 1.0)
            await asyncio.sleep(2.0)
            for _ in range(2):
                await send("vibrar OFF", ff.FIND_VIBRAR_OFF, 0.5)
            log.event(f"escutando RX por {args.seconds} s")
            try:
                await asyncio.wait_for(disconnected.wait(), timeout=args.seconds)
            except asyncio.TimeoutError:
                log.event("tempo esgotado, encerrando")
    except Exception as e:  # noqa: BLE001
        log.event(f"falha: {e!r}")
    print(f"\n[log] pronto: {log.path.resolve()}")


# --------------------------------------------------------------------------
# testar: abre a sessao e testa candidatos para "concluir a configuracao"
# --------------------------------------------------------------------------
def candidatos(last_a2: bytes | None):
    """(rotulo, payload sem framing). DIR=01, flags=40."""
    def p(ch, cmd, data=b""):
        return bytes([0x01, 0x40, ch, ch, cmd]) + data
    lst = [
        ("resp ch04 46 (a 86 da pulseira)", p(0x04, 0x46, b"\x00")),
        ("resp ch07 50 (a 90 da pulseira)", p(0x07, 0x50, b"\x01")),
        ("resp ch0A 49 (a 89 da pulseira)", p(0x0A, 0x49)),
    ]
    if last_a2 is not None:
        lst.append(("resp ch0A 62 eco do A2", p(0x0A, 0x62, last_a2)))
    lst += [
        ("ch09 41 01 01 (ack do estado)", p(0x09, 0x41, b"\x01\x01")),
        ("ch09 01 01 00", p(0x09, 0x01, b"\x01\x00")),
        ("ch09 01 01 03", p(0x09, 0x01, b"\x01\x03")),
        ("ch09 02 01", p(0x09, 0x02, b"\x01")),
        ("ch01 04", p(0x01, 0x04)),
        ("ch01 05", p(0x01, 0x05)),
        ("ch01 84 01", p(0x01, 0x84, b"\x01")),
    ]
    return lst


async def cmd_testar(args) -> None:
    dev = await find_band(args.address)
    # tira o pareamento antigo do Windows (a pulseira em config esquece a chave)
    try:
        async with BleakClient(dev) as c0:
            print(f"[..] limpando pareamento antigo: unpair() -> {await c0.unpair()}")
    except Exception as e:  # noqa: BLE001
        print(f"[..] (sem pareamento antigo para limpar: {e!r})")
    await asyncio.sleep(2.0)
    dev = await find_band(args.address)

    log = Logger("testar")
    disconnected = asyncio.Event()
    state = {"last_a2": None, "rx_count": 0}

    def on_disconnect(_c) -> None:
        log.event("desconectada")
        disconnected.set()

    def on_notify(sender: BleakGATTCharacteristic, data: bytearray) -> None:
        b = bytes(data)
        state["rx_count"] += 1
        log.data("RX", sender.uuid, b)
        pr = ff.parse(b)
        if pr.get("canal") == 0x0A and pr.get("cmd") == 0xA2:
            state["last_a2"] = pr["dados"]

    try:
        async with BleakClient(dev, disconnected_callback=on_disconnect) as client:
            log.event(f"conectado: {dev.name} {dev.address}  MTU={safe_mtu(client)}")
            sap_notify = sap_write = None
            for svc in client.services:
                if svc.uuid.lower() != SAP_SERVICE:
                    continue
                for ch in svc.characteristics:
                    props = set(ch.properties)
                    if props & {"notify", "indicate"}:
                        sap_notify = ch
                    if props & {"write", "write-without-response"}:
                        sap_write = ch
            if not await pair_inline(client, log):
                log.event("pareamento falhou")
                return
            await asyncio.sleep(0.5)
            await asyncio.wait_for(client.start_notify(sap_notify, on_notify), timeout=8.0)
            log.event("SAP notify ativo")

            async def send(label: str, frame: bytes, pause: float = 0.15) -> bool:
                if not client.is_connected:
                    return False
                log.event(f">> {label}")
                log.data("TX", sap_write.uuid, frame)
                try:
                    await client.write_gatt_char(sap_write, frame, response="write" in sap_write.properties)
                except Exception as e:  # noqa: BLE001
                    log.event(f"{label}: escrita falhou: {e!r}")
                    return False
                await asyncio.sleep(pause)
                return True

            seq = [
                ("abrir sessao", bytes.fromhex(SESSION_OPEN_HEX)),
                ("setup 1", ff.build(bytes.fromhex("01 40 01 01 01 04 02 05 00 0E"))),
                ("setup 2", ff.build(bytes.fromhex("01 40 01 01 02 01 01"))),
                ("horario", ff.time_sync(time.time())),
                ("fuso", TZ_FRAME),
                ("config", CONFIG_FRAME),
                ("0B/02", ff.cmd(0x0B, b"\x02")),
                ("07/0D", ff.cmd(0x07, b"\x0D")),
                ("07/0E", ff.cmd(0x07, b"\x0E")),
            ]
            for label, fr in seq:
                if not await send(label, fr):
                    return
            log.event("sessao aberta; esperando o primeiro A2 da pulseira (ate 25 s)")
            for _ in range(50):
                if state["last_a2"] is not None or disconnected.is_set():
                    break
                await asyncio.sleep(0.5)

            for i, (label, payload) in enumerate(candidatos(state["last_a2"]), 1):
                if disconnected.is_set():
                    break
                before = state["rx_count"]
                await send(f"[{i}] {label}", ff.build(payload), 3.0)
                log.event(f"[{i}] {state['rx_count'] - before} frames recebidos depois deste teste")
                ans = (await asyncio.to_thread(
                    input, f"\n>>> [{i}] '{label}': a tela da pulseira mudou? (Enter=nao / s=sim / q=parar): "
                )).strip().lower()
                log.event(f"[{i}] resposta do usuario: {ans or 'nao'}")
                if ans in ("s", "q"):
                    break
            log.event("fim dos testes; escutando mais 15 s")
            try:
                await asyncio.wait_for(disconnected.wait(), timeout=15)
            except asyncio.TimeoutError:
                pass
    except Exception as e:  # noqa: BLE001
        log.event(f"falha: {e!r}")
    print(f"\n[log] pronto: {log.path.resolve()}")


# --------------------------------------------------------------------------
# notificar: manda uma notificacao no formato visto no Fit3 Bridge (canal 07, cmd 80)
# --------------------------------------------------------------------------
def notif_payload(remetente: str, texto: str, app: str, notif_id: int) -> bytes:
    """Monta o payload a partir do frame real do Fit3 Bridge, trocando so os campos conhecidos:
    03 = titulo (1 B de tamanho), 04 = texto (2 B LE), 0E = nome do app (1 B),
    02 = horario em ms (8 B LE), id em texto (5 digitos) e nome do icone APP_ICON_<id>."""
    nid = f"{notif_id % 100000:05d}".encode()
    t = remetente.encode("utf-8")[:60]
    b = texto.encode("utf-8")[:400]
    a = app.encode("utf-8")[:40]
    ts = int(time.time() * 1000).to_bytes(8, "little")
    data = (
        b"\x0B\x00\x01\x01\x01\x00\x00\x00\x06\x05" + nid
        + b"\x02" + ts
        + b"\x03" + bytes([len(t)]) + t
        + b"\x04" + len(b).to_bytes(2, "little") + b
        + b"\x0E" + bytes([len(a)]) + a
        + b"\x0F\x01\x10\x00\x09\x0E" + b"APP_ICON_" + nid
        + b"\x13\x01"
    )
    return bytes([0x01, 0x40, 0x07, 0x07, 0x80]) + data


async def cmd_notificar(args) -> None:
    dev = await find_band(args.address)
    try:
        async with BleakClient(dev) as c0:
            print(f"[..] limpando pareamento antigo: unpair() -> {await c0.unpair()}")
    except Exception as e:  # noqa: BLE001
        print(f"[..] (sem pareamento antigo para limpar: {e!r})")
    await asyncio.sleep(2.0)
    dev = await find_band(args.address)

    log = Logger("notificar")
    disconnected = asyncio.Event()

    def on_disconnect(_c) -> None:
        log.event("desconectada")
        disconnected.set()

    def on_notify(sender: BleakGATTCharacteristic, data: bytearray) -> None:
        log.data("RX", sender.uuid, bytes(data))

    try:
        async with BleakClient(dev, disconnected_callback=on_disconnect) as client:
            log.event(f"conectado: {dev.name} {dev.address}  MTU={safe_mtu(client)}")
            sap_notify = sap_write = None
            for svc in client.services:
                if svc.uuid.lower() != SAP_SERVICE:
                    continue
                for ch in svc.characteristics:
                    props = set(ch.properties)
                    if props & {"notify", "indicate"}:
                        sap_notify = ch
                    if props & {"write", "write-without-response"}:
                        sap_write = ch
            if not await pair_inline(client, log):
                log.event("pareamento falhou")
                return
            await asyncio.sleep(0.5)
            await asyncio.wait_for(client.start_notify(sap_notify, on_notify), timeout=8.0)

            async def send(label: str, frame: bytes, pause: float = 0.15) -> bool:
                if not client.is_connected:
                    return False
                log.event(f">> {label}")
                log.data("TX", sap_write.uuid, frame)
                try:
                    await client.write_gatt_char(sap_write, frame, response="write" in sap_write.properties)
                except Exception as e:  # noqa: BLE001
                    log.event(f"{label}: escrita falhou: {e!r}")
                    return False
                await asyncio.sleep(pause)
                return True

            seq = [
                ("abrir sessao", bytes.fromhex(SESSION_OPEN_HEX)),
                ("setup 1", ff.build(bytes.fromhex("01 40 01 01 01 04 02 05 00 0E"))),
                ("setup 2", ff.build(bytes.fromhex("01 40 01 01 02 01 01"))),
                ("horario", ff.time_sync(time.time())),
                ("fuso", TZ_FRAME),
                ("config", CONFIG_FRAME),
                ("0B/02", ff.cmd(0x0B, b"\x02")),
                ("07/0D", ff.cmd(0x07, b"\x0D")),
                ("07/0E", ff.cmd(0x07, b"\x0E")),
                ("concluir config 01/84", ff.build(bytes.fromhex("01 40 01 01 84 01"))),
            ]
            for label, fr in seq:
                if not await send(label, fr):
                    return
            await asyncio.sleep(2.0)
            frame = ff.build(notif_payload(args.de, args.texto, args.app, int(time.time())))
            await send(f"notificacao: {args.de}: {args.texto}", frame, 1.0)
            log.event(f"escutando RX por {args.seconds} s")
            try:
                await asyncio.wait_for(disconnected.wait(), timeout=args.seconds)
            except asyncio.TimeoutError:
                pass
    except Exception as e:  # noqa: BLE001
        log.event(f"falha: {e!r}")
    print(f"\n[log] pronto: {log.path.resolve()}")


# --------------------------------------------------------------------------
# Sessao reutilizavel: limpa pareamento, pareia com PIN, abre sessao SAP
# --------------------------------------------------------------------------
HR_MEAS_UUID = "00002a37-0000-1000-8000-00805f9b34fb"


def parse_hr(data: bytes):
    """Heart Rate Measurement (0x2A37) padrao Bluetooth."""
    if not data:
        return None
    flags = data[0]
    return int.from_bytes(data[1:3], "little") if flags & 0x01 else data[1]


@contextlib.asynccontextmanager
async def sessao(args, nome_log: str, on_rx=None, concluir=True):
    dev = await find_band(args.address)
    try:
        async with BleakClient(dev) as c0:
            print(f"[..] limpando pareamento antigo: unpair() -> {await c0.unpair()}")
    except Exception as e:  # noqa: BLE001
        print(f"[..] (sem pareamento antigo para limpar: {e!r})")
    await asyncio.sleep(2.0)
    dev = await find_band(args.address)
    log = Logger(nome_log)
    disconnected = asyncio.Event()

    def on_disconnect(_c) -> None:
        log.event("desconectada")
        disconnected.set()

    def on_notify(sender: BleakGATTCharacteristic, data: bytearray) -> None:
        b = bytes(data)
        log.data("RX", sender.uuid, b)
        if on_rx:
            on_rx(sender.uuid.lower(), b)

    async with BleakClient(dev, disconnected_callback=on_disconnect) as client:
        log.event(f"conectado: {dev.name} {dev.address}  MTU={safe_mtu(client)}")
        sap_notify = sap_write = None
        for svc in client.services:
            if svc.uuid.lower() != SAP_SERVICE:
                continue
            for ch in svc.characteristics:
                props = set(ch.properties)
                if props & {"notify", "indicate"}:
                    sap_notify = ch
                if props & {"write", "write-without-response"}:
                    sap_write = ch
        if not await pair_inline(client, log):
            raise RuntimeError("pareamento falhou")
        await asyncio.sleep(0.5)
        await asyncio.wait_for(client.start_notify(sap_notify, on_notify), timeout=8.0)

        async def send(label: str, frame: bytes, pause: float = 0.15) -> bool:
            if not client.is_connected:
                return False
            log.event(f">> {label}")
            log.data("TX", sap_write.uuid, frame)
            try:
                await client.write_gatt_char(sap_write, frame, response="write" in sap_write.properties)
            except Exception as e:  # noqa: BLE001
                log.event(f"{label}: escrita falhou: {e!r}")
                return False
            await asyncio.sleep(pause)
            return True

        seq = [
            ("abrir sessao", bytes.fromhex(SESSION_OPEN_HEX)),
            ("setup 1", ff.build(bytes.fromhex("01 40 01 01 01 04 02 05 00 0E"))),
            ("setup 2", ff.build(bytes.fromhex("01 40 01 01 02 01 01"))),
            ("horario", ff.time_sync(time.time())),
            ("fuso", TZ_FRAME),
            ("config", CONFIG_FRAME),
            ("0B/02", ff.cmd(0x0B, b"\x02")),
            ("07/0D", ff.cmd(0x07, b"\x0D")),
            ("07/0E", ff.cmd(0x07, b"\x0E")),
        ]
        if concluir:
            seq.append(("concluir config 01/84", ff.build(bytes.fromhex("01 40 01 01 84 01"))))
        for label, fr in seq:
            if not await send(label, fr):
                raise RuntimeError("conexao caiu abrindo a sessao")
        await asyncio.sleep(1.0)
        yield client, send, log, disconnected
    print(f"\n[log] pronto: {log.path.resolve()}")


# --------------------------------------------------------------------------
# enviar: manda um payload qualquer (para experimentar a mao)
# --------------------------------------------------------------------------
async def cmd_enviar(args) -> None:
    payloads = [bytes.fromhex(x) for x in args.payload]
    async with sessao(args, "enviar") as (client, send, log, disc):
        for pl in payloads:
            await send(f"payload {pl.hex(' ')}", ff.build(pl), args.pausa)
        try:
            await asyncio.wait_for(disc.wait(), timeout=args.seconds)
        except asyncio.TimeoutError:
            pass


# --------------------------------------------------------------------------
# idioma: 0B/01 com "04 <id> 00" (visto no Fit3 Bridge: id 13)
# --------------------------------------------------------------------------
def idioma_frame(lang_id: int) -> bytes:
    return ff.cmd(0x0B, bytes([0x01, 0x04, lang_id & 0xFF, 0x00]))


async def cmd_idioma(args) -> None:
    async with sessao(args, "idioma") as (client, send, log, disc):
        if args.id is not None:
            await send(f"idioma id={args.id}", idioma_frame(args.id), 3.0)
        else:
            print("\n>>> Abra uma tela com texto na pulseira (ex.: Configuracoes).")
            print(">>> Anote o numero quando o texto mudar para portugues e aperte Ctrl+C.\n")
            for lid in range(args.de, args.ate + 1):
                if disc.is_set():
                    break
                print(f"=== testando idioma id {lid} ===")
                await send(f"idioma id={lid}", idioma_frame(lid), args.pausa)
        try:
            await asyncio.wait_for(disc.wait(), timeout=5)
        except asyncio.TimeoutError:
            pass


# --------------------------------------------------------------------------
# bpm: tenta ler o perfil padrao de frequencia cardiaca (0x180D / 0x2A37)
# --------------------------------------------------------------------------
async def cmd_bpm(args) -> None:
    def on_rx(uuid: str, data: bytes) -> None:
        if uuid == HR_MEAS_UUID:
            print(f"    ❤️  {parse_hr(data)} bpm")

    async with sessao(args, "bpm", on_rx=on_rx) as (client, send, log, disc):
        try:
            await asyncio.wait_for(client.start_notify(HR_MEAS_UUID, lambda s, d: (log.data("RX", s.uuid, bytes(d)), on_rx(HR_MEAS_UUID, bytes(d)))), timeout=6.0)
            log.event("inscrito no HR_MEAS (2A37)")
        except Exception as e:  # noqa: BLE001
            log.event(f"nao consegui inscrever no HR_MEAS: {e!r}")
        print("\n>>> Abra a medicao de batimentos na pulseira e espere.\n")
        try:
            await asyncio.wait_for(disc.wait(), timeout=args.seconds)
        except asyncio.TimeoutError:
            pass


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
    vb = sub.add_parser("vibrar", help="abre sessao como o Fit3 Bridge e faz a pulseira vibrar")
    vb.add_argument("--address", help="endereco BLE da pulseira")
    vb.add_argument("--seconds", type=int, default=30, help="tempo escutando RX depois (padrao 30)")
    vb.add_argument("--no-pair", action="store_true", help="nao pareia na conexao (usa o vinculo do Windows)")
    ts = sub.add_parser("testar", help="abre a sessao e testa candidatos para concluir a configuracao")
    ts.add_argument("--address", help="endereco BLE da pulseira")
    nt = sub.add_parser("notificar", help="manda uma notificacao para a pulseira")
    nt.add_argument("--address", help="endereco BLE da pulseira")
    nt.add_argument("--de", default="Ana", help="remetente / titulo")
    nt.add_argument("--texto", default="Tô chegando!! 🏃💨 Me espera 😄", help="texto da mensagem")
    nt.add_argument("--app", default="WhatsApp", help="nome do app")
    nt.add_argument("--seconds", type=int, default=15, help="tempo escutando RX depois")
    en = sub.add_parser("enviar", help="manda payloads (hex, sem framing) depois de abrir a sessao")
    en.add_argument("payload", nargs="+", help='ex.: "01 40 1F 1F 0D"')
    en.add_argument("--address")
    en.add_argument("--pausa", type=float, default=1.5)
    en.add_argument("--seconds", type=int, default=10)
    idm = sub.add_parser("idioma", help="troca o idioma (--id N) ou varre uma faixa (--de A --ate B)")
    idm.add_argument("--address")
    idm.add_argument("--id", type=int)
    idm.add_argument("--de", type=int, default=0)
    idm.add_argument("--ate", type=int, default=40)
    idm.add_argument("--pausa", type=float, default=4.0)
    bp = sub.add_parser("bpm", help="tenta ler batimentos pelo perfil padrao 0x2A37")
    bp.add_argument("--address")
    bp.add_argument("--seconds", type=int, default=90)
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
    handler = {"scan": cmd_scan, "explore": cmd_explore, "listen": cmd_listen, "unpair": cmd_unpair, "vibrar": cmd_vibrar, "testar": cmd_testar, "notificar": cmd_notificar,
               "enviar": cmd_enviar, "idioma": cmd_idioma, "bpm": cmd_bpm}[args.cmd]
    try:
        asyncio.run(handler(args))
    except KeyboardInterrupt:
        print("\n[ok] interrompido pelo usuario")


if __name__ == "__main__":
    main()
