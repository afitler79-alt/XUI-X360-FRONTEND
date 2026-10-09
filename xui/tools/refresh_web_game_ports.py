#!/usr/bin/env python3
import html
import json
import re
from pathlib import Path
from urllib.request import Request, urlopen


README_URL = (
    'https://raw.githubusercontent.com/Carter54git/'
    'Ultimate-Catalog-Of-Web-Game-Ports/main/README.md'
)
OUTPUT_PATH = Path(__file__).resolve().parents[1] / 'win' / 'web_game_ports.json'
EXPECTED_GAME_COUNT = 534
SUPPLEMENTAL_GAMES = [
    {
        'id': 'xui-skate-fan-engine',
        'name': 'Skate 3 (Fan Browser Engine)',
        'demo_url': 'https://skate.aaddpp.lol/',
        'source_url': None,
        'access': 'demo',
        'price_xui': 0,
        'popularity_tier': 'free',
        'description': (
            'Motor fan no comercial. Requiere tu propia copia legal de Skate 3; '
            'este sitio no aloja archivos del juego.'
        ),
    },
    {
        'id': 'xui-bo1-zombies',
        'name': 'BO1 Zombies',
        'demo_url': 'https://vel.gg/bo1z',
    },
    {
        'id': 'xui-moon-zombies',
        'name': 'Moon Zombies',
        'demo_url': 'https://moon-zombies.pages.dev/',
    },
    {
        'id': 'xui-kino-der-toten',
        'name': 'Kino der Toten',
        'demo_url': 'https://kino-der-toten.pages.dev/',
    },
    {
        'id': 'xui-bo3-cheese-cube',
        'name': 'BO3 Cheese Cube',
        'demo_url': 'https://cheese-cube.pages.dev/',
    },
    {
        'id': 'xui-black-ops-2',
        'name': 'Black Ops 2',
        'demo_url': 'https://vibeslops.luckeysystems.com/',
    },
    {
        'id': 'xui-modern-warfare-2',
        'name': 'Modern Warfare 2',
        'demo_url': 'https://ovz-game-production.up.railway.app/',
    },
    {
        'id': 'xui-skate-rust',
        'name': 'Skate Rust',
        'demo_url': 'https://global-terror.net/',
    },
    {
        'id': 'xui-cs-surf',
        'name': 'CS Surf',
        'demo_url': 'https://surfd.net/',
    },
    {
        'id': 'xui-halo-ce',
        'name': 'Halo CE',
        'demo_url': 'https://mitchellhynes.com/halo',
    },
    {
        'id': 'xui-halo-ce-mobile',
        'name': 'Halo CE Mobile',
        'demo_url': 'https://hcemobile.com/',
    },
    {
        'id': 'xui-pes-6',
        'name': 'PES 6',
        'demo_url': 'https://pes6.optijuegos.net/',
    },
    {
        'id': 'xui-gta-5-archived',
        'name': 'GTA 5 (Archived Port)',
        'demo_url': 'https://web.archive.org/web/20261006055917/https://playgta5.com/',
        'description': 'Enlace a una captura archivada; puede no funcionar o estar incompleta.',
    },
    {
        'id': 'xui-gta-vice-city-wasm',
        'name': 'GTA Vice City (WASM Port)',
        'demo_url': 'https://joncodeofficial.github.io/gta-vice-city-wasm/',
    },
    {
        'id': 'xui-simpsons-hit-and-run',
        'name': 'The Simpsons: Hit & Run',
        'demo_url': 'https://shar-wasm.cjoseph.workers.dev/?skipmovie',
    },
    {
        'id': 'xui-quake-1-browser',
        'name': 'Quake 1 (Browser Port)',
        'demo_url': 'https://q1.pieter.com/',
    },
    {
        'id': 'xui-quake-2-browser',
        'name': 'Quake 2 (Browser Port)',
        'demo_url': 'https://q2.pieter.com/',
    },
    {
        'id': 'xui-quake-3-browser',
        'name': 'Quake 3 (Browser Port)',
        'demo_url': 'https://q3.pieter.com/',
    },
    {
        'id': 'xui-rtc-wolfenstein-browser',
        'name': 'Return to Castle Wolfenstein (Browser Port)',
        'demo_url': 'https://rtcw.pieter.com/',
    },
    {
        'id': 'xui-unreal-tournament-browser',
        'name': 'Unreal Tournament',
        'demo_url': 'https://ut.pieter.com/',
    },
    {
        'id': 'xui-half-life-pixelsuft',
        'name': 'Half-Life (PixelSuft Port)',
        'demo_url': 'https://pixelsuft.github.io/hl/',
    },
    {
        'id': 'xui-half-life-cs-16',
        'name': 'Half-Life / CS 1.6',
        'demo_url': 'https://x8bitrain.github.io/webXash/',
    },
    {
        'id': 'xui-diablo-browser',
        'name': 'Diablo (Browser Port)',
        'demo_url': 'https://johnimril.github.io/diablo_web/',
    },
    {
        'id': 'xui-hedgewars',
        'name': 'Hedgewars',
        'demo_url': 'https://webwars.link/',
    },
    {
        'id': 'xui-wasm-arcade-fan-ports',
        'name': 'More GTA / Minecraft Fan Ports',
        'demo_url': 'https://wasmarcade.com/Fan',
    },
]

for game in SUPPLEMENTAL_GAMES:
    game.setdefault('source_url', None)
    game.setdefault('access', 'demo')
    game.setdefault('price_xui', 0)
    game.setdefault('popularity_tier', 'free')
    game.setdefault(
        'description',
        'Enlace de terceros, no verificado ni alojado por XUI. Algunos ports requieren archivos propios; '
        'usa solo copias que tengas derecho a utilizar y no descargues launchers inesperados.',
    )

# Popularity is a transparent, curated franchise tier because the source catalog
# provides no per-game play counts or popularity scores.
POPULARITY_PRICES = {
    'minecraft': 300,
    'terraria': 300,
    'cuphead': 280,
    'hollow knight': 280,
    'stardew valley': 280,
    'balatro': 260,
    'portal': 260,
    'undertale': 240,
    'among us': 240,
    "five nights at freddy's": 220,
    'fnaf': 220,
    'geometry dash': 220,
    'celeste': 220,
    'pizza tower': 220,
    'plants vs zombies': 220,
    'super mario': 200,
    'sonic': 200,
    'ultrakill': 200,
    'omori': 200,
    'gta': 200,
    'slime rancher': 180,
    'getting over it': 180,
    'bendy': 180,
    "baldi's basics": 160,
    'granny': 160,
    'doom': 160,
    'quake': 160,
}


def extract_link(cell):
    match = re.search(r'\[[^\]]*\]\((https?://[^)]+)\)', cell)
    return html.unescape(match.group(1).strip()) if match else None


def price_for(name, demo_url):
    if not demo_url:
        return 0, 'free'
    normalized = re.sub(r'\s+\(\d+\)$', '', name).casefold()
    for franchise, price in sorted(POPULARITY_PRICES.items(), key=lambda item: -len(item[0])):
        if normalized.startswith(franchise):
            return price, 'popular'
    return 0, 'free'


def parse_catalog(markdown):
    in_list = False
    games = []
    for line in markdown.splitlines():
        if line.strip() == '## List':
            in_list = True
            continue
        if in_list and line.startswith('## '):
            break
        if not in_list or not line.lstrip().startswith('|'):
            continue
        cells = [cell.strip() for cell in line.strip().strip('|').split('|')]
        if len(cells) < 4 or not cells[0].isdigit():
            continue
        number = int(cells[0])
        name = html.unescape(cells[1]).strip(' `*')
        demo_url = extract_link(cells[2])
        source_url = extract_link(cells[3])
        price, tier = price_for(name, demo_url)
        games.append({
            'id': f'web-port-{number:03d}',
            'name': name,
            'demo_url': demo_url,
            'source_url': source_url,
            'access': 'demo' if demo_url else 'source',
            'price_xui': price,
            'popularity_tier': tier,
        })
    return games


def main():
    request = Request(README_URL, headers={'User-Agent': 'XUI-Web-Ports-Catalog/1.0'})
    with urlopen(request, timeout=30) as response:
        markdown = response.read().decode('utf-8')
    games = parse_catalog(markdown)
    ids = [game['id'] for game in games]
    expected_ids = [f'web-port-{number:03d}' for number in range(1, EXPECTED_GAME_COUNT + 1)]
    if ids != expected_ids:
        raise ValueError(f'Expected {EXPECTED_GAME_COUNT} ordered entries; parsed {len(games)}')
    games.extend(SUPPLEMENTAL_GAMES)

    updated_match = re.search(r'Updated ([^\n]+)', markdown)
    catalog = {
        'source_url': 'https://github.com/Carter54git/Ultimate-Catalog-Of-Web-Game-Ports',
        'source_updated': updated_match.group(1).strip() if updated_match else None,
        'pricing_basis': (
            'Curated franchise popularity tiers. Only playable demo links may be paid; '
            'all repository-only entries, other demos, and supplemental listings are free. XUI prices are local '
            'virtual credits and do not imply ownership or licensing.'
        ),
        'game_count': len(games),
        'games': games,
    }
    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    paid_count = sum(game['price_xui'] > 0 for game in games)
    print(f'Wrote {len(games)} games ({paid_count} paid, {len(games) - paid_count} free): {OUTPUT_PATH}')


if __name__ == '__main__':
    main()