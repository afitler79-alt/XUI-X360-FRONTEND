import sys
import os
import subprocess
import random
import json
import shutil
import time
from pathlib import Path

ASSETS = Path.home() / '.xui' / 'assets'
DATA = Path.home() / '.xui' / 'data'
DATA.mkdir(parents=True, exist_ok=True)
SLOTS_FILE = DATA / 'slots.json'
MISSIONS_FILE = DATA / 'missions.json'
SETTINGS_FILE = DATA / 'settings.json'
PORTS_CATALOG_FILE = Path(__file__).with_name('web_game_ports.json')
XUI_WALLET_FILE = DATA / 'xui_wallet.json'
GAME_LIBRARY_FILE = DATA / 'web_game_library.json'

try:
    from PyQt5 import QtWidgets, QtGui, QtCore
except Exception:
    print('PyQt5 not installed')
    sys.exit(1)

try:
    import pygame
except Exception:
    pygame = None


class SlotMachineDialog(QtWidgets.QDialog):
    SYMBOLS = ['🍒', '🔔', '🍋', '⭐', '7']

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle('Casino - Tragaperras')
        self.setModal(True)
        try:
            data = json.load(open(SLOTS_FILE)) if SLOTS_FILE.exists() else {}
            self.credits = int(data.get('credits', 100))
        except Exception:
            self.credits = 100
        try:
            settings = json.load(open(SETTINGS_FILE)) if SETTINGS_FILE.exists() else {}
            self.sounds = bool(settings.get('sounds', True))
        except Exception:
            self.sounds = True
        v = QtWidgets.QVBoxLayout(self)
        h = QtWidgets.QHBoxLayout()
        self.reels = [QtWidgets.QLabel('') for _ in range(3)]
        for r in self.reels:
            r.setAlignment(QtCore.Qt.AlignCenter)
            f = r.font()
            f.setPointSize(48)
            r.setFont(f)
            r.setFixedSize(160, 160)
            r.setStyleSheet('background:#123; color:white; border-radius:8px;')
            h.addWidget(r)
        v.addLayout(h)
        ctr = QtWidgets.QHBoxLayout()
        self.spin_btn = QtWidgets.QPushButton('Girar (10 créditos)')
        self.spin_btn.clicked.connect(self.spin)
        self.credits_lbl = QtWidgets.QLabel(f'Créditos: {self.credits}')
        ctr.addWidget(self.spin_btn)
        ctr.addWidget(self.credits_lbl)
        v.addLayout(ctr)
        self.timers = [QtCore.QTimer(self) for _ in range(3)]
        for i, t in enumerate(self.timers):
            t.timeout.connect(lambda i=i: self._advance_reel(i))

    def _play_sound(self, fname):
        if not self.sounds:
            return
        path = ASSETS / fname
        if path.exists() and shutil.which('mpv'):
            try:
                if str(path).lower().endswith('.mp4'):
                    subprocess.Popen(['mpv', '--really-quiet', str(path)])
                else:
                    subprocess.Popen(['mpv', '--no-video', '--really-quiet', str(path)])
            except Exception:
                pass

    def _advance_reel(self, i):
        self.reels[i].setText(random.choice(self.SYMBOLS))

    def spin(self):
        if self.credits < 10:
            QtWidgets.QMessageBox.information(self, 'Sin créditos', 'No tienes suficientes créditos')
            return
        self.credits -= 10
        self.credits_lbl.setText(f'Créditos: {self.credits}')
        self._play_sound('click.mp3')
        intervals = [50, 70, 90]
        durations = [800, 1400, 2000]
        for i, t in enumerate(self.timers):
            t.start(intervals[i])
            QtCore.QTimer.singleShot(durations[i], lambda t=t: t.stop())
        QtCore.QTimer.singleShot(max(durations) + 50, self._resolve)

    def _resolve(self):
        vals = [r.text() for r in self.reels]
        if vals[0] == vals[1] == vals[2]:
            win = 200 if vals[0] == '7' else 50
            self.credits += win
            QtWidgets.QMessageBox.information(self, 'Ganaste!', f'¡Combinación {vals[0]}! Ganaste {win} créditos')
            self._play_sound('startup.mp4')
        elif vals[0] == vals[1] or vals[1] == vals[2] or vals[0] == vals[2]:
            win = 20
            self.credits += win
            QtWidgets.QMessageBox.information(self, 'Pequeño premio', f'Combinación parcial {vals}. Ganaste {win} créditos')
            self._play_sound('startup.mp4')
        else:
            QtWidgets.QMessageBox.information(self, 'Suerte', 'No hubo premio')
        self.credits_lbl.setText(f'Créditos: {self.credits}')
        try:
            json.dump({'credits': self.credits}, open(SLOTS_FILE, 'w'))
        except Exception:
            pass


class VerticalGuideButton(QtWidgets.QPushButton):
    def __init__(self, text, callback, parent=None):
        super().__init__(parent)
        self.label = text
        self.clicked.connect(callback)
        self.setFocusPolicy(QtCore.Qt.StrongFocus)
        self.setFixedWidth(44)
        self.setStyleSheet('''
            QPushButton { background:#d9dfe2; color:#283946; border:1px solid #f4f7f8;
                          font-weight:bold; }
            QPushButton:checked { background:#394954; color:#fff; }
            QPushButton:focus { border:2px solid #63b943; }
        ''')
        self.setCheckable(True)

    def sizeHint(self):
        return QtCore.QSize(44, 300)

    def paintEvent(self, event):
        painter = QtGui.QPainter(self)
        option = QtWidgets.QStyleOptionButton()
        self.initStyleOption(option)
        self.style().drawPrimitive(QtWidgets.QStyle.PE_Widget, option, painter, self)
        painter.save()
        painter.translate(self.width() / 2, self.height() / 2)
        painter.rotate(90)
        painter.setPen(self.palette().buttonText().color())
        painter.setFont(self.font())
        painter.drawText(QtCore.QRect(-self.height() / 2, -self.width() / 2,
                                      self.height(), self.width()),
                         QtCore.Qt.AlignCenter, self.label)
        painter.restore()


class XboxGuideDialog(QtWidgets.QDialog):
    PAGES = ('Games & Apps', 'Player', 'Media', 'Settings')

    def __init__(self, actions, parent=None):
        super().__init__(parent)
        self.actions = actions
        self.page_index = 1
        self.setWindowTitle('Xbox Guide')
        self.setWindowModality(QtCore.Qt.ApplicationModal)
        self.setWindowFlags(self.windowFlags() | QtCore.Qt.WindowStaysOnTopHint)
        self.setFixedSize(620, 440)
        self.setStyleSheet('''
            QDialog { background:#a6afb2; color:#f5f7f8; border:2px solid #e8edef; }
            QLabel { color:#f5f7f8; }
            QPushButton { border:0; border-radius:0; text-align:left; padding:0 12px;
                          background:#e4e8ea; color:#172c3c; font-size:17px; }
            QPushButton:hover, QPushButton:focus { background:#55b53e; color:white; }
        ''')
        self._build_ui()
        self._show_page(self.page_index)
        self.clock_timer = QtCore.QTimer(self)
        self.clock_timer.timeout.connect(self._update_clock)
        self.clock_timer.start(1000)

    def _build_ui(self):
        outer = QtWidgets.QVBoxLayout(self)
        outer.setContentsMargins(10, 8, 10, 8)
        outer.setSpacing(8)

        header = QtWidgets.QHBoxLayout()
        title = QtWidgets.QLabel('Xbox Guide')
        title.setStyleSheet('font-size:25px; font-weight:bold;')
        header.addWidget(title)
        header.addStretch(1)
        status = QtWidgets.QLabel('◩  ◉  ')
        header.addWidget(status)
        self.clock_label = QtWidgets.QLabel()
        self.clock_label.setStyleSheet('font-weight:bold;')
        header.addWidget(self.clock_label)
        header.addWidget(QtWidgets.QLabel('DASH'))
        outer.addLayout(header)

        body = QtWidgets.QHBoxLayout()
        body.setSpacing(2)
        self.left_buttons = []
        self.right_buttons = []
        for page in self.PAGES[:2]:
            button = VerticalGuideButton(page, lambda checked=False, p=page: self._select_page(p))
            self.left_buttons.append(button)
            body.addWidget(button)

        self.rows_host = QtWidgets.QWidget()
        self.rows_host.setStyleSheet('background:#e0e5e7;')
        self.rows_layout = QtWidgets.QVBoxLayout(self.rows_host)
        self.rows_layout.setContentsMargins(0, 0, 0, 0)
        self.rows_layout.setSpacing(0)
        body.addWidget(self.rows_host, 1)

        for page in self.PAGES[2:]:
            button = VerticalGuideButton(page, lambda checked=False, p=page: self._select_page(p))
            self.right_buttons.append(button)
            body.addWidget(button)
        outer.addLayout(body, 1)

        footer = QtWidgets.QHBoxLayout()
        footer.setSpacing(12)
        footer.setContentsMargins(0, 0, 0, 0)
        for label, callback, color in (
            ('A Select', self._activate_current, '#4eb845'),
            ('B Back', self.reject, '#e44141'),
            ('X Close Game', lambda: self._run_action('close'), '#3b9de0'),
            ('Y Minimize Dashboard', lambda: self._run_action('minimize'), '#e3bb31'),
            ('LB/RB Page', self._next_page, '#f2f5f6'),
        ):
            button = QtWidgets.QPushButton(label)
            button.setFocusPolicy(QtCore.Qt.StrongFocus)
            button.setStyleSheet(f'QPushButton {{ background:transparent; color:{color}; '
                                 'padding:0; font-size:12px; font-weight:bold; } '
                                 'QPushButton:focus { text-decoration:underline; }')
            button.clicked.connect(lambda checked=False, cb=callback: cb())
            footer.addWidget(button)
        outer.addLayout(footer)

    def _update_clock(self):
        self.clock_label.setText(QtCore.QTime.currentTime().toString('HH:mm'))

    def _select_page(self, page):
        self.page_index = self.PAGES.index(page)
        self._show_page(self.page_index)

    def _show_page(self, index):
        while self.rows_layout.count():
            item = self.rows_layout.takeAt(0)
            if item.widget():
                item.widget().deleteLater()
        self.row_buttons = []
        pages = {
            'Games & Apps': [('Xbox Home', 'home'), ('Games & Apps', 'library'),
                             ('Minimize', 'minimize')],
            'Player': [('Xbox Home', 'home'), ('Friends', 'friends'), ('Party', 'party'),
                       ('Messages', 'messages'), ('Chat', 'chat'),
                       ('Beacons & Activity', 'activity'), ('Minimize', 'minimize')],
            'Media': [('Open Media Folder', 'media'), ('Messages', 'messages'),
                      ('Minimize', 'minimize')],
            'Settings': [('Settings', 'settings'), ('Minimize Dashboard', 'minimize'),
                         ('Close Game', 'close')],
        }
        for label, action in pages[self.PAGES[index]]:
            button = QtWidgets.QPushButton(label)
            button.setFixedHeight(40)
            button.setFocusPolicy(QtCore.Qt.StrongFocus)
            button.clicked.connect(lambda checked=False, a=action: self._run_action(a))
            self.rows_layout.addWidget(button)
            self.row_buttons.append(button)
        self.rows_layout.addStretch(1)
        self._update_tabs()
        self.row_buttons[0].setFocus()

    def _update_tabs(self):
        for idx, button in enumerate(self.left_buttons):
            button.setChecked(idx == self.page_index)
        for idx, button in enumerate(self.right_buttons, start=2):
            button.setChecked(idx == self.page_index)

    def _run_action(self, action):
        self.accept()
        callback = self.actions.get(action)
        if callback:
            QtCore.QTimer.singleShot(0, callback)

    def _activate_current(self):
        focused = QtWidgets.QApplication.focusWidget()
        if focused in self.row_buttons or isinstance(focused, VerticalGuideButton):
            focused.click()

    def _next_page(self, direction=1):
        self._select_page(self.PAGES[(self.page_index + direction) % len(self.PAGES)])

    def keyPressEvent(self, event):
        key = event.key()
        if key in (QtCore.Qt.Key_Escape, QtCore.Qt.Key_B):
            self.reject()
        elif key == QtCore.Qt.Key_X:
            self._run_action('close')
        elif key == QtCore.Qt.Key_Y:
            self._run_action('minimize')
        elif key in (QtCore.Qt.Key_PageDown, QtCore.Qt.Key_PageUp):
            self._next_page(1 if key == QtCore.Qt.Key_PageDown else -1)
        elif key in (QtCore.Qt.Key_Left, QtCore.Qt.Key_Right):
            self._next_page(1 if key == QtCore.Qt.Key_Right else -1)
        elif key in (QtCore.Qt.Key_Up, QtCore.Qt.Key_Down):
            if self.row_buttons:
                current = self.row_buttons.index(QtWidgets.QApplication.focusWidget()) \
                    if QtWidgets.QApplication.focusWidget() in self.row_buttons else 0
                step = -1 if key == QtCore.Qt.Key_Up else 1
                self.row_buttons[(current + step) % len(self.row_buttons)].setFocus()
        elif key in (QtCore.Qt.Key_Return, QtCore.Qt.Key_Enter, QtCore.Qt.Key_A,
                     QtCore.Qt.Key_Space):
            self._activate_current()
        else:
            super().keyPressEvent(event)


class GamepadListener(QtCore.QObject):
    left = QtCore.pyqtSignal()
    right = QtCore.pyqtSignal()
    up = QtCore.pyqtSignal()
    down = QtCore.pyqtSignal()
    select = QtCore.pyqtSignal()
    back = QtCore.pyqtSignal()
    guide = QtCore.pyqtSignal()

    def __init__(self, parent=None):
        super().__init__(parent)
        if pygame is None:
            return
        try:
            pygame.init()
            pygame.joystick.init()
            self.joysticks = [pygame.joystick.Joystick(i)
                              for i in range(pygame.joystick.get_count())]
            for joystick in self.joysticks:
                joystick.init()
            self.last_buttons = {}
            self.held_directions = set()
            self.last_direction_emit = {}
            self.timer = QtCore.QTimer(self)
            self.timer.timeout.connect(self.poll)
            self.timer.start(50)
        except Exception:
            self.joysticks = []

    def poll(self):
        try:
            pygame.event.pump()
            for joystick in self.joysticks:
                if joystick.get_numaxes() > 0:
                    axis_x = joystick.get_axis(0)
                    self._poll_direction('left', axis_x < -0.6, self.left)
                    self._poll_direction('right', axis_x > 0.6, self.right)
                else:
                    self._poll_direction('left', False, self.left)
                    self._poll_direction('right', False, self.right)
                if joystick.get_numaxes() > 1:
                    axis_y = joystick.get_axis(1)
                    self._poll_direction('up', axis_y < -0.6, self.up)
                    self._poll_direction('down', axis_y > 0.6, self.down)
                else:
                    self._poll_direction('up', False, self.up)
                    self._poll_direction('down', False, self.down)
                current = {}
                for button_id, signal in ((0, self.select), (1, self.back), (3, self.guide)):
                    pressed = (joystick.get_button(button_id)
                               if joystick.get_numbuttons() > button_id else 0)
                    current[button_id] = pressed
                    previous = self.last_buttons.get(joystick.get_id(), {})
                    if pressed and not previous.get(button_id, 0):
                        signal.emit()
                self.last_buttons[joystick.get_id()] = current
        except Exception:
            pass

    def _poll_direction(self, direction, active, signal):
        if not active:
            self.held_directions.discard(direction)
            return
        now = time.monotonic()
        last = self.last_direction_emit.get(direction, 0.0)
        if direction not in self.held_directions or now - last >= 0.14:
            signal.emit()
            self.held_directions.add(direction)
            self.last_direction_emit[direction] = now


class StoreDialog(QtWidgets.QDialog):
    STARTING_XUI = 500

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle('XUI Game Store')
        self.setWindowModality(QtCore.Qt.ApplicationModal)
        self.setWindowFlags(self.windowFlags() | QtCore.Qt.WindowStaysOnTopHint)
        self.resize(1000, 680)
        self.setStyleSheet('''
            QDialog { background:#101a22; color:#e7edf0; }
            QLabel { color:#e7edf0; }
            QLineEdit, QComboBox, QTableWidget, QPlainTextEdit {
                background:#192731; color:#e7edf0; border:1px solid #344650;
                selection-background-color:#3c9c43;
            }
            QHeaderView::section { background:#263640; color:#e7edf0; padding:7px;
                                   border:0; }
            QPushButton { background:#344650; color:white; padding:9px 13px; border:0; }
            QPushButton:disabled { color:#89959a; background:#26343d; }
            QPushButton#buyButton { background:#4cae43; font-weight:bold; }
        ''')
        self.games = self._load_catalog()
        self.games_by_id = {game['id']: game for game in self.games}
        self.wallet = self._load_wallet()
        self.owned_ids = self._load_library()
        self.visible_games = []
        self._build_ui()
        self._refresh_table()

    def _read_json(self, path, fallback):
        try:
            with path.open(encoding='utf-8') as data_file:
                return json.load(data_file)
        except (OSError, ValueError, TypeError):
            return fallback

    def _write_json(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary_path = path.with_suffix(path.suffix + '.tmp')
        temporary_path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding='utf-8')
        temporary_path.replace(path)

    def _load_catalog(self):
        catalog = self._read_json(PORTS_CATALOG_FILE, {})
        games = catalog.get('games', []) if isinstance(catalog, dict) else []
        return [game for game in games if isinstance(game, dict) and game.get('id')]

    def _load_wallet(self):
        wallet = self._read_json(XUI_WALLET_FILE, None)
        if not isinstance(wallet, dict):
            wallet = {'balance': self.STARTING_XUI, 'currency': 'XUI'}
            self._write_json(XUI_WALLET_FILE, wallet)
        try:
            wallet['balance'] = max(0, int(wallet.get('balance', 0)))
        except (TypeError, ValueError):
            wallet['balance'] = 0
        wallet['currency'] = 'XUI'
        return wallet

    def _load_library(self):
        library = self._read_json(GAME_LIBRARY_FILE, {})
        ids = library.get('owned_ids', []) if isinstance(library, dict) else []
        return set(ids) if isinstance(ids, list) else set()

    def _build_ui(self):
        layout = QtWidgets.QVBoxLayout(self)
        layout.setContentsMargins(18, 16, 18, 16)
        layout.setSpacing(12)

        header = QtWidgets.QHBoxLayout()
        title = QtWidgets.QLabel('XUI GAME STORE')
        title.setStyleSheet('font-size:22px; font-weight:bold;')
        header.addWidget(title)
        header.addStretch(1)
        self.wallet_label = QtWidgets.QLabel()
        self.wallet_label.setStyleSheet('color:#80d877; font-size:16px; font-weight:bold;')
        header.addWidget(self.wallet_label)
        layout.addLayout(header)

        filters = QtWidgets.QHBoxLayout()
        self.search_box = QtWidgets.QLineEdit()
        self.search_box.setPlaceholderText('Buscar entre los juegos...')
        filters.addWidget(self.search_box, 1)
        self.filter_box = QtWidgets.QComboBox()
        for label, value in (
            ('Todo el catálogo', 'all'),
            ('Demos jugables', 'demo'),
            ('Solo repositorios', 'source'),
            ('Gratis', 'free'),
            ('Con precio XUI', 'paid'),
            ('Mi biblioteca', 'owned'),
        ):
            self.filter_box.addItem(label, value)
        filters.addWidget(self.filter_box)
        layout.addLayout(filters)

        self.table = QtWidgets.QTableWidget(0, 4)
        self.table.setHorizontalHeaderLabels(['Juego', 'Acceso', 'Precio', 'Biblioteca'])
        self.table.setSelectionBehavior(QtWidgets.QAbstractItemView.SelectRows)
        self.table.setSelectionMode(QtWidgets.QAbstractItemView.SingleSelection)
        self.table.setEditTriggers(QtWidgets.QAbstractItemView.NoEditTriggers)
        self.table.verticalHeader().setVisible(False)
        self.table.horizontalHeader().setStretchLastSection(True)
        self.table.horizontalHeader().setSectionResizeMode(0, QtWidgets.QHeaderView.Stretch)
        self.table.horizontalHeader().setSectionResizeMode(1, QtWidgets.QHeaderView.ResizeToContents)
        self.table.horizontalHeader().setSectionResizeMode(2, QtWidgets.QHeaderView.ResizeToContents)
        layout.addWidget(self.table, 1)

        detail = QtWidgets.QHBoxLayout()
        self.detail_label = QtWidgets.QLabel('Selecciona un juego para ver sus opciones.')
        self.detail_label.setWordWrap(True)
        detail.addWidget(self.detail_label, 1)
        self.open_button = QtWidgets.QPushButton('Abrir enlace')
        self.open_button.clicked.connect(self._open_selected_link)
        detail.addWidget(self.open_button)
        self.buy_button = QtWidgets.QPushButton('Comprar')
        self.buy_button.setObjectName('buyButton')
        self.buy_button.clicked.connect(self._buy_selected_game)
        detail.addWidget(self.buy_button)
        close_button = QtWidgets.QPushButton('Cerrar')
        close_button.clicked.connect(self.accept)
        detail.addWidget(close_button)
        layout.addLayout(detail)

        self.search_box.textChanged.connect(self._refresh_table)
        self.filter_box.currentIndexChanged.connect(self._refresh_table)
        self.table.itemSelectionChanged.connect(self._update_selection)
        self._update_wallet_label()

    def _refresh_table(self, *_):
        query = self.search_box.text().strip().casefold()
        filter_mode = self.filter_box.currentData()
        games = []
        for game in self.games:
            game_id = game['id']
            paid = int(game.get('price_xui', 0)) > 0
            has_demo = bool(game.get('demo_url'))
            if query and query not in game.get('name', '').casefold():
                continue
            if filter_mode == 'demo' and not has_demo:
                continue
            if filter_mode == 'source' and (has_demo or not game.get('source_url')):
                continue
            if filter_mode == 'free' and paid:
                continue
            if filter_mode == 'paid' and not paid:
                continue
            if filter_mode == 'owned' and game_id not in self.owned_ids:
                continue
            games.append(game)

        self.visible_games = games
        self.table.setRowCount(len(games))
        for row, game in enumerate(games):
            price = int(game.get('price_xui', 0))
            acquired = game['id'] in self.owned_ids
            access = 'Demo jugable' if game.get('demo_url') else (
                'Repositorio' if game.get('source_url') else 'Sin enlace')
            library_status = 'Comprado' if acquired else ('Gratis' if price == 0 else 'Bloqueado')
            values = (game.get('name', 'Juego'), access,
                      'Gratis' if price == 0 else f'{price} XUI', library_status)
            for column, value in enumerate(values):
                item = QtWidgets.QTableWidgetItem(value)
                if column == 0:
                    item.setData(QtCore.Qt.UserRole, game['id'])
                self.table.setItem(row, column, item)

        if games:
            self.table.selectRow(0)
        else:
            self._update_selection()

    def _selected_game(self):
        row = self.table.currentRow()
        if row < 0 or row >= len(self.visible_games):
            return None
        return self.visible_games[row]

    def _update_selection(self):
        game = self._selected_game()
        if not game:
            self.detail_label.setText('No hay juegos que coincidan con la búsqueda.')
            self.open_button.setEnabled(False)
            self.buy_button.setEnabled(False)
            return
        price = int(game.get('price_xui', 0))
        is_owned = game['id'] in self.owned_ids
        link_kind = 'demo' if game.get('demo_url') else 'repositorio'
        link_available = bool(game.get('demo_url') or game.get('source_url'))
        self.detail_label.setText(
            f"{game.get('name')} · {link_kind.title()} · "
            f"{'Desbloqueado en tu biblioteca' if is_owned else 'Gratis' if price == 0 else 'Precio por popularidad: ' + str(price) + ' XUI'}"
            + (f"\n{game['description']}" if game.get('description') else '')
        )
        self.open_button.setText('Jugar demo' if game.get('demo_url') else 'Abrir repositorio')
        self.open_button.setEnabled(link_available)
        self.buy_button.setVisible(price > 0)
        self.buy_button.setEnabled(price > 0 and not is_owned)
        self.buy_button.setText('Comprado' if is_owned else f'Comprar · {price} XUI')

    def _update_wallet_label(self):
        self.wallet_label.setText(f"Saldo: {self.wallet['balance']} XUI")

    def _open_selected_link(self):
        game = self._selected_game()
        if not game:
            return
        if int(game.get('price_xui', 0)) and game['id'] not in self.owned_ids:
            QtWidgets.QMessageBox.information(self, 'Juego bloqueado', 'Compra este juego para abrir su demo.')
            return
        url = game.get('demo_url') or game.get('source_url')
        if url:
            QtGui.QDesktopServices.openUrl(QtCore.QUrl(url))

    def _buy_selected_game(self):
        game = self._selected_game()
        if not game:
            return
        price = int(game.get('price_xui', 0))
        if price <= 0 or game['id'] in self.owned_ids:
            return
        if self.wallet['balance'] < price:
            QtWidgets.QMessageBox.warning(self, 'Saldo insuficiente', 'No tienes suficientes monedas XUI.')
            return
        answer = QtWidgets.QMessageBox.question(
            self, 'Confirmar compra',
            f"Desbloquear {game.get('name')} por {price} XUI? Son monedas virtuales locales.",
            QtWidgets.QMessageBox.Yes | QtWidgets.QMessageBox.No,
            QtWidgets.QMessageBox.No,
        )
        if answer != QtWidgets.QMessageBox.Yes:
            return
        self.wallet['balance'] -= price
        self.owned_ids.add(game['id'])
        self._write_json(XUI_WALLET_FILE, self.wallet)
        self._write_json(GAME_LIBRARY_FILE, {'owned_ids': sorted(self.owned_ids)})
        self._update_wallet_label()
        self._refresh_table()
        for row, visible_game in enumerate(self.visible_games):
            if visible_game['id'] == game['id']:
                self.table.selectRow(row)
                break


class TileWidget(QtWidgets.QFrame):
    def __init__(self, name, img_path=None, size=(220, 140), parent=None):
        super().__init__(parent)
        self.name = name
        self.img_path = img_path
        self.setObjectName('tile')
        self.setMinimumSize(*size)
        self.setFocusPolicy(QtCore.Qt.StrongFocus)
        self.setStyleSheet(self.default_style())
        v = QtWidgets.QVBoxLayout(self)
        v.setContentsMargins(12, 12, 12, 12)
        v.setSpacing(10)
        self.img_label = QtWidgets.QLabel()
        self.img_label.setAlignment(QtCore.Qt.AlignCenter)
        self.img_label.setFixedHeight(size[1] - 60)
        self.img_label.setScaledContents(False)
        self.title = QtWidgets.QLabel(name)
        self.title.setAlignment(QtCore.Qt.AlignCenter)
        self.title.setStyleSheet('color:white; font-weight:600; letter-spacing:0.5px;')
        v.addWidget(self.img_label)
        v.addWidget(self.title)
        self.anim = QtCore.QPropertyAnimation(self, b"geometry")
        self.load_image()

    def default_style(self):
        return "QFrame#tile { background: qlineargradient(spread:pad, x1:0, y1:0, x2:1, y2:1, stop:0 #0d3b7a, stop:1 #0f65c6); border: 2px solid #0b2c52; border-radius:10px; } QLabel { color: white; }"

    def load_image(self):
        if self.img_path and Path(self.img_path).exists():
            pix = QtGui.QPixmap(str(self.img_path))
            if not pix.isNull():
                scaled = pix.scaled(self.img_label.size(), QtCore.Qt.KeepAspectRatio, QtCore.Qt.SmoothTransformation)
                self.img_label.setPixmap(scaled)
                return
        placeholder = QtGui.QPixmap(self.img_label.width(), self.img_label.height())
        placeholder.fill(QtGui.QColor('#0b1c2f'))
        self.img_label.setPixmap(placeholder)

    def resizeEvent(self, e):
        self.load_image()
        super().resizeEvent(e)

    def focusInEvent(self, e):
        rect = self.geometry()
        self.anim.stop()
        self.anim.setDuration(160)
        self.anim.setStartValue(rect)
        self.anim.setEndValue(QtCore.QRect(rect.x() - 6, rect.y() - 6, rect.width() + 12, rect.height() + 12))
        self.anim.start()
        self.setStyleSheet("QFrame#tile { background:#1a8dff; border: 3px solid #7fe8ff; border-radius:10px; box-shadow: 0 0 12px rgba(0,255,255,0.4);} QLabel { color: white; font-weight:bold; }")
        super().focusInEvent(e)

    def focusOutEvent(self, e):
        self.anim.stop()
        rect = self.geometry()
        self.anim.setDuration(120)
        self.anim.setStartValue(rect)
        self.anim.setEndValue(QtCore.QRect(rect.x() + 6, rect.y() + 6, rect.width() - 12, rect.height() - 12))
        self.anim.start()
        self.setStyleSheet(self.default_style())
        super().focusOutEvent(e)

    def mousePressEvent(self, e):
        win = QtWidgets.QApplication.activeWindow()
        if win and hasattr(win, 'on_tile_clicked'):
            win.on_tile_clicked(self.name)
        else:
            super().mousePressEvent(e)


class MainWindow(QtWidgets.QMainWindow):
    def __init__(self, windowed=False):
        super().__init__()
        if os.name == 'nt' and not windowed:
            self.setWindowFlag(QtCore.Qt.WindowStaysOnTopHint, True)
        self.setWindowTitle('XUI GUI - Xbox Style')
        self.setMinimumSize(1280, 720)
        central = QtWidgets.QWidget()
        main_l = QtWidgets.QHBoxLayout(central)
        main_l.setContentsMargins(32, 28, 32, 28)
        main_l.setSpacing(20)

        left = QtWidgets.QVBoxLayout()
        left.setSpacing(10)
        user_lbl = QtWidgets.QLabel('Usuario')
        user_lbl.setStyleSheet('color:white; font-weight:bold; font-size:18px;')
        left.addWidget(user_lbl)
        for t in ['Perfil', 'Compat X86']:
            lbl = QtWidgets.QLabel(t)
            lbl.setStyleSheet('background:#0C54A6; color:white; padding:12px; border-radius:10px;')
            lbl.setFixedHeight(58)
            left.addWidget(lbl)
        left.addStretch()
        left_widget = QtWidgets.QFrame()
        left_widget.setLayout(left)
        left_widget.setFixedWidth(210)
        left_widget.setStyleSheet('background:rgba(0,0,0,0.35); border:1px solid #0b2c52; border-radius:14px;')

        center = QtWidgets.QWidget()
        grid = QtWidgets.QGridLayout(center)
        grid.setHorizontalSpacing(14)
        grid.setVerticalSpacing(14)
        grid.setContentsMargins(4, 4, 4, 4)
        hero = TileWidget('Casino', ASSETS / 'Casino.png', size=(520, 300))
        hero.setSizePolicy(QtWidgets.QSizePolicy.Expanding, QtWidgets.QSizePolicy.Expanding)
        grid.addWidget(hero, 0, 0, 2, 2)
        others = ['Runner', 'Store', 'Misiones', 'LAN', 'Settings', 'Power Profile', 'Battery Saver']
        positions = [(0, 2), (1, 2), (2, 0), (2, 1), (2, 2), (3, 0), (3, 1)]
        self.tiles = [hero]
        for name, pos in zip(others, positions):
            img_webp = ASSETS / f"{name}.webp"
            img_png = ASSETS / f"{name}.png"
            img = img_webp if img_webp.exists() else (img_png if img_png.exists() else None)
            tw = TileWidget(name, img if img is not None else None, size=(240, 150))
            tw.setSizePolicy(QtWidgets.QSizePolicy.Expanding, QtWidgets.QSizePolicy.Expanding)
            grid.addWidget(tw, pos[0], pos[1])
            self.tiles.append(tw)
        grid.setColumnStretch(0, 2)
        grid.setColumnStretch(1, 2)
        grid.setColumnStretch(2, 1)
        grid.setRowStretch(0, 2)
        grid.setRowStretch(1, 2)
        grid.setRowStretch(2, 1)
        grid.setRowStretch(3, 1)

        right = QtWidgets.QVBoxLayout()
        right.setSpacing(10)
        right_title = QtWidgets.QLabel('Featured')
        right_title.setStyleSheet('color:white; font-weight:bold; font-size:16px;')
        right.addWidget(right_title)
        for i in range(4):
            lbl = QtWidgets.QLabel(f'Featured {i+1}')
            lbl.setFixedHeight(76)
            lbl.setAlignment(QtCore.Qt.AlignVCenter | QtCore.Qt.AlignLeft)
            lbl.setStyleSheet('background:#0f1724; color:white; border:1px solid #1f2f45; padding:12px; border-radius:12px;')
            right.addWidget(lbl)
        right.addStretch()
        right_widget = QtWidgets.QFrame()
        right_widget.setLayout(right)
        right_widget.setFixedWidth(270)
        right_widget.setStyleSheet('background:rgba(0,0,0,0.32); border:1px solid #0b2c52; border-radius:14px;')

        main_l.addWidget(left_widget)
        main_l.addWidget(center, 1)
        main_l.addWidget(right_widget)
        self.setCentralWidget(central)
        self.current_index = 0
        QtCore.QTimer.singleShot(120, self.update_focus)
        self.windowed = windowed
        self._party_active = False
        self._guide_dialog = None
        self._guide_shortcut = QtWidgets.QShortcut(QtGui.QKeySequence(QtCore.Qt.Key_F1), self)
        self._guide_shortcut.activated.connect(self.show_controller_guide)
        self.gamepad = GamepadListener(self)
        self.gamepad.left.connect(lambda: self._dispatch_gamepad_key(QtCore.Qt.Key_Left))
        self.gamepad.right.connect(lambda: self._dispatch_gamepad_key(QtCore.Qt.Key_Right))
        self.gamepad.up.connect(lambda: self._dispatch_gamepad_key(QtCore.Qt.Key_Up))
        self.gamepad.down.connect(lambda: self._dispatch_gamepad_key(QtCore.Qt.Key_Down))
        self.gamepad.select.connect(lambda: self._dispatch_gamepad_key(QtCore.Qt.Key_Return))
        self.gamepad.back.connect(lambda: self._dispatch_gamepad_key(QtCore.Qt.Key_Escape))
        self.gamepad.guide.connect(self.show_controller_guide)

    def _guide_actions(self):
        return {
            'friends': self._guide_show_friends,
            'party': self._guide_show_party,
            'messages': self._guide_show_messages,
            'chat': self._guide_show_chat,
            'activity': self._guide_show_activity,
            'settings': lambda: self.on_tile_clicked('Settings'),
            'media': self._guide_open_media,
            'library': self._guide_open_library,
            'minimize': self.showMinimized,
            'close': self._guide_close_dashboard,
        }

    def show_controller_guide(self):
        if self._guide_dialog and self._guide_dialog.isVisible():
            self._guide_dialog.reject()
            return
        self._guide_dialog = XboxGuideDialog(self._guide_actions(), self)
        self._guide_dialog.exec_()
        self._guide_dialog = None
        if not self.isMinimized() and self.isVisible():
            self.activateWindow()

    def _dispatch_gamepad_key(self, key):
        target = QtWidgets.QApplication.activeWindow() or self
        event = QtGui.QKeyEvent(QtCore.QEvent.KeyPress, key, QtCore.Qt.NoModifier)
        QtWidgets.QApplication.sendEvent(target, event)

    def _guide_show_dialog(self, title, text):
        dialog = QtWidgets.QDialog(self)
        dialog.setWindowTitle(title)
        dialog.resize(440, 340)
        layout = QtWidgets.QVBoxLayout(dialog)
        content = QtWidgets.QPlainTextEdit()
        content.setReadOnly(True)
        content.setPlainText(text or 'No hay contenido disponible.')
        layout.addWidget(content)
        close_button = QtWidgets.QPushButton('Cerrar')
        close_button.clicked.connect(dialog.accept)
        layout.addWidget(close_button)
        dialog.exec_()

    def _guide_show_friends(self):
        try:
            friends = json.load(open(Path.home() / '.xui' / 'data' / 'friends.json', encoding='utf-8'))
        except Exception:
            friends = []
        lines = [f"{'●' if friend.get('online') else '○'}  {friend.get('name', 'Amigo')}"
                 for friend in friends]
        self._guide_show_dialog('Friends', '\n'.join(lines))

    def _guide_show_party(self):
        dialog = QtWidgets.QDialog(self)
        dialog.setWindowTitle('Party')
        layout = QtWidgets.QVBoxLayout(dialog)
        status = QtWidgets.QLabel('Party activa' if self._party_active else 'No hay una party activa')
        layout.addWidget(status)
        toggle = QtWidgets.QPushButton('Salir de la party' if self._party_active else 'Crear party')

        def toggle_party():
            self._party_active = not self._party_active
            status.setText('Party activa' if self._party_active else 'No hay una party activa')
            toggle.setText('Salir de la party' if self._party_active else 'Crear party')

        toggle.clicked.connect(toggle_party)
        layout.addWidget(toggle)
        invite = QtWidgets.QPushButton('Ver amigos')
        invite.clicked.connect(self._guide_show_friends)
        layout.addWidget(invite)
        close_button = QtWidgets.QPushButton('Cerrar')
        close_button.clicked.connect(dialog.accept)
        layout.addWidget(close_button)
        dialog.exec_()

    def _guide_show_messages(self):
        path = Path.home() / '.xui' / 'data' / 'notifications.json'
        try:
            messages = json.load(open(path, encoding='utf-8'))
        except Exception:
            messages = []
        lines = [message.get('text', '') for message in messages]
        for message in messages:
            message['read'] = True
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            json.dump(messages, open(path, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
        except Exception:
            pass
        self._guide_show_dialog('Messages', '\n'.join(lines))

    def _guide_show_chat(self):
        path = Path.home() / '.xui' / 'data' / 'chat.json'
        try:
            messages = json.load(open(path, encoding='utf-8'))
        except Exception:
            messages = []
        dialog = QtWidgets.QDialog(self)
        dialog.setWindowTitle('Chat')
        dialog.resize(440, 340)
        layout = QtWidgets.QVBoxLayout(dialog)
        history = QtWidgets.QPlainTextEdit()
        history.setReadOnly(True)
        history.setPlainText('\n'.join(f"{item.get('sender', 'Tú')}: {item.get('text', '')}"
                                       for item in messages))
        layout.addWidget(history)
        entry = QtWidgets.QLineEdit()
        entry.setPlaceholderText('Escribe un mensaje')
        layout.addWidget(entry)
        send_button = QtWidgets.QPushButton('Enviar')

        def send_message():
            text = entry.text().strip()
            if not text:
                return
            messages.append({'sender': 'Tú', 'text': text})
            history.appendPlainText(f'Tú: {text}')
            entry.clear()
            try:
                path.parent.mkdir(parents=True, exist_ok=True)
                json.dump(messages, open(path, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
            except Exception:
                pass

        send_button.clicked.connect(send_message)
        entry.returnPressed.connect(send_message)
        layout.addWidget(send_button)
        close_button = QtWidgets.QPushButton('Cerrar')
        close_button.clicked.connect(dialog.accept)
        layout.addWidget(close_button)
        dialog.exec_()

    def _guide_show_activity(self):
        sections = []
        for title, path in (
            ('Misiones', Path.home() / '.xui' / 'data' / 'missions.json'),
            ('Logros', Path.home() / '.xui' / 'data' / 'achievements.json'),
        ):
            try:
                entries = json.load(open(path, encoding='utf-8'))
            except Exception:
                entries = []
            sections.append(title)
            sections.extend(f"{'[x]' if item.get('done') else '[ ]'} {item.get('title', '')}: "
                            f"{item.get('desc', '')}" for item in entries)
        self._guide_show_dialog('Beacons & Activity', '\n'.join(sections))

    def _guide_open_media(self):
        ASSETS.mkdir(parents=True, exist_ok=True)
        QtGui.QDesktopServices.openUrl(QtCore.QUrl.fromLocalFile(str(ASSETS)))

    def _guide_open_library(self):
        library = Path.home() / '.xui' / 'games'
        target = library if library.exists() else Path.home() / '.xui'
        QtGui.QDesktopServices.openUrl(QtCore.QUrl.fromLocalFile(str(target)))

    def _guide_close_dashboard(self):
        answer = QtWidgets.QMessageBox.question(
            self, 'Close Game', '¿Quieres cerrar el dashboard?',
            QtWidgets.QMessageBox.Yes | QtWidgets.QMessageBox.No,
            QtWidgets.QMessageBox.No,
        )
        if answer == QtWidgets.QMessageBox.Yes:
            self.close()

    def keyPressEvent(self, event):
        if event.key() == QtCore.Qt.Key_F1:
            self.show_controller_guide()
        elif event.key() in (QtCore.Qt.Key_Left, QtCore.Qt.Key_Up):
            self.current_index = (self.current_index - 1) % len(self.tiles)
            self.update_focus()
        elif event.key() in (QtCore.Qt.Key_Right, QtCore.Qt.Key_Down):
            self.current_index = (self.current_index + 1) % len(self.tiles)
            self.update_focus()
        elif event.key() in (QtCore.Qt.Key_Return, QtCore.Qt.Key_Enter, QtCore.Qt.Key_Space):
            self.on_tile_clicked(self.tiles[self.current_index].name)
        else:
            super().keyPressEvent(event)

    def update_focus(self):
        if 0 <= self.current_index < len(self.tiles):
            self.tiles[self.current_index].setFocus()

    def on_tile_clicked(self, name):
        xui = str(Path.home() / '.xui')
        if name == 'Casino':
            dlg = SlotMachineDialog(self)
            dlg.exec_()
        elif name == 'Store':
            dlg = StoreDialog(self)
            dlg.exec_()
        elif name == 'LAN':
            dlg = QtWidgets.QDialog(self)
            dlg.setWindowTitle('LAN Info')
            t = QtWidgets.QPlainTextEdit()
            t.setReadOnly(True)
            try:
                out = subprocess.getoutput('ipconfig') if os.name == 'nt' else subprocess.getoutput('ip -4 addr show | sed -n "1,40p"')
            except Exception:
                out = 'No se pudo obtener red'
            t.setPlainText(out)
            l = QtWidgets.QVBoxLayout(dlg)
            l.addWidget(t)
            b = QtWidgets.QPushButton('Cerrar')
            b.clicked.connect(dlg.accept)
            l.addWidget(b)
            dlg.exec_()
        elif name == 'Settings':
            dlg = QtWidgets.QDialog(self)
            dlg.setWindowTitle('Settings')
            layout = QtWidgets.QVBoxLayout(dlg)
            sounds_cb = QtWidgets.QCheckBox('Enable sounds')
            try:
                s = json.load(open(SETTINGS_FILE)) if SETTINGS_FILE.exists() else {}
                sounds_cb.setChecked(bool(s.get('sounds', True)))
            except Exception:
                sounds_cb.setChecked(True)
            layout.addWidget(sounds_cb)
            reset_btn = QtWidgets.QPushButton('Reset slot credits')

            def do_reset():
                try:
                    json.dump({'credits': 100}, open(SLOTS_FILE, 'w'))
                    QtWidgets.QMessageBox.information(dlg, 'Reset', 'Credits reset to 100')
                except Exception:
                    QtWidgets.QMessageBox.warning(dlg, 'Error', 'Could not reset')

            reset_btn.clicked.connect(do_reset)
            layout.addWidget(reset_btn)
            ok = QtWidgets.QPushButton('Guardar')

            def save_settings():
                try:
                    json.dump({'sounds': bool(sounds_cb.isChecked())}, open(SETTINGS_FILE, 'w'))
                    dlg.accept()
                except Exception:
                    dlg.reject()

            ok.clicked.connect(save_settings)
            layout.addWidget(ok)
            dlg.exec_()
        elif name == 'Misiones':
            dlg = QtWidgets.QDialog(self)
            dlg.setWindowTitle('Misiones')
            l = QtWidgets.QVBoxLayout(dlg)
            try:
                missions = json.load(open(MISSIONS_FILE)) if MISSIONS_FILE.exists() else [{'title': 'Demo Mision', 'desc': 'Haz algo divertido'}]
            except Exception:
                missions = [{'title': 'Demo Mision', 'desc': 'Haz algo divertido'}]
            for m in missions:
                w = QtWidgets.QGroupBox(m.get('title', 'Mision'))
                v = QtWidgets.QVBoxLayout()
                v.addWidget(QtWidgets.QLabel(m.get('desc', '')))
                w.setLayout(v)
                l.addWidget(w)
            btn = QtWidgets.QPushButton('Cerrar')
            btn.clicked.connect(dlg.accept)
            l.addWidget(btn)
            dlg.exec_()
        else:
            candidate = os.path.join(xui, name.lower(), f"{name}.py")
            if os.path.exists(candidate):
                QtCore.QProcess.startDetached(sys.executable, [candidate])
            else:
                script_dir = os.path.join(xui, 'bin')
                if os.name == 'nt':
                    ps_script = os.path.join(script_dir, f'xui_{name.lower()}.ps1')
                    cmd_script = os.path.join(script_dir, f'xui_{name.lower()}.cmd')
                    if os.path.exists(ps_script):
                        QtCore.QProcess.startDetached(
                            'powershell.exe',
                            ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ps_script],
                        )
                    elif os.path.exists(cmd_script):
                        QtCore.QProcess.startDetached('cmd.exe', ['/c', cmd_script])
                else:
                    script = os.path.join(script_dir, f'xui_{name.lower()}.sh')
                    if os.path.exists(script):
                        QtCore.QProcess.startDetached('/bin/sh', ['-c', script])


if __name__ == '__main__':
    windowed = '--windowed' in sys.argv
    app = QtWidgets.QApplication(sys.argv)
    app.setStyleSheet('''
        QWidget { background: qradialgradient(cx:0.3, cy:0.3, radius:1.2, fx:0.3, fy:0.3, stop:0 #0a0f1a, stop:1 #081526); color: #e6eef6; }
        QFrame#tile { background: #0C54A6; border-radius: 10px; }
        QLabel { color: #e6eef6; }
        QPushButton { background: #154a70; color: #fff; border-radius:8px; padding:10px; font-weight:600; }
    ''')
    w = MainWindow(windowed=windowed)
    try:
        if not windowed:
            w.showFullScreen()
            w.raise_()
            w.activateWindow()
        else:
            w.resize(1280, 768)
            w.show()
    except Exception:
        w.show()
    sys.exit(app.exec_())
