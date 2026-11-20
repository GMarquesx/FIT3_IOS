"""
fit3_frame.py - Formato de frame do canal SAP do Galaxy Fit3 (decifrado a partir do log do Fit3 Bridge)

Frame (todos os campos big-endian):

    +---------+------------------+-----------------+---------------------+
    | LEN (2) | CRC16(LEN) (2)   | PAYLOAD (LEN)   | CRC16(PAYLOAD) (2)  |
    +---------+------------------+-----------------+---------------------+

    CRC16 = CRC-16/ARC  (poly 0x8005 refletido, init 0x0000, xorout 0x0000)

Payload visto ate agora:

    DIR 40 | CH CH | CMD ... dados
    - DIR      01 = app -> pulseira, 00 = pulseira -> app
    - 40       flags (sempre 0x40 ate agora)
    - CH CH    numero do canal repetido (provavelmente porta origem/destino)
    - CMD      comando dentro do canal; a resposta costuma ser CMD | 0x40 (01->41, 02->42, 83->43)

    ACK da pulseira: payload de 4 bytes "88 40 80 00" / "88 50 80 00" (o bit 0x10 alterna a cada frame)

Validado contra os 45 frames distintos do log do Fit3 Bridge (python fit3_frame.py).
"""

from __future__ import annotations


def crc16_arc(data: bytes) -> int:
    crc = 0x0000
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


def build(payload: bytes) -> bytes:
    """Monta um frame completo a partir do payload."""
    ln = len(payload).to_bytes(2, "big")
    return ln + crc16_arc(ln).to_bytes(2, "big") + payload + crc16_arc(payload).to_bytes(2, "big")


def cmd(channel: int, data: bytes) -> bytes:
    """Atalho: payload '01 40 CH CH' + dados."""
    return build(bytes([0x01, 0x40, channel, channel]) + data)


def parse(frame: bytes) -> dict:
    """Decodifica um frame e confere os dois CRCs."""
    if len(frame) < 6:
        return {"ok": False, "erro": f"curto demais ({len(frame)} B)"}
    ln = int.from_bytes(frame[0:2], "big")
    hdr_ok = int.from_bytes(frame[2:4], "big") == crc16_arc(frame[0:2])
    if len(frame) != ln + 6:
        return {"ok": False, "erro": f"LEN={ln} mas o frame tem {len(frame)} B", "hdr_ok": hdr_ok}
    payload = frame[4:-2]
    pay_ok = int.from_bytes(frame[-2:], "big") == crc16_arc(payload)
    out = {"ok": hdr_ok and pay_ok, "hdr_ok": hdr_ok, "payload_ok": pay_ok, "len": ln, "payload": payload}
    if len(payload) == 4 and payload[0] == 0x88:
        out["ack"] = True  # 88 40 80 00 / 88 50 80 00 (bit 0x10 alterna)
    elif len(payload) >= 5 and payload[0] in (0x00, 0x01) and payload[2] == payload[3]:
        out["dir"] = "app->pulseira" if payload[0] == 0x01 else "pulseira->app"
        out["flags"] = payload[1]
        out["canal"] = payload[2]
        out["cmd"] = payload[4]
        out["dados"] = payload[5:]
    return out


# Comandos ja identificados ------------------------------------------------
FIND_VIBRAR_ON = cmd(0x1F, b"\x0D")
FIND_VIBRAR_OFF = cmd(0x1F, b"\x0F")


def time_sync(epoch: int) -> bytes:
    """Frame do canal 0x01 cmd 0x83 com o horario em texto (visto no log)."""
    ts = str(int(epoch)).encode()
    data = b"\x83\x01\x53\x00\x02\x00\x03" + bytes([len(ts)]) + ts + b"\x04\x01\x30\x2A\x05\x00"
    return cmd(0x01, data)


if __name__ == "__main__":
    # auto-teste: os frames reais do log precisam ser reproduzidos byte a byte
    amostras = [
        "00 05 03 C0 01 40 1F 1F 0D 33 D0",
        "00 05 03 C0 01 40 1F 1F 0F F2 51",
        "00 0A 07 80 01 40 01 01 01 04 02 05 00 0E 66 D1",
        "00 07 C2 41 01 40 01 01 02 01 01 AC 43",
        "00 1C C9 01 01 40 01 01 83 01 53 00 02 00 03 0A 31 37 39 35 30 33 34 33 34 35 04 01 30 2A 05 00 A5 87",
    ]
    for hx in amostras:
        f = bytes.fromhex(hx)
        p = parse(f)
        assert p["ok"], hx
        assert build(p["payload"]) == f, hx
    assert time_sync(1795034345) == bytes.fromhex(amostras[4])
    assert FIND_VIBRAR_ON == bytes.fromhex(amostras[0])
    print("ok: formato de frame confere com o log do Fit3 Bridge")
