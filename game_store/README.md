# Xbox 360 Homebrew Games Store

Herramienta automática para descargar e instalar juegos homebrew de Xbox 360 desde una tienda de juegos centralizada.

## 🎮 Características

- ✅ Descarga automática desde Google Drive
- ✅ Descompresión automática (ZIP, TAR, 7z)
- ✅ Soporte para múltiples formatos de archivo
- ✅ Barra de progreso de descarga
- ✅ Reintentos automáticos en caso de error
- ✅ Disponible en Shell Script y Python

## 📋 Requisitos

### Para Shell Script (download_games.sh)
```bash
# Dependencias:
- bash
- curl
- unzip (para archivos ZIP)
- 7z (para archivos 7-ZIP, opcional)
- tar (para archivos TAR, opcional)
```

### Para Python (download_games.py)
```bash
# Python 3.6+
# No requiere dependencias externas (usa módulos estándar)
```

## 🚀 Uso

### Opción 1: Usando Python (Recomendado)

```bash
# Hacer ejecutable
chmod +x game_store/download_games.py

# Ejecutar
python3 game_store/download_games.py

# O directamente
./game_store/download_games.py
```

### Opción 2: Usando Shell Script

```bash
# Hacer ejecutable
chmod +x game_store/download_games.sh

# Ejecutar
bash game_store/download_games.sh

# O directamente
./game_store/download_games.sh
```

## 📂 Estructura de Directorios

Después de ejecutar el descargador:

```
.
├── games/           # Juegos descomprimidos listos para usar
├── downloads/       # Archivos temporales de descarga
└── game_store/      # Scripts del descargador
    ├── download_games.py
    ├── download_games.sh
    ├── xui360repo.txt  # (generado automáticamente)
    └── README.md
```

## 🎯 Cómo Funciona

1. **Descarga la lista**: Lee `xui360repo.txt` desde el repositorio XUI_360GAMES_REP
2. **Procesa enlaces**: Extrae los IDs de Google Drive de cada enlace
3. **Descarga juegos**: Descarga cada archivo desde Google Drive
4. **Descomprime**: Detecta el formato y descomprime automáticamente
5. **Organiza**: Coloca los juegos listos en la carpeta `games/`

## 📝 Formato de xui360repo.txt

El archivo debe contener enlaces de Google Drive, uno por línea:

```
https://drive.google.com/file/d/12OhLJDgLgmnA2Qy6cM836W38qrnwdEel/view?usp=sharing
https://drive.google.com/file/d/AnotherFileID12345678901234567/view?usp=sharing
...
```

### Comentarios permitidos:
```
# Esto es un comentario
# Los comentarios se ignoran automáticamente
```

## ⚙️ Opciones Avanzadas

### Python: Personalizar rutas

Edita `download_games.py` y modifica:

```python
self.repo_url = "https://raw.githubusercontent.com/..."
self.games_dir = Path("./tu_ruta_de_juegos")
self.downloads_dir = Path("./tu_ruta_de_descargas")
```

### Shell: Personalizar rutas

Edita `download_games.sh` y modifica:

```bash
REPO_URL="https://raw.githubusercontent.com/..."
GAMES_DIR="./tu_ruta_de_juegos"
DOWNLOADS_DIR="./tu_ruta_de_descargas"
```

## 🔧 Solución de Problemas

### Error: "Permiso denegado"
```bash
chmod +x game_store/download_games.py
chmod +x game_store/download_games.sh
```

### Error: "curl: command not found"
```bash
# Linux/Debian
sudo apt-get install curl

# macOS
brew install curl

# Use el script de Python en su lugar
```

### Error: "No se puede descargar desde Google Drive"
- Verifica que los enlaces sean públicos
- Verifica tu conexión a Internet
- Los archivos muy grandes pueden requerir más tiempo

### Los archivos no se descomprimen
Instala las herramientas de descompresión:
```bash
# Linux
sudo apt-get install unzip p7zip-full

# macOS
brew install p7zip
```

## 📊 Monitoreo

El script mostrará:
- ✅ Descargas exitosas con tamaño del archivo
- ⏳ Porcentaje de progreso de descarga
- ✓ Archivos descomprimidos correctamente
- ✗ Errores con detalles

## 🎮 Juegos Soportados

La tienda funciona con cualquier juego homebrew de Xbox 360 en formato:
- `.zip` o `.rar` (comprimidos)
- `.tar.gz` o `.tar.bz2` (archivos tar)
- `.7z` (7-ZIP)
- Formatos directos (sin compresión)

## 📱 Integración con XUI

Los juegos descomprimidos en `games/` están listos para:
1. Copiar a tu dispositivo Xbox 360
2. Integrar con el dashboard XUI
3. Usar con cualquier administrador de juegos

## 📞 Soporte

Para reportar problemas o sugerir mejoras:
- Abre un issue en el repositorio
- Verifica la lista de juegos disponibles en XUI_360GAMES_REP

---

**Nota**: Todos los juegos son homebrew. Respeta los derechos de autor del contenido.
