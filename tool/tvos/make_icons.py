"""Makes the Apple TV icon and Top Shelf images from VyseTV's helmet mark.

    python tool/tvos/make_icons.py

An Apple TV app icon is a stack of layers the system tilts against each other when the icon
has focus: here a dark back layer (the app's background, lit from the middle as the iPhone
icon is) and the helmet in front. Top Shelf images are what the home screen shows across the
top while VyseTV's icon has focus. Writes tvos/Runner/Assets.xcassets; the images are
committed, so this is only run again when the mark changes.
"""
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

REPO = Path(__file__).resolve().parents[2]
MARK = REPO / 'assets' / 'brand' / 'vysetv_mark.png'
FONT = REPO / 'assets' / 'fonts' / 'go-noto-current-regular.ttf'
OUT = REPO / 'tvos' / 'Runner' / 'Assets.xcassets'

EDGE = (7, 8, 15)  # the app's background (lib/core/theme.dart, bg)
MIDDLE = (25, 27, 40)  # where the light falls, as on the iPhone icon
INFO = {'author': 'xcode', 'version': 1}


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8', newline='\n')


def back(w, h):
    """The background, brightest in the middle (a radial gradient, drawn small and scaled)."""
    small = Image.new('RGB', (64, 64))
    px = small.load()
    for y in range(64):
        for x in range(64):
            d = min(1.0, (((x - 31.5) / 32) ** 2 + ((y - 31.5) / 32) ** 2) ** 0.5)
            px[x, y] = tuple(round(m + (e - m) * d) for m, e in zip(MIDDLE, EDGE))
    return small.resize((w, h), Image.BICUBIC)


def mark(height):
    m = Image.open(MARK).convert('RGBA')
    m = m.crop(m.getchannel('A').getbbox())
    w = round(m.width * height / m.height)
    return m.resize((w, height), Image.LANCZOS)


def front(w, h, share=0.78):
    layer = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    m = mark(round(h * share))
    layer.alpha_composite(m, ((w - m.width) // 2, (h - m.height) // 2))
    return layer


def shelf(w, h):
    """The mark and the name, on the background, centred."""
    img = back(w, h).convert('RGBA')
    m = mark(round(h * 0.5))
    font = ImageFont.truetype(str(FONT), round(h * 0.2))
    draw = ImageDraw.Draw(img)
    text = 'VyseTV'
    box = draw.textbbox((0, 0), text, font=font)
    gap = round(h * 0.06)
    total = m.width + gap + (box[2] - box[0])
    x = (w - total) // 2
    img.alpha_composite(m, (x, (h - m.height) // 2))
    ty = (h - (box[3] - box[1])) // 2 - box[1]
    draw.text((x + m.width + gap - box[0], ty), text, font=font, fill=(244, 245, 251, 255))
    return img.convert('RGB')


def imagestack(name, sizes):
    """A layered icon: [sizes] is [(scale, w, h), ...]."""
    stack = OUT / 'AppIcon.brandassets' / f'{name}.imagestack'
    write_json(stack / 'Contents.json', {'info': INFO, 'layers': [{'filename': 'Front.imagestacklayer'}, {'filename': 'Back.imagestacklayer'}]})
    for layer, make in (('Front', front), ('Back', back)):
        folder = stack / f'{layer}.imagestacklayer'
        write_json(folder / 'Contents.json', {'info': INFO})
        (folder / 'Content.imageset').mkdir(parents=True, exist_ok=True)
        images = []
        for scale, w, h in sizes:
            file = f'{layer}{"" if scale == "1x" else "@" + scale}.png'
            make(w, h).save(folder / 'Content.imageset' / file)
            images.append({'filename': file, 'idiom': 'tv', 'scale': scale})
        write_json(folder / 'Content.imageset' / 'Contents.json', {'images': images, 'info': INFO})


def imageset(name, sizes, make):
    folder = OUT / 'AppIcon.brandassets' / f'{name}.imageset'
    folder.mkdir(parents=True, exist_ok=True)
    images = []
    for scale, w, h in sizes:
        file = f'{name.lower().replace(" ", "-")}{"" if scale == "1x" else "@" + scale}.png'
        make(w, h).save(folder / file)
        images.append({'filename': file, 'idiom': 'tv', 'scale': scale})
    write_json(folder / 'Contents.json', {'images': images, 'info': INFO})


def main():
    write_json(OUT / 'Contents.json', {'info': INFO})
    write_json(OUT / 'AppIcon.brandassets' / 'Contents.json', {
        'assets': [
            {'filename': 'App Icon - App Store.imagestack', 'idiom': 'tv', 'role': 'primary-app-icon', 'size': '1280x768'},
            {'filename': 'App Icon.imagestack', 'idiom': 'tv', 'role': 'primary-app-icon', 'size': '400x240'},
            {'filename': 'Top Shelf Image Wide.imageset', 'idiom': 'tv', 'role': 'top-shelf-image-wide', 'size': '2320x720'},
            {'filename': 'Top Shelf Image.imageset', 'idiom': 'tv', 'role': 'top-shelf-image', 'size': '1920x720'},
        ],
        'info': INFO,
    })
    imagestack('App Icon', [('1x', 400, 240), ('2x', 800, 480)])
    imagestack('App Icon - App Store', [('1x', 1280, 768)])
    imageset('Top Shelf Image', [('1x', 1920, 720), ('2x', 3840, 1440)], shelf)
    imageset('Top Shelf Image Wide', [('1x', 2320, 720), ('2x', 4640, 1440)], shelf)
    print('wrote', OUT.relative_to(REPO))


if __name__ == '__main__':
    main()
