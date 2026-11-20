#!/usr/bin/env python3
"""
analisar_btsnoop.py - Decodifica uma captura HCI (btsnoop_hci.log) do Android focando no Galaxy Fit3.

O que extrai:
  - Conexoes BLE (endereco, inicio/fim, motivo da desconexao)
  - Pareamento SMP: capacidades de E/S, MITM, Secure Connections, falhas
  - Reconexao: se o celular reusa a chave (LE Start Encryption / LTK) sem parear de novo
  - Descoberta de caracteristicas (mapa handle -> UUID)
  - Todo o trafego ATT, com remontagem de pacotes fragmentados e de escritas longas
  - Frames do canal SAP decodificados no nosso formato (DIR 40 CH CH CMD dados) + CRC conferido
  - Batimentos do perfil padrao (2A37)

Saidas (ao lado do arquivo de entrada):
  <nome>_timeline.txt      linha do tempo legivel
  <nome>_frames.jsonl      um frame decodificado por linha (para analise posterior)
  <nome>_resumo.md         resumo: pareamento, reconexoes, contagem por canal/comando

Uso:
    python analisar_btsnoop.py capturas\\<data>\\btsnoop_hci.log
    python analisar_btsnoop.py captura.log --todos      # inclui conexoes sem trafego SAP (fones etc.)
"""

from __future__ import annotations

import argparse
import collections
import datetime as dt
import json
import struct
import sys
from pathlib import Path

BTSNOOP_EPOCH_DELTA_US = 0x00DCDDB30F2F8000

KNOWN_UUIDS = {
    "797ae4e9-2e58-4fe8-b48d-b5c79599fb9b": "SAP_NOTIFY",
    "63e30bad-4206-4596-839f-e47cbf7a4b5d": "SAP_WRITE",
    "2a37": "HR_MEAS",
    "2a38": "HR_LOC",
    "2a39": "HR_CTRL",
    "2a05": "SVC_CHANGED",
    "4af351bb-d6f7-4612-a8e3-8dce6ca13e7b": "SAMSUNG_4AF3",
    "853bd048-b043-4dcd-b073-de49569e1194": "SAMSUNG_853B",
    "66aeea2f-1edf-445b-bcfb-7ef330268073": "SAMSUNG_66AE",
    "8ac32d3f-5cb9-4d44-bec2-ee689169f626": "SAMSUNG_8AC3",
}
IO_CAPS = {0: "DisplayOnly", 1: "DisplayYesNo", 2: "KeyboardOnly", 3: "NoInputNoOutput", 4: "KeyboardDisplay"}
SMP_OPS = {1: "Pairing Request", 2: "Pairing Response", 3: "Pairing Confirm", 4: "Pairing Random",
           5: "Pairing Failed", 6: "Encryption Information (LTK)", 7: "Central Identification",
           8: "Identity Information (IRK)", 9: "Identity Address", 10: "Signing Information",
           11: "Security Request", 12: "Pairing Public Key", 13: "Pairing DHKey Check", 14: "Keypress Notification"}
SMP_FAIL = {1: "Passkey Entry Failed", 2: "OOB Not Available", 3: "Authentication Requirements", 4: "Confirm Value Failed",
            5: "Pairing Not Supported", 6: "Encryption Key Size", 7: "Command Not Supported", 8: "Unspecified Reason",
            9: "Repeated Attempts", 10: "Invalid Parameters", 11: "DHKey Check Failed", 12: "Numeric Comparison Failed"}
DISC_REASON = {0x08: "timeout", 0x13: "remoto encerrou", 0x16: "local encerrou", 0x05: "falha de autenticacao",
               0x06: "chave ausente (PIN/Key Missing)", 0x3D: "falha de MIC", 0x3E: "falha ao estabelecer"}


# --------------------------------------------------------------------------
# Formato de frame do Fit3 (igual ao fit3_frame.py, embutido para o script ficar sozinho)
# --------------------------------------------------------------------------
def crc16_arc(data: bytes) -> int:
    crc = 0
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


def parse_fit3(frame: bytes) -> dict | None:
    if frame[:2] in (b"\x68\x14", b"\x68\x15"):
        return {"tipo": "handshake_sap", "lado": "pulseira" if frame[1] == 0x14 else "app"}
    if len(frame) < 6:
        return None
    ln = int.from_bytes(frame[0:2], "big")
    if len(frame) != ln + 6:
        return None
    if int.from_bytes(frame[2:4], "big") != crc16_arc(frame[0:2]):
        return None
    payload = frame[4:-2]
    if int.from_bytes(frame[-2:], "big") != crc16_arc(payload):
        return {"tipo": "frame", "crc_ok": False, "payload": payload.hex(" ")}
    if len(payload) == 4 and payload[0] == 0x88:
        return {"tipo": "ack", "payload": payload.hex(" ")}
    if len(payload) >= 5 and payload[0] in (0, 1) and payload[2] == payload[3]:
        return {"tipo": "frame", "crc_ok": True, "dir": "app->pulseira" if payload[0] == 1 else "pulseira->app",
                "flags": payload[1], "canal": payload[2], "cmd": payload[4], "dados": payload[5:].hex(" ")}
    return {"tipo": "frame", "crc_ok": True, "payload": payload.hex(" ")}


# --------------------------------------------------------------------------
def uuid_str(raw: bytes) -> str:
    if len(raw) == 2:
        return f"{int.from_bytes(raw, 'little'):04x}"
    h = raw[::-1].hex()
    return f"{h[0:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:32]}"


def fmt_addr(raw: bytes) -> str:
    return ":".join(f"{b:02X}" for b in raw[::-1])


def ascii_view(b: bytes) -> str:
    return "".join(chr(c) if 32 <= c < 127 else "." for c in b)


class Conn:
    def __init__(self, handle: int, addr: str, t: float):
        self.handle, self.addr, self.t0 = handle, addr, t
        self.t1 = None
        self.reason = None
        self.handles: dict[int, str] = {}       # value handle -> uuid
        self.sap = 0
        self.rx_buf = {0: b"", 1: b""}          # remontagem L2CAP por direcao
        self.rx_need = {0: 0, 1: 0}
        self.prep: dict[int, bytearray] = {}    # escritas longas (Prepare Write)
        self.encrypted = False
        self.paired_here = False
        self.ltk_reuse = False


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("arquivo")
    ap.add_argument("--todos", action="store_true", help="mostrar todas as conexoes, nao so a da pulseira")
    args = ap.parse_args()
    path = Path(args.arquivo)
    raw = path.read_bytes()
    if raw[:8] != b"btsnoop\x00":
        sys.exit("[erro] nao parece um arquivo btsnoop (cabecalho invalido)")
    _, datalink = struct.unpack(">II", raw[8:16])
    if datalink not in (1001, 1002):
        print(f"[aviso] datalink {datalink} inesperado; tentando como H4 (1002)")

    eventos: list[tuple[float, int, str]] = []      # (t, conn_handle ou -1, texto)
    frames: list[dict] = []
    conns: dict[int, Conn] = {}
    todas: list[Conn] = []
    t_first = None
    off = 16

    def ev(t, h, txt):
        eventos.append((t, h, txt))

    def handle_att(c: Conn, t: float, sent: bool, pdu: bytes):
        op = pdu[0]
        quem = "celular->pulseira" if sent else "pulseira->celular"
        if op in (0x02, 0x03):
            ev(t, c.handle, f"ATT MTU {'pedido' if op == 2 else 'resposta'}: {int.from_bytes(pdu[1:3], 'little')}")
            return
        if op == 0x09 and len(pdu) > 2:          # Read By Type Response (descoberta de caracteristicas)
            ln = pdu[1]
            for i in range(2, len(pdu) - ln + 1, ln):
                item = pdu[i:i + ln]
                if ln in (7, 21):
                    vh = int.from_bytes(item[3:5], "little")
                    c.handles[vh] = uuid_str(item[5:])
            return
        value = handle = None
        if op in (0x12, 0x52, 0x1B, 0x1D):        # write req / write cmd / notify / indicate
            handle = int.from_bytes(pdu[1:3], "little")
            value = pdu[3:]
        elif op == 0x16:                           # Prepare Write Request
            handle = int.from_bytes(pdu[1:3], "little")
            ofs = int.from_bytes(pdu[3:5], "little")
            buf = c.prep.setdefault(handle, bytearray())
            if ofs == 0:
                buf.clear()
            buf[ofs:ofs + len(pdu) - 5] = pdu[5:]
            return
        elif op == 0x18 and len(pdu) > 1 and pdu[1] == 1:   # Execute Write
            for h, buf in c.prep.items():
                handle_value(c, t, sent, h, bytes(buf), "escrita longa")
            c.prep.clear()
            return
        elif op == 0x01:
            ev(t, c.handle, f"ATT erro: opcode 0x{pdu[1]:02X} handle 0x{int.from_bytes(pdu[2:4], 'little'):04X} codigo 0x{pdu[4]:02X}")
            return
        if value is not None:
            tipo = {0x12: "write", 0x52: "write-cmd", 0x1B: "notify", 0x1D: "indicate"}[op]
            handle_value(c, t, sent, handle, value, tipo)

    def handle_value(c: Conn, t: float, sent: bool, handle: int, value: bytes, tipo: str):
        uuid = c.handles.get(handle, "")
        nome = KNOWN_UUIDS.get(uuid, uuid[:8] if uuid else f"h0x{handle:04X}")
        quem = "CEL->PUL" if sent else "PUL->CEL"
        p = parse_fit3(value)
        rec = {"t": round(t - t_first, 3), "conn": c.handle, "quem": quem, "carac": nome, "tipo_att": tipo,
               "len": len(value), "hex": value.hex(" ")}
        if p:
            c.sap += 1
            rec.update(p)
            if p["tipo"] == "frame" and "canal" in p:
                dados = bytes.fromhex(p["dados"]) if p["dados"] else b""
                txt = f"{quem} canal 0x{p['canal']:02X} cmd 0x{p['cmd']:02X} {p['dados'][:90]}"
                if any(32 <= x < 127 for x in dados):
                    txt += f"  |{ascii_view(dados)[:60]}|"
            elif p["tipo"] == "ack":
                txt = f"{quem} ack {p['payload']}"
            elif p["tipo"] == "handshake_sap":
                txt = f"{quem} HANDSHAKE SAP ({len(value)} B)  |{ascii_view(value)[:70]}|"
            else:
                txt = f"{quem} frame {'CRC OK' if p.get('crc_ok') else 'CRC ERRADO'} {p.get('payload', '')[:90]}"
        elif uuid == "2a37" or nome == "HR_MEAS":
            bpm = int.from_bytes(value[1:3], "little") if value and value[0] & 1 else (value[1] if len(value) > 1 else None)
            contato = bool(value and value[0] & 0x02)
            rec.update({"tipo": "hr", "bpm": bpm, "contato": contato})
            txt = f"{quem} BPM {bpm} ({'com' if contato else 'sem'} contato)"
        else:
            txt = f"{quem} {tipo} {nome}: {value[:40].hex(' ')}"
        frames.append(rec)
        ev(t, c.handle, txt)

    def handle_smp(c: Conn, t: float, sent: bool, pdu: bytes):
        op = pdu[0]
        quem = "celular" if sent else "pulseira"
        nome = SMP_OPS.get(op, f"0x{op:02X}")
        txt = f"SMP {quem}: {nome}"
        if op in (1, 2) and len(pdu) >= 7:
            io_, oob, auth, maxk = pdu[1], pdu[2], pdu[3], pdu[4]
            txt += (f" | IO={IO_CAPS.get(io_, io_)} OOB={oob} bonding={'sim' if auth & 3 else 'nao'} "
                    f"MITM={'sim' if auth & 4 else 'nao'} SecureConn={'sim' if auth & 8 else 'nao'} "
                    f"keypress={'sim' if auth & 16 else 'nao'} chave={maxk}B")
            c.paired_here = True
        elif op == 5 and len(pdu) >= 2:
            txt += f" | motivo: {SMP_FAIL.get(pdu[1], pdu[1])}"
        elif op == 11 and len(pdu) >= 2:
            a = pdu[1]
            txt += f" | MITM={'sim' if a & 4 else 'nao'} SecureConn={'sim' if a & 8 else 'nao'}"
        ev(t, c.handle, txt)

    while off + 24 <= len(raw):
        orig, incl, flags, drops, ts = struct.unpack(">IIIIq", raw[off:off + 24])
        pkt = raw[off + 24: off + 24 + incl]
        off += 24 + incl
        t = (ts - BTSNOOP_EPOCH_DELTA_US) / 1e6
        if t_first is None:
            t_first = t
        sent = not (flags & 1)
        if not pkt:
            continue
        h4 = pkt[0]
        body = pkt[1:]

        if h4 == 0x04 and len(body) >= 2:          # evento HCI
            code, plen = body[0], body[1]
            p = body[2:2 + plen]
            if code == 0x3E and p:                   # LE Meta
                sub = p[0]
                if sub in (0x01, 0x0A) and len(p) >= 12 and p[1] == 0:
                    h = int.from_bytes(p[2:4], "little") & 0x0FFF
                    addr = fmt_addr(p[6:12])
                    c = Conn(h, addr, t)
                    conns[h] = c
                    todas.append(c)
                    ev(t, h, f"CONECTOU handle=0x{h:03X} endereco={addr} papel={'central' if p[4] == 0 else 'periferico'}")
                elif sub == 0x05 and len(p) >= 3:
                    h = int.from_bytes(p[1:3], "little") & 0x0FFF
                    ev(t, h, "pulseira pediu a chave salva (LE LTK Request) -> reconexao usando o vinculo")
                    if h in conns:
                        conns[h].ltk_reuse = True
            elif code == 0x05 and len(p) >= 4:     # Disconnection Complete
                h = int.from_bytes(p[1:3], "little") & 0x0FFF
                motivo = DISC_REASON.get(p[3], f"0x{p[3]:02X}")
                ev(t, h, f"DESCONECTOU handle=0x{h:03X} motivo={motivo}")
                if h in conns:
                    conns[h].t1, conns[h].reason = t, motivo
                    del conns[h]
            elif code in (0x08, 0x59) and len(p) >= 4:   # Encryption Change (v1/v2)
                h = int.from_bytes(p[1:3], "little") & 0x0FFF
                ok = p[0] == 0 and p[3] != 0
                ev(t, h, f"CRIPTOGRAFIA {'ativada' if ok else 'FALHOU status=0x%02X' % p[0]}")
                if h in conns and ok:
                    conns[h].encrypted = True
            continue

        if h4 == 0x01 and len(body) >= 3:          # comando HCI
            opcode = int.from_bytes(body[0:2], "little")
            if opcode == 0x2019 and len(body) >= 5:
                h = int.from_bytes(body[3:5], "little") & 0x0FFF
                ev(t, h, "celular iniciou criptografia com chave salva (LE Start Encryption)")
                if h in conns:
                    conns[h].ltk_reuse = True
            continue

        if h4 != 0x02 or len(body) < 4:            # so ACL daqui pra baixo
            continue
        hh = int.from_bytes(body[0:2], "little")
        h, pb = hh & 0x0FFF, (hh >> 12) & 0x3
        data = body[4:4 + int.from_bytes(body[2:4], "little")]
        c = conns.get(h)
        if c is None:
            c = Conn(h, "?", t)
            conns[h] = c
            todas.append(c)
        d = 0 if sent else 1
        if pb in (0b00, 0b10):                     # inicio de PDU L2CAP
            if len(data) < 4:
                continue
            need = int.from_bytes(data[0:2], "little") + 4
            c.rx_buf[d], c.rx_need[d] = data, need
        else:                                      # continuacao
            if not c.rx_need[d]:
                continue
            c.rx_buf[d] += data
        if len(c.rx_buf[d]) < c.rx_need[d]:
            continue
        l2 = c.rx_buf[d][:c.rx_need[d]]
        c.rx_buf[d], c.rx_need[d] = b"", 0
        cid = int.from_bytes(l2[2:4], "little")
        pdu = l2[4:]
        if not pdu:
            continue
        if cid == 0x0004:
            handle_att(c, t, sent, pdu)
        elif cid == 0x0006:
            handle_smp(c, t, sent, pdu)

    # ---------------------------------------------------------------- saidas
    alvo = {c.handle for c in todas if c.sap > 0}
    if not alvo and not args.todos:
        print("[aviso] nenhum frame do canal SAP encontrado. Mostrando todas as conexoes (--todos).")
        args.todos = True
    mostrar = lambda h: args.todos or h in alvo or h == -1

    base = path.with_suffix("")
    tl = [f"{t - t_first:9.3f}s  [conn 0x{h:03X}]  {txt}" for t, h, txt in eventos if mostrar(h)]
    (base.parent / (base.name + "_timeline.txt")).write_text("\n".join(tl), encoding="utf-8")
    with open(base.parent / (base.name + "_frames.jsonl"), "w", encoding="utf-8") as fp:
        for r in frames:
            if mostrar(r["conn"]):
                fp.write(json.dumps(r, ensure_ascii=False) + "\n")

    cont = collections.Counter()
    for r in frames:
        if mostrar(r["conn"]) and r.get("canal") is not None:
            cont[(r["quem"], r["canal"], r["cmd"])] += 1
    md = [f"# Resumo da captura `{path.name}`", "",
          f"- Duração: {eventos[-1][0] - t_first:.1f} s" if eventos else "- (vazia)",
          f"- Frames decodificados: {sum(1 for r in frames if mostrar(r['conn']))}", "", "## Conexões", "",
          "| conn | endereço | início (s) | fim (s) | motivo | pareou aqui? | reusou chave? | cripto | frames SAP |",
          "|---|---|---|---|---|---|---|---|---|"]
    for c in todas:
        if not mostrar(c.handle):
            continue
        md.append(f"| 0x{c.handle:03X} | {c.addr} | {c.t0 - t_first:.1f} | "
                  f"{(c.t1 - t_first) if c.t1 else 0:.1f} | {c.reason or '-'} | {'sim' if c.paired_here else 'não'} | "
                  f"{'sim' if c.ltk_reuse else 'não'} | {'sim' if c.encrypted else 'não'} | {c.sap} |")
    md += ["", "## Pareamento (SMP)", ""]
    md += [f"- {t - t_first:.2f}s: {txt}" for t, h, txt in eventos if txt.startswith("SMP") and mostrar(h)] or ["- nenhum"]
    md += ["", "## Mensagens por canal/comando", "", "| sentido | canal | cmd | qtd |", "|---|---|---|---|"]
    for (quem, ch, cmd), n in sorted(cont.items(), key=lambda kv: (kv[0][1], kv[0][2], kv[0][0])):
        md.append(f"| {quem} | 0x{ch:02X} | 0x{cmd:02X} | {n} |")
    (base.parent / (base.name + "_resumo.md")).write_text("\n".join(md), encoding="utf-8")

    for linha in tl[:400]:
        print(linha)
    if len(tl) > 400:
        print(f"... (+{len(tl) - 400} linhas no arquivo)")
    print(f"\n[ok] timeline: {base.name}_timeline.txt | frames: {base.name}_frames.jsonl | resumo: {base.name}_resumo.md")


if __name__ == "__main__":
    main()
