from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageOps

root = Path(__file__).resolve().parents[1]
photo = ImageOps.exif_transpose(Image.open(root / 'pic/IMG20260918205805.jpg'))
photo = photo.convert('RGB').resize((1600, 1600), Image.Resampling.LANCZOS)
draw = ImageDraw.Draw(photo)
font_path = 'C:/Windows/Fonts/arial.ttf'
title = ImageFont.truetype(font_path, 30)
body = ImageFont.truetype(font_path, 27)
small = ImageFont.truetype(font_path, 23)

groups = [
    ('M1 / BOARD 1 CH1', '#00EE96', (18, 815),
     ['ST1 = PA5', 'DIR1 = PA4', 'EN1 = PC2'],
     [(439, 877, 505, 917), (508, 877, 576, 917), (509, 920, 577, 961)]),
    ('M2 / BOARD 1 CH2', '#42D9FF', (18, 1030),
     ['ST2 = PA1', 'DIR2 = PA2', 'EN2 = PC3'],
     [(432, 1007, 502, 1051), (507, 963, 577, 1006), (434, 963, 503, 1006)]),
    ('M3 / BOARD 2 CH1', '#FFE354', (1240, 315),
     ['ST1 = PA6', 'DIR1 = PB5', 'EN1 = PG8'],
     [(1016, 407, 1081, 450), (1014, 452, 1080, 493), (1082, 364, 1148, 407)]),
    ('M4 / BOARD 2 CH2', '#FF8CB3', (1240, 550),
     ['ST2 = PB6', 'DIR2 = PB11', 'EN2 = PB10'],
     [(1081, 452, 1148, 494), (1013, 494, 1080, 536), (1080, 537, 1148, 579)]),
]
for label, color, (x, y), lines, rectangles in groups:
    for rectangle in rectangles:
        draw.rectangle(rectangle, outline=color, width=5)
    draw.rectangle((x, y, x + 336, y + 182), fill='#152020', outline=color, width=3)
    draw.text((x + 12, y + 12), label, fill=color, font=body)
    for index, line in enumerate(lines):
        draw.text((x + 12, y + 57 + index * 36), line, fill='white', font=body)

draw.rectangle((375, 1370, 1230, 1533), fill='#152020')
draw.text((393, 1386), 'BACK VIEW: SD socket at top, SWD at bottom', fill='white', font=title)
draw.text((393, 1430), 'Boxes mark printed pin names. Connect to matching header pins.', fill='white', font=small)
draw.text((393, 1464), 'Both D36A boards: GND -> STM32 GND. PA0 is not used.', fill='white', font=small)
draw.text((393, 1498), 'D36A: external 12 V supply; leave 5V and ADC unconnected.', fill='white', font=small)
photo.save(root / 'pic/D36A_pinmap_annotated.jpg', quality=94, subsampling=0)
