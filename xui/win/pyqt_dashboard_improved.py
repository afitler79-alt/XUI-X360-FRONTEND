import sys
import os
import subprocess
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

try:
    from PyQt5 import QtWidgets, QtGui, QtCore
except Exception:
    print('PyQt5 not installed')
    sys.exit(1)


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

    def update_focus(self):
        if 0 <= self.current_index < len(self.tiles):
            self.tiles[self.current_index].setFocus()

    def on_tile_clicked(self, name):
        xui = str(Path.home() / '.xui')
        if name == 'Casino':
            dlg = SlotMachineDialog(self)
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
                script = os.path.join(xui, 'bin', f'xui_{name.lower()}.sh')
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
        else:
            w.resize(1280, 768)
            w.show()
    except Exception:
        w.show()
    sys.exit(app.exec_())
