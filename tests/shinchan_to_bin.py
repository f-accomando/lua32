#!/usr/bin/env python3
"""
shinchan_to_bin.py - converte un'immagine in RGB565 raw pronto per il
pannello LCD (480x320) - stessa identica logica di packing byte del
tuo shinchan.sh originale (gia' verificata a occhio sul pannello vero:
"colori attesi: rosso = rosso, giallo = giallo"), NON "corretta" sulla
base di quello che ci si aspetterebbe in teoria.

A differenza dello script originale, non scrive direttamente su
/dev/fbN (l'indice e' cambiato da quando HDMI e' passato a KMSDRM: oggi
l'LCD e' /dev/fb0, non piu' /dev/fb1 - verificalo con `cat /proc/fb`
prima di lanciare un test diretto) - scrive un file .bin che
lcd_status.lua ricarica ad ogni avvio senza dover rifare la conversione
ogni volta (serve farla una sola volta per immagine).

Uso:
    python3 tests/shinchan_to_bin.py /home/pi/shinchan.png shinchan_565.bin
    python3 tests/shinchan_to_bin.py /home/pi/shinchan.png shinchan_565.bin 480 320
"""
import sys
from PIL import Image


def convert(src_path, out_path, w=480, h=320):
    img = Image.open(src_path).convert("RGB")
    img.thumbnail((w, h), Image.Resampling.LANCZOS)

    canvas = Image.new("RGB", (w, h), "black")
    canvas.paste(img, ((w - img.width) // 2, (h - img.height) // 2))

    rgb = canvas.tobytes()
    out = bytearray()
    for i in range(0, len(rgb), 3):
        r, g, b = rgb[i:i + 3]
        p = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
        out += bytes((p & 0xFF, (p >> 8) & 0xFF))

    with open(out_path, "wb") as f:
        f.write(out)
    print(f"Scritto {out_path}: {len(out)} byte ({w}x{h} RGB565)")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    src, out = sys.argv[1], sys.argv[2]
    w = int(sys.argv[3]) if len(sys.argv) > 3 else 480
    h = int(sys.argv[4]) if len(sys.argv) > 4 else 320
    convert(src, out, w, h)
