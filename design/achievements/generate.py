from PIL import Image, ImageDraw, ImageFilter
import math, random

S = 512
BLACK  = (7, 8, 10)
ORANGE = (232, 144, 80)
GREEN  = (108, 235, 158)

def base(): return Image.new('RGB', (S, S), BLACK)
def bloom(img, r=14): return Image.blend(img, img.filter(ImageFilter.GaussianBlur(r)), 0.38)

def ring(d, cx, cy, rad, w, col, arc=None):
    box=[cx-rad, cy-rad, cx+rad, cy+rad]
    if arc: d.arc(box, arc[0], arc[1], fill=col, width=w)
    else: d.ellipse(box, outline=col, width=w)

def dots(d, n, seed, cx, cy, spread, col=GREEN, rmin=2, rmax=4):
    r = random.Random(seed)
    for _ in range(n):
        a = r.random()*math.tau
        dist = (r.random()**0.6)*spread
        x, y = cx+math.cos(a)*dist, cy+math.sin(a)*dist
        rr = r.uniform(rmin, rmax)
        f = max(0.3, 1-dist/(spread*1.2))
        d.ellipse([x-rr,y-rr,x+rr,y+rr], fill=tuple(int(v*f) for v in col))

# first_run — one ring, one field. The plainest possible statement of the game.
def first_run():
    img=base(); d=ImageDraw.Draw(img)
    dots(d, 200, 5, S/2, S/2, 210)
    ring(d, S/2, S/2, 128, 15, ORANGE)
    return bloom(img)

# max_combo — six marks around the ring, one per multiplier step.
def max_combo():
    img=base(); d=ImageDraw.Draw(img)
    dots(d, 150, 9, S/2, S/2, 190)
    ring(d, S/2, S/2, 120, 13, ORANGE)
    for i in range(6):
        a = -math.pi/2 + i*math.tau/6
        x, y = S/2+math.cos(a)*172, S/2+math.sin(a)*172
        d.ellipse([x-15,y-15,x+15,y+15], fill=ORANGE)
    return bloom(img)

# first_online — two rings, overlapping. The shared field, in one image.
def first_online():
    img=base(); d=ImageDraw.Draw(img)
    dots(d, 190, 13, S/2, S/2, 205)
    ring(d, S/2-58, S/2, 108, 13, ORANGE)
    ring(d, S/2+58, S/2, 108, 13, (108,200,235))
    return bloom(img)

# all_classes — three rings at the three class radii, nested as they actually differ.
def all_classes():
    img=base(); d=ImageDraw.Draw(img)
    dots(d, 150, 21, S/2, S/2, 200)
    for rad, col in ((78,(232,144,80)), (120,(103,232,249)), (162,(167,139,250))):
        ring(d, S/2, S/2, rad, 11, col)
    return bloom(img)

for name, fn in [('first_run',first_run), ('max_combo',max_combo),
                 ('first_online',first_online), ('all_classes',all_classes)]:
    fn().save(f'ach-{name}.png')
    print(f'  ach-{name}.png')

# contact sheet
sheet = Image.new('RGB', (4*270+30, 300), (13,14,16)); sd=ImageDraw.Draw(sheet)
for i,n in enumerate(['first_run','max_combo','first_online','all_classes']):
    im = Image.open(f'ach-{n}.png').resize((250,250), Image.LANCZOS)
    sheet.paste(im, (15+i*270, 12))
    sd.text((15+i*270+70, 272), n, fill=(150,155,165))
sheet.save('ach-sheet.png')
print('  sheet', sheet.size)
