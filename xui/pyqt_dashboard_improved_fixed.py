#!/usr/bin/env python3
import sys
import os
import subprocess
import time
import random
import json
import shutil
from pathlib import Path

ASSETS = Path.home() / '.xui' / 'assets'
DATA = Path.home() / '.xui' / 'data'
DATA.mkdir(parents=True, exist_ok=True)
SLOTS_FILE = DATA / 'slots.json'
MISSIONS_FILE = DATA / 'missions.json'
SETTINGS_FILE = DATA / 'settings.json'


def ensure_default_data():
    """Create minimal default data files (achievements, friends, notifications, saldo) if missing."""
    try:
        DATA.mkdir(parents=True, exist_ok=True)
        ach = DATA / 'achievements.json'
        if not ach.exists():
            json.dump([
                {'id':'welcome','title':'Bienvenido','desc':'Inicia XUI por primera vez','done':False,'reward':10}
            ], open(ach, 'w'))
        fr = DATA / 'friends.json'
        if not fr.exists():
            json.dump([
                {'name':'Amigo1','online':False},
                {'name':'Amigo2','online':True}
            ], open(fr, 'w'))
        # simple notifications and saldo defaults
        notif = DATA / 'notifications.json'
        if not notif.exists():
            json.dump([
                {'id':'welcome','text':'Welcome to XUI','read':False}
            ], open(notif,'w'))
        saldo = DATA / 'saldo.json'
        if not saldo.exists():
            json.dump({'balance': 0.0, 'currency': 'EUR'}, open(saldo,'w'))
        # basic missions & store sample
        missions = DATA / 'missions.json'
        if not missions.exists():
            json.dump([{'title':'Demo Mision','desc':'Haz algo divertido','done':False}], open(missions,'w'))
        store = DATA / 'store.json'
        if not store.exists():
            json.dump({'items':[]}, open(store,'w'))
        # default settings (only write when missing)
        if not SETTINGS_FILE.exists():
            default_settings = {
                'sounds': True,
                'theme': 'dark',
                'gamepad': {
                    'deadzone': 0.6,
                    'repeat_initial': 350,
                    'repeat_rate': 120,
                    'select_btn': 0,
                    'back_btn': 1,
                    'guide_btn': 3
                }
            }
            json.dump(default_settings, open(SETTINGS_FILE, 'w'))
    except Exception:
        pass

try:
    from PyQt5 import QtWidgets, QtGui, QtCore
except Exception:
    print('PyQt5 not installed')
    sys.exit(1)

# Optional pygame-based gamepad listener (best-effort)
try:
    import pygame
    HAVE_PYGAME = True
except Exception:
    HAVE_PYGAME = False


# Theme helpers
def load_settings():
    try:
        return json.load(open(SETTINGS_FILE)) if SETTINGS_FILE.exists() else {}
    except Exception:
        return {}


def save_settings(d):
    try:
        json.dump(d, open(SETTINGS_FILE, 'w'))
    except Exception:
        pass


def apply_theme(app, name='dark'):
    # two simple themes (dark and light) using QSS variables
    if name == 'light':
        qss = '''
QWidget { background: qlineargradient(x1:0,y1:0,x2:1,y2:1, stop:0 #f6f9fc, stop:1 #e6eef6); color: #0b2233; font-family: Segoe UI, Arial; }
QFrame#tile { background: #e8f4ff; border: 2px solid #c6dff0; border-radius: 12px; }
QLabel { color: #022; }
QPushButton { background: #2b8bd6; color: #fff; border-radius:8px; padding:8px; }
'''
    else:
        qss = '''
QWidget { background: qradialgradient(cx:0.3, cy:0.3, radius: 1.0, fx:0.3, fy:0.3, stop:0 #071017, stop:1 #0b0f13); color: #e6eef6; font-family: Segoe UI, Arial; }
QFrame#tile { background: #0C54A6; border: 2px solid rgba(0,0,0,0.35); border-radius: 12px; }
QLabel { color: #e6eef6; }
QPushButton { background: qlineargradient(x1:0,y1:0,x2:0,y2:1, stop:0 #1e90ff, stop:1 #154a70); color: #fff; border-radius:8px; padding:8px; }
QFrame#tile:hover { border: 2px solid #00ffff; }
'''
    try:
        app.setStyleSheet(qss)
    except Exception:
        pass


def play_sound(fname):
    """Play a sound from the assets folder. Accepts a basename with or without extension.
    Tries common audio extensions and uses `mpv` when available.
    """
    # normalize name
    name = str(fname)
    candidates = []
    p = ASSETS / name
    if p.suffix:
        candidates.append(p)
    else:
        for ext in ('.mp3', '.wav', '.ogg'):
            candidates.append(ASSETS / (name + ext))
    # also accept .mp4 -> but prefer mp3/wav with same stem
    if name.lower().endswith('.mp4'):
        stem = Path(name).stem
        for ext in ('.mp3', '.wav'):
            candidates.insert(0, ASSETS / (stem + ext))
    for c in candidates:
        if c.exists():
            try:
                if shutil.which('mpv'):
                    # prefer mpv for quiet playback
                    if str(c).lower().endswith('.mp4'):
                        subprocess.Popen(['mpv', '--really-quiet', str(c)])
                    else:
                        subprocess.Popen(['mpv', '--no-video', '--really-quiet', str(c)])
                else:
                    # fall back to QtMultimedia if available
                    try:
                        from PyQt5 import QtMultimedia
                        url = QtCore.QUrl.fromLocalFile(str(c))
                        content = QtMultimedia.QMediaContent(url)
                        player = QtMultimedia.QMediaPlayer()
                        player.setMedia(content)
                        player.setVolume(50)
                        player.play()
                    except Exception:
                        pass
            except Exception:
                pass
            break


class SlotMachineDialog(QtWidgets.QDialog):
        """Simple tragaperras (slots) with animated reels using emojis/text.
        Runs inside the dashboard as a modal dialog."""

        SYMBOLS = ['🍒', '🔔', '🍋', '⭐', '7']


class GamepadListener(QtCore.QObject):
        """Polls pygame joysticks and emits directional/select/back/guide signals.
        Implements a deadzone and simple hold-to-repeat behaviour so navigation is comfortable."""
        left = QtCore.pyqtSignal()
        right = QtCore.pyqtSignal()
        up = QtCore.pyqtSignal()
        down = QtCore.pyqtSignal()
        select = QtCore.pyqtSignal()
        back = QtCore.pyqtSignal()
        guide = QtCore.pyqtSignal()

        def __init__(self, parent=None, settings=None):
            super().__init__(parent)
            self.timer = None
            self.inited = False
            # defaults (may be overridden by settings)
            self.deadzone = 0.6
            self.repeat_initial = 350
            self.repeat_rate = 120
            self.btn_select = 0
            self.btn_back = 1
            self.btn_guide = 3
            self._last_emit = {'left':0.0,'right':0.0,'up':0.0,'down':0.0}
            self._held = {'left':False,'right':False,'up':False,'down':False}
            self._last_buttons = {}
            if settings:
                self.update_settings(settings)
            if not HAVE_PYGAME:
                return
            try:
                pygame.init()
                pygame.joystick.init()
                self.joysticks = [pygame.joystick.Joystick(i) for i in range(pygame.joystick.get_count())]
                for j in self.joysticks:
                    try:
                        j.init()
                    except Exception:
                        pass
                self.timer = QtCore.QTimer(self)
                self.timer.timeout.connect(self.poll)
                self.timer.start(50)
                self.inited = True
            except Exception:
                self.inited = False

        def update_settings(self, cfg):
            try:
                self.deadzone = float(cfg.get('deadzone', self.deadzone))
                self.repeat_initial = int(cfg.get('repeat_initial', self.repeat_initial))
                self.repeat_rate = int(cfg.get('repeat_rate', self.repeat_rate))
                self.btn_select = int(cfg.get('select_btn', self.btn_select))
                self.btn_back = int(cfg.get('back_btn', self.btn_back))
                self.btn_guide = int(cfg.get('guide_btn', self.btn_guide))
            except Exception:
                pass

        def poll(self):
            try:
                now = time.time() * 1000.0
                pygame.event.pump()
                for j in self.joysticks:
                    ax0 = j.get_axis(0) if j.get_numaxes() > 0 else 0.0
                    ax1 = j.get_axis(1) if j.get_numaxes() > 1 else 0.0
                    # horizontal
                    if ax0 < -self.deadzone:
                        self._maybe_emit('left', now)
                    elif ax0 > self.deadzone:
                        self._maybe_emit('right', now)
                    else:
                        self._held['left'] = False; self._held['right'] = False
                    # vertical
                    if ax1 < -self.deadzone:
                        self._maybe_emit('up', now)
                    elif ax1 > self.deadzone:
                        self._maybe_emit('down', now)
                    else:
                        self._held['up'] = False; self._held['down'] = False
                    # buttons use configured ids
                    nb = j.get_numbuttons()
                    bsel = j.get_button(self.btn_select) if nb>self.btn_select else 0
                    bback = j.get_button(self.btn_back) if nb>self.btn_back else 0
                    bguide = j.get_button(self.btn_guide) if nb>self.btn_guide else 0
                    prev = self._last_buttons.get(j.get_id(), {})
                    if bsel and not prev.get(self.btn_select,0):
                        self.select.emit()
                    if bback and not prev.get(self.btn_back,0):
                        self.back.emit()
                    if bguide and not prev.get(self.btn_guide,0):
                        self.guide.emit()
                    # store last btns (only those we checked)
                    self._last_buttons[j.get_id()] = {self.btn_select:bsel, self.btn_back:bback, self.btn_guide:bguide}
            except Exception:
                pass

        def _maybe_emit(self, direction, now):
            # emit on first press, then after initial delay allow repeats
            last = self._last_emit.get(direction, 0.0)
            held = self._held.get(direction, False)
            if not held:
                # first time
                self._emit_direction(direction)
                self._held[direction] = True
                self._last_emit[direction] = now
            else:
                if now - last >= self.repeat_rate:
                    self._emit_direction(direction)
                    self._last_emit[direction] = now

        def _emit_direction(self, direction):
            try:
                if direction == 'left': self.left.emit()
                elif direction == 'right': self.right.emit()
                elif direction == 'up': self.up.emit()
                elif direction == 'down': self.down.emit()
            except Exception:
                pass

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
            # use the global helper which will pick best extension
            try:
                play_sound(fname)
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


class TileWidget(QtWidgets.QFrame):
        def __init__(self, name, img_path=None, parent=None, big=False):
            super().__init__(parent)
            self.name = name
            self.img_path = img_path
            self.big = big
            self.setObjectName('tile')
            self.setFocusPolicy(QtCore.Qt.StrongFocus)
            self.setStyleSheet(self.default_style())
            v = QtWidgets.QVBoxLayout(self)
            self.img_label = QtWidgets.QLabel()
            self.img_label.setAlignment(QtCore.Qt.AlignCenter)
            self.img_label.setFixedHeight(180 if big else 100)
            # load image if provided
            try:
                if img_path is not None:
                    p = Path(img_path)
                    if p.exists():
                        pm = QtGui.QPixmap(str(p)).scaled(self.img_label.width() or 200, self.img_label.height(), QtCore.Qt.KeepAspectRatio, QtCore.Qt.SmoothTransformation)
                        self.img_label.setPixmap(pm)
            except Exception:
                pass
            self.title = QtWidgets.QLabel(name)
            self.title.setAlignment(QtCore.Qt.AlignCenter)
            self.title.setStyleSheet('color:white;')
            v.addWidget(self.img_label)
            v.addWidget(self.title)
            self.anim = QtCore.QPropertyAnimation(self, b"geometry")
            # badge (small overlay) for counts/indicators
            self.badge = QtWidgets.QLabel('', self)
            self.badge.setStyleSheet('background:#ff4d4d; color:white; border-radius:10px; padding:2px 6px;')
            self.badge.hide()

        def set_badge(self, text):
            try:
                if not text:
                    self.badge.hide(); return
                self.badge.setText(str(text))
                self.badge.adjustSize()
                self.badge.show()
            except Exception:
                pass

        def resizeEvent(self, e):
            super().resizeEvent(e)
            try:
                # place badge at top-right
                r = self.rect()
                bw = self.badge.width(); bh = self.badge.height()
                self.badge.move(r.right() - bw - 8, r.top() + 8)
            except Exception:
                pass

        def default_style(self):
            return "QFrame#tile { background: #0C54A6; border: 2px solid #08375a; border-radius:8px; } QLabel { color: white; }"

        def focusInEvent(self, e):
            rect = self.geometry()
            self.anim.stop()
            self.anim.setDuration(160)
            self.anim.setStartValue(rect)
            self.anim.setEndValue(QtCore.QRect(rect.x() - 6, rect.y() - 6, rect.width() + 12, rect.height() + 12))
            self.anim.start()
            self.setStyleSheet("QFrame#tile { background: #1E90FF; border: 3px solid #00FFFF; border-radius:8px; } QLabel { color: white; font-weight: bold; }")
            try:
                play_sound('hover')
            except Exception:
                pass
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
            try:
                play_sound('click')
            except Exception:
                pass
            if win and hasattr(win, 'on_tile_clicked'):
                win.on_tile_clicked(self.name)
            else:
                super().mousePressEvent(e)

        def keyPressEvent(self, event):
            # Forward navigation keys to the main window so arrows/enter/esc work
            win = QtWidgets.QApplication.activeWindow()
            if win and hasattr(win, 'keyPressEvent'):
                try:
                    win.keyPressEvent(event)
                    return
                except Exception:
                    pass
            super().keyPressEvent(event)


class MainWindow(QtWidgets.QMainWindow):
        def __init__(self, windowed=False):
            super().__init__()
            self.setWindowTitle('XUI GUI - Xbox Style')
            central = QtWidgets.QWidget()
            main_l = QtWidgets.QHBoxLayout(central)

            left = QtWidgets.QVBoxLayout()
            user_lbl = QtWidgets.QLabel('Usuario')
            user_lbl.setStyleSheet('color:white; font-weight:bold;')
            left.addWidget(user_lbl)
            left.addSpacing(10)
            left_tiles = ['Perfil', 'Compat X86']
            for t in left_tiles:
                lbl = QtWidgets.QLabel(t)
                lbl.setStyleSheet('background:#0C54A6; color:white; padding:8px; border-radius:6px;')
                lbl.setFixedHeight(48)
                left.addWidget(lbl)
                left.addSpacing(6)
            left.addStretch()
            left_widget = QtWidgets.QFrame()
            left_widget.setLayout(left)
            left_widget.setFixedWidth(180)
            left_widget.setStyleSheet('background: #000;')

            center = QtWidgets.QWidget()
            grid = QtWidgets.QGridLayout(center)
            hero = TileWidget('Casino', ASSETS / 'Casino.png', big=True)
            grid.addWidget(hero, 0, 0, 2, 2)
            others = ['Runner', 'Store', 'Misiones', 'LAN', 'Settings', 'Power Profile', 'Battery Saver', 'Logros', 'Amigos', 'Salir']
            positions = [(0, 2), (1, 2), (2, 0), (2, 1), (2, 2), (3, 0), (3, 1), (3, 2), (3, 3), (4, 0)]
            self.tiles = [hero]
            for name, pos in zip(others, positions):
                img_webp = ASSETS / (f"{name}.webp")
                img_png = ASSETS / (f"{name}.png")
                img = img_webp if img_webp.exists() else (img_png if img_png.exists() else None)
                tw = TileWidget(name, img if img is not None else None, big=False)
                grid.addWidget(tw, pos[0], pos[1])
                self.tiles.append(tw)
            # initial badge update and periodic refresh
            QtCore.QTimer.singleShot(300, self.update_badges)
            self._badges_timer = QtCore.QTimer(self)
            self._badges_timer.timeout.connect(self.update_badges)
            self._badges_timer.start(5000)

            right = QtWidgets.QVBoxLayout()
            right_title = QtWidgets.QLabel('Featured')
            right_title.setStyleSheet('color:white; font-weight:bold')
            right.addWidget(right_title)
            for i in range(4):
                lbl = QtWidgets.QLabel(f'Featured {i+1}')
                lbl.setFixedHeight(70)
                lbl.setStyleSheet('background:#111; color:white; border:1px solid #333; padding:6px;')
                right.addWidget(lbl)
                right.addSpacing(8)
            right.addStretch()
            right_widget = QtWidgets.QFrame()
            right_widget.setLayout(right)
            right_widget.setFixedWidth(240)

            main_l.addWidget(left_widget)
            main_l.addWidget(center, 1)
            main_l.addWidget(right_widget)

            self.setCentralWidget(central)
            self.current_index = 0
            QtCore.QTimer.singleShot(120, self.update_focus)
            self.windowed = windowed

            # overlay used for small notifications / reward animation
            self._overlay = QtWidgets.QLabel('', self)
            self._overlay.setAttribute(QtCore.Qt.WA_TranslucentBackground)
            self._overlay.setStyleSheet('background:rgba(0,0,0,0.6); color:#fff; padding:12px; border-radius:8px; font-size:22px;')
            self._overlay.setAlignment(QtCore.Qt.AlignCenter)
            self._overlay.hide()

            # toast queue and previous badge snapshot
            self._prev_badges = {}
            self._toast_queue = []
            self._toast_label = QtWidgets.QLabel('', self)
            self._toast_label.setStyleSheet('background:rgba(0,0,0,0.7); color:#fff; padding:6px 10px; border-radius:6px;')
            self._toast_label.setAlignment(QtCore.Qt.AlignCenter)
            self._toast_label.hide()

            # gamepad support (best-effort using pygame), configured from settings
            try:
                cfg = load_settings().get('gamepad', {})
                self.gpl = GamepadListener(self, cfg)
                if getattr(self.gpl, 'inited', False):
                    self.gpl.left.connect(lambda: self._nav_by_dir('left'))
                    self.gpl.right.connect(lambda: self._nav_by_dir('right'))
                    self.gpl.up.connect(lambda: self._nav_by_dir('up'))
                    self.gpl.down.connect(lambda: self._nav_by_dir('down'))
                    self.gpl.select.connect(lambda: self._activate_current())
                    self.gpl.back.connect(lambda: self.close())
                    self.gpl.guide.connect(lambda: self.show_controller_guide(True))
            except Exception:
                pass

        def show_reward(self, text, icon_path=None, duration=1600):
            try:
                s = text
                if icon_path:
                    # if icon provided, show it inline
                    self._overlay.setText(s)
                else:
                    self._overlay.setText(s)
                self._overlay.adjustSize()
                # center overlay
                w = self._overlay.width(); h = self._overlay.height()
                cw = self.centralWidget().width(); ch = self.centralWidget().height()
                self._overlay.move((cw-w)//2, (ch-h)//2)
                self._overlay.setWindowOpacity(0.0)
                self._overlay.show()
                # fade in/out
                eff = QtWidgets.QGraphicsOpacityEffect(self._overlay)
                self._overlay.setGraphicsEffect(eff)
                anim = QtCore.QPropertyAnimation(eff, b"opacity")
                anim.setDuration(duration)
                anim.setStartValue(0.0)
                anim.setKeyValueAt(0.2, 1.0)
                anim.setKeyValueAt(0.8, 1.0)
                anim.setEndValue(0.0)
                anim.start()
                QtCore.QTimer.singleShot(duration + 100, lambda: self._overlay.hide())
            except Exception:
                pass

        def _nav_by_dir(self, direction):
            # emulate arrow key navigation
            try:
                ev = QtGui.QKeyEvent(QtCore.QEvent.KeyPress, 0, QtCore.Qt.NoModifier)
                if direction == 'left':
                    k = QtCore.Qt.Key_Left
                elif direction == 'right':
                    k = QtCore.Qt.Key_Right
                elif direction == 'up':
                    k = QtCore.Qt.Key_Up
                else:
                    k = QtCore.Qt.Key_Down
                ev = QtGui.QKeyEvent(QtCore.QEvent.KeyPress, k, QtCore.Qt.NoModifier)
                QtWidgets.QApplication.postEvent(self, ev)
            except Exception:
                pass

        def _activate_current(self):
            try:
                ev = QtGui.QKeyEvent(QtCore.QEvent.KeyPress, QtCore.Qt.Key_Return, QtCore.Qt.NoModifier)
                QtWidgets.QApplication.postEvent(self, ev)
            except Exception:
                pass

        def show_confetti(self, count=22):
            # improved confetti: larger shapes, random sizes, upward burst and optional sound
            try:
                parts = []
                for i in range(count):
                    size = random.randint(8,20)
                    c = QtWidgets.QLabel(self)
                    c.setFixedSize(size, size)
                    col = random.choice(['#ff4d4d','#ffd24d','#4dff88','#4dd0ff','#c04dff','#ff8a4d'])
                    radius = max(2, size//3)
                    c.setStyleSheet(f'background:{col}; border-radius:{radius}px;')
                    c.show()
                    parts.append(c)
                cx = self.centralWidget().width()//2
                cy = self.centralWidget().height()//2
                ag = QtCore.QParallelAnimationGroup(self)
                for idx, p in enumerate(parts):
                    dx = random.randint(-280,280)
                    dy = random.randint(-260,-60)  # burst upwards
                    dur = 900 + random.randint(-200,360)
                    anim = QtCore.QPropertyAnimation(p, b"pos")
                    anim.setDuration(dur)
                    anim.setStartValue(QtCore.QPoint(cx, cy))
                    anim.setEndValue(QtCore.QPoint(cx + dx, cy + dy))
                    anim.setEasingCurve(QtCore.QEasingCurve.OutCubic)
                    fade = QtCore.QPropertyAnimation(p, b"windowOpacity")
                    fade.setDuration(dur)
                    fade.setStartValue(1.0)
                    fade.setEndValue(0.0)
                    ag.addAnimation(anim)
                    ag.addAnimation(fade)
                ag.start(QtCore.QAbstractAnimation.DeleteWhenStopped)
                # optional confetti sound if available
                try:
                    play_sound('confetti')
                except Exception:
                    pass
                QtCore.QTimer.singleShot(1400, lambda: [p.deleteLater() for p in parts])
            except Exception:
                pass

        def show_coin_and_reward(self, text, duration=1200):
            try:
                # coin label (emoji) and reward text, animate scale and upward movement
                coin = QtWidgets.QLabel('🪙', self)
                coin.setStyleSheet('font-size:48px;')
                txt = QtWidgets.QLabel(text, self)
                txt.setStyleSheet('color:#ffdd57; font-size:26px; font-weight:bold;')
                coin.adjustSize(); txt.adjustSize()
                cx = self.centralWidget().width()//2
                cy = self.centralWidget().height()//2
                coin.move(cx - 30, cy - 20); txt.move(cx + 20, cy - 12)
                coin.show(); txt.show()
                # animate position (upwards) and fade
                effc = QtWidgets.QGraphicsOpacityEffect(coin); coin.setGraphicsEffect(effc)
                efft = QtWidgets.QGraphicsOpacityEffect(txt); txt.setGraphicsEffect(efft)
                ap = QtCore.QPropertyAnimation(coin, b"pos"); ap.setDuration(duration); ap.setStartValue(QtCore.QPoint(cx - 30, cy - 20)); ap.setEndValue(QtCore.QPoint(cx - 30, cy - 80))
                at = QtCore.QPropertyAnimation(txt, b"pos"); at.setDuration(duration); at.setStartValue(QtCore.QPoint(cx + 20, cy - 12)); at.setEndValue(QtCore.QPoint(cx + 20, cy - 80))
                ac = QtCore.QPropertyAnimation(effc, b"opacity"); ac.setDuration(duration); ac.setStartValue(1.0); ac.setEndValue(0.0)
                atx = QtCore.QPropertyAnimation(efft, b"opacity"); atx.setDuration(duration); atx.setStartValue(1.0); atx.setEndValue(0.0)
                ag = QtCore.QParallelAnimationGroup(self)
                ag.addAnimation(ap); ag.addAnimation(at); ag.addAnimation(ac); ag.addAnimation(atx)
                ag.start(QtCore.QAbstractAnimation.DeleteWhenStopped)
                try:
                    play_sound('confetti')
                except Exception:
                    pass
                QtCore.QTimer.singleShot(duration + 120, lambda: (coin.deleteLater(), txt.deleteLater()))
            except Exception:
                pass

        def show_toast(self, text, duration=2200):
            try:
                if self._toast_label.isVisible():
                    # queue it
                    self._toast_queue.append((text, duration))
                    return
                self._toast_label.setText(text)
                self._toast_label.adjustSize()
                w = self._toast_label.width(); h = self._toast_label.height()
                self._toast_label.move((self.width()-w)//2, 30)
                eff = QtWidgets.QGraphicsOpacityEffect(self._toast_label)
                self._toast_label.setGraphicsEffect(eff)
                anim = QtCore.QPropertyAnimation(eff, b"opacity")
                anim.setDuration(300)
                anim.setStartValue(0.0)
                anim.setEndValue(1.0)
                self._toast_label.show()
                anim.start()
                QtCore.QTimer.singleShot(duration, lambda: self._hide_toast())
            except Exception:
                pass

        def _hide_toast(self):
            try:
                eff = self._toast_label.graphicsEffect()
                if not eff:
                    self._toast_label.hide(); return
                anim = QtCore.QPropertyAnimation(eff, b"opacity")
                anim.setDuration(400)
                anim.setStartValue(1.0)
                anim.setEndValue(0.0)
                anim.start()
                QtCore.QTimer.singleShot(420, lambda: (self._toast_label.hide(), self._maybe_show_next_toast()))
            except Exception:
                pass

        def _maybe_show_next_toast(self):
            try:
                if self._toast_queue:
                    text, dur = self._toast_queue.pop(0)
                    self.show_toast(text, dur)
            except Exception:
                pass

        def show_controller_guide(self, show=None):
            try:
                if not hasattr(self,'_controller_guide'):
                    self._controller_guide = QtWidgets.QLabel(self)
                    self._controller_guide.setStyleSheet('background:rgba(0,0,0,0.6); color:#fff; padding:8px; border-radius:8px;')
                    self._controller_guide.setText('A:Select   B:Back   L/R:Nav   Y:Guide (toggle)')
                    self._controller_guide.adjustSize()
                    w = self._controller_guide.width(); h = self._controller_guide.height()
                    self._controller_guide.move(20, self.height() - h - 40)
                if show is None:
                    visible = not self._controller_guide.isVisible()
                else:
                    visible = bool(show)
                if visible:
                    self._controller_guide.show()
                else:
                    self._controller_guide.hide()
            except Exception:
                pass

        def update_badges(self):
            try:
                # friends online
                try:
                    friends = json.load(open(DATA / 'friends.json')) if (DATA / 'friends.json').exists() else []
                    online = sum(1 for f in friends if f.get('online'))
                except Exception:
                    online = 0
                t = self.find_tile('Amigos')
                if t:
                    t.set_badge(online if online>0 else '')
                # missions count
                try:
                    missions = json.load(open(MISSIONS_FILE)) if MISSIONS_FILE.exists() else []
                except Exception:
                    missions = []
                mcount = len(missions)
                t = self.find_tile('Misiones')
                if t:
                    t.set_badge(mcount if mcount>0 else '')
                # achievements uncompleted
                try:
                    achs = json.load(open(DATA / 'achievements.json')) if (DATA / 'achievements.json').exists() else []
                    pending = sum(1 for a in achs if not a.get('done'))
                except Exception:
                    pending = 0
                t = self.find_tile('Logros')
                if t:
                    t.set_badge(pending if pending>0 else '')
                # notifications
                try:
                    nots = json.load(open(DATA / 'notifications.json')) if (DATA / 'notifications.json').exists() else []
                    unread = sum(1 for n in nots if not n.get('read'))
                except Exception:
                    unread = 0
                t = self.find_tile('Casino')
                if t:
                    t.set_badge(unread if unread>0 else '')
                # compute deltas vs previous and show small toast for new items
                prev = self._prev_badges
                if prev.get('unread', 0) < unread and unread - prev.get('unread', 0) > 0:
                    self.show_toast(f"{unread - prev.get('unread', 0)} new messages")
                if prev.get('online', 0) < online and online - prev.get('online', 0) > 0:
                    self.show_toast(f"{online - prev.get('online', 0)} friends online")
                if prev.get('missions', 0) < mcount and mcount - prev.get('missions', 0) > 0:
                    self.show_toast(f"{mcount - prev.get('missions', 0)} new missions")
                if prev.get('ach', 0) > pending and prev.get('ach', 0) - pending > 0:
                    # achievements decreased (progress made)
                    self.show_toast('Achievement completed!')
                self._prev_badges['unread'] = unread
                self._prev_badges['online'] = online
                self._prev_badges['missions'] = mcount
                self._prev_badges['ach'] = pending
            except Exception:
                pass

        def find_tile(self, name):
            for t in self.tiles:
                if getattr(t,'name',None) == name:
                    return t
            return None

        def update_focus(self):
            if 0 <= self.current_index < len(self.tiles):
                self.tiles[self.current_index].setFocus()

        def _tile_center(self, i):
            w = self.tiles[i]
            return w.mapTo(self, w.rect().center())

        def _choose_by_direction(self, direction):
            cur = self.current_index
            curc = self._tile_center(cur)
            best = None
            best_score = None
            for i, t in enumerate(self.tiles):
                if i == cur:
                    continue
                c = self._tile_center(i)
                dx = c.x() - curc.x()
                dy = c.y() - curc.y()
                # require movement in primary direction
                if direction == 'right' and dx <= 10:
                    continue
                if direction == 'left' and dx >= -10:
                    continue
                if direction == 'down' and dy <= 10:
                    continue
                if direction == 'up' and dy >= -10:
                    continue
                if direction in ('right', 'left'):
                    score = (abs(dx), abs(dy))
                else:
                    score = (abs(dy), abs(dx))
                if best is None or score < best_score:
                    best = i
                    best_score = score
            return best

        def keyPressEvent(self, event):
            k = event.key()
            changed = False
            if k == QtCore.Qt.Key_Right:
                cand = self._choose_by_direction('right')
                if cand is not None:
                    self.current_index = cand
                    changed = True
            elif k == QtCore.Qt.Key_Left:
                cand = self._choose_by_direction('left')
                if cand is not None:
                    self.current_index = cand
                    changed = True
            elif k == QtCore.Qt.Key_Down:
                cand = self._choose_by_direction('down')
                if cand is not None:
                    self.current_index = cand
                    changed = True
            elif k == QtCore.Qt.Key_Up:
                cand = self._choose_by_direction('up')
                if cand is not None:
                    self.current_index = cand
                    changed = True
            elif k in (QtCore.Qt.Key_Enter, QtCore.Qt.Key_Return, QtCore.Qt.Key_Space):
                cur = self.current_index
                if 0 <= cur < len(self.tiles):
                        try:
                            play_sound('select')
                        except Exception:
                            pass
                        self.on_tile_clicked(self.tiles[cur].name)
            elif k == QtCore.Qt.Key_Tab:
                self.current_index = (self.current_index + 1) % len(self.tiles)
                changed = True
            elif k == QtCore.Qt.Key_Escape:
                    try:
                        play_sound('close')
                    except Exception:
                        pass
                    self.close()
            if changed:
                self.update_focus()
            else:
                super().keyPressEvent(event)

        def on_tile_clicked(self, name):
            xui = str(Path.home() / '.xui')
            if name == 'Casino':
                try:
                    play_sound('open')
                except Exception:
                    pass
                dlg = SlotMachineDialog(self)
                dlg.exec_()
            elif name == 'LAN':
                try:
                    play_sound('open')
                except Exception:
                    pass
                dlg = QtWidgets.QDialog(self)
                dlg.setWindowTitle('LAN Info')
                t = QtWidgets.QPlainTextEdit()
                t.setReadOnly(True)
                try:
                    out = subprocess.getoutput('ip -4 addr show | sed -n "1,40p"')
                except Exception:
                    out = 'Could not run ip command'
                t.setPlainText(out)
                l = QtWidgets.QVBoxLayout(dlg)
                l.addWidget(t)
                b = QtWidgets.QPushButton('Cerrar')
                b.clicked.connect(dlg.accept)
                l.addWidget(b)
                dlg.exec_()
            elif name == 'Settings':
                try:
                    play_sound('open')
                except Exception:
                    pass
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
                # Theme selector
                theme_label = QtWidgets.QLabel('Theme')
                theme_label.setStyleSheet('font-weight:bold;')
                layout.addWidget(theme_label)
                theme_combo = QtWidgets.QComboBox()
                theme_combo.addItems(['dark', 'light'])
                try:
                    s = json.load(open(SETTINGS_FILE)) if SETTINGS_FILE.exists() else {}
                    theme_combo.setCurrentText(s.get('theme', 'dark'))
                except Exception:
                    theme_combo.setCurrentText('dark')
                layout.addWidget(theme_combo)

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

                # Controller settings
                ctrl_box = QtWidgets.QGroupBox('Controller')
                ctrl_l = QtWidgets.QFormLayout()
                gp = load_settings().get('gamepad', {})
                dead = QtWidgets.QDoubleSpinBox(); dead.setRange(0.0,0.95); dead.setSingleStep(0.05); dead.setValue(float(gp.get('deadzone',0.6)))
                ri = QtWidgets.QSpinBox(); ri.setRange(50,2000); ri.setValue(int(gp.get('repeat_initial',350)))
                rr = QtWidgets.QSpinBox(); rr.setRange(20,1000); rr.setValue(int(gp.get('repeat_rate',120)))
                sel = QtWidgets.QSpinBox(); sel.setRange(0,16); sel.setValue(int(gp.get('select_btn',0)))
                backb = QtWidgets.QSpinBox(); backb.setRange(0,16); backb.setValue(int(gp.get('back_btn',1)))
                guideb = QtWidgets.QSpinBox(); guideb.setRange(0,16); guideb.setValue(int(gp.get('guide_btn',3)))
                ctrl_l.addRow('Deadzone', dead)
                ctrl_l.addRow('Repeat delay (ms)', ri)
                ctrl_l.addRow('Repeat rate (ms)', rr)
                ctrl_l.addRow('Select button id', sel)
                ctrl_l.addRow('Back button id', backb)
                ctrl_l.addRow('Guide button id', guideb)
                ctrl_box.setLayout(ctrl_l)
                layout.addWidget(ctrl_box)

                def do_save_settings():
                    try:
                        # merge with existing settings
                        cur = load_settings()
                        cur['sounds'] = bool(sounds_cb.isChecked())
                        cur['theme'] = theme_combo.currentText()
                        cur['gamepad'] = {
                            'deadzone': dead.value(),
                            'repeat_initial': ri.value(),
                            'repeat_rate': rr.value(),
                            'select_btn': sel.value(),
                            'back_btn': backb.value(),
                            'guide_btn': guideb.value()
                        }
                        save_settings(cur)
                        # apply theme immediately
                        apply_theme(QtWidgets.QApplication.instance(), cur.get('theme','dark'))
                        # update gamepad listener if present
                        try:
                            if hasattr(self, 'gpl') and self.gpl is not None:
                                self.gpl.update_settings(cur['gamepad'])
                        except Exception:
                            pass
                        dlg.accept()
                    except Exception:
                        dlg.reject()

                ok.clicked.connect(do_save_settings)
                layout.addWidget(ok)
                dlg.exec_()
            elif name == 'Misiones':
                try:
                    play_sound('open')
                except Exception:
                    pass
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
            elif name == 'Logros':
                try:
                    play_sound('open')
                except Exception:
                    pass
                dlg = QtWidgets.QDialog(self)
                dlg.setWindowTitle('Logros')
                l = QtWidgets.QVBoxLayout(dlg)
                try:
                    achs = json.load(open(DATA / 'achievements.json'))
                except Exception:
                    achs = []
                boxes = []
                for a in achs:
                    cb = QtWidgets.QCheckBox(f"{a.get('title','')} - {a.get('desc','')}")
                    cb.setChecked(bool(a.get('done', False)))
                    boxes.append((cb, a))
                    l.addWidget(cb)
                def save_achs():
                    for cb, a in boxes:
                        prev = bool(a.get('done', False))
                        now = bool(cb.isChecked())
                        a['done'] = now
                        if now and not prev and a.get('reward', 0):
                            try:
                                balf = DATA / 'saldo.json'
                                if balf.exists():
                                    d = json.load(open(balf))
                                else:
                                    d = {'balance': 0.0}
                                d['balance'] = round(d.get('balance', 0.0) + float(a.get('reward', 0)), 2)
                                json.dump(d, open(balf, 'w'))
                                # show reward animation
                                try:
                                    self.show_reward(f"+{a.get('reward',0)} €")
                                except Exception:
                                    pass
                            except Exception:
                                pass
                    try:
                        json.dump(achs, open(DATA / 'achievements.json', 'w'))
                    except Exception:
                        pass
                    QtWidgets.QMessageBox.information(dlg, 'Guardado', 'Logros actualizados')
                    dlg.accept()
                btn = QtWidgets.QPushButton('Guardar y cerrar')
                btn.clicked.connect(save_achs)
                l.addWidget(btn)
                dlg.exec_()
            elif name == 'Amigos':
                try:
                    play_sound('open')
                except Exception:
                    pass
                dlg = QtWidgets.QDialog(self)
                dlg.setWindowTitle('Amigos')
                l = QtWidgets.QVBoxLayout(dlg)
                try:
                    friends = json.load(open(DATA / 'friends.json'))
                except Exception:
                    friends = []
                for f in friends:
                    row = QtWidgets.QHBoxLayout()
                    lbl = QtWidgets.QLabel(f.get('name', 'Unknown'))
                    st = QtWidgets.QLabel('Online' if f.get('online') else 'Offline')
                    st.setStyleSheet('color:#aaf' if f.get('online') else 'color:#888')
                    row.addWidget(lbl); row.addWidget(st)
                    b = QtWidgets.QPushButton('Invitar')
                    b.clicked.connect(lambda _, n=f.get('name', ''): QtWidgets.QMessageBox.information(dlg, 'Invitado', f'Invitacion enviada a {n}'))
                    row.addWidget(b)
                    w = QtWidgets.QWidget()
                    w.setLayout(row)
                    l.addWidget(w)
                bclose = QtWidgets.QPushButton('Cerrar')
                bclose.clicked.connect(dlg.accept)
                l.addWidget(bclose)
                dlg.exec_()
            elif name in ('Salir','Salir al escritorio'):
                ok = QtWidgets.QMessageBox.question(self, 'Salir', 'Salir al escritorio y cerrar XUI?', QtWidgets.QMessageBox.Yes | QtWidgets.QMessageBox.No)
                if ok == QtWidgets.QMessageBox.Yes:
                    try:
                        play_sound('close')
                    except Exception:
                        pass
                    QtWidgets.QApplication.quit()
            else:
                candidate = os.path.join(xui, name.lower(), f"{name}.py")
                if os.path.exists(candidate):
                    try:
                        play_sound('open')
                    except Exception:
                        pass
                    QtCore.QProcess.startDetached(sys.executable, [candidate])
                else:
                    script = os.path.join(xui, 'bin', f'xui_{name.lower()}.sh')
                    if os.path.exists(script):
                        try:
                            play_sound('open')
                        except Exception:
                            pass
                        QtCore.QProcess.startDetached('/bin/sh', ['-c', script])


if __name__=='__main__':
    windowed = '--windowed' in sys.argv
    app = QtWidgets.QApplication(sys.argv)
    # apply saved theme if present
    s = load_settings()
    theme = s.get('theme', 'dark')
    apply_theme(app, theme)
    # Ensure basic data exists (achievements, friends, etc.)
    try:
        ensure_default_data()
    except Exception:
        pass
    w = MainWindow(windowed=windowed)
    try:
        if not windowed:
            w.showFullScreen()
        else:
            w.resize(1200,720)
            w.show()
    except Exception:
        w.show()
    sys.exit(app.exec_())