# -*- mode: python ; coding: utf-8 -*-

a = Analysis(
    ['run.py'],
    pathex=[],
    binaries=[],
    datas=[
        ('assets', 'assets'),
        ('whisprflow', 'whisprflow'),
    ],
    hiddenimports=[
        'rumps',
        'pynput',
        'pynput.keyboard',
        'pynput.keyboard._darwin',
        'sounddevice',
        'soundfile',
        'numpy',
        'ollama',
        'anthropic',
        'groq',
        'httpx',
        'httpcore',
        'anyio',
        'AppKit',
        'Foundation',
        'Quartz',
        'mlx',
        'mlx_whisper',
        'tiktoken',
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=['tkinter', 'matplotlib', 'test', 'unittest'],
    noarchive=False,
    optimize=0,
)

pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='WhisprFlow',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    icon='assets/WhisprFlow.icns',
)

coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name='WhisprFlow',
)

app = BUNDLE(
    coll,
    name='WhisprFlow.app',
    icon='assets/WhisprFlow.icns',
    bundle_identifier='com.whisprflow.app',
    info_plist={
        'CFBundleName': 'WhisprFlow',
        'CFBundleDisplayName': 'WhisprFlow',
        'CFBundleVersion': '1.0.0',
        'CFBundleShortVersionString': '1.0.0',
        'LSMinimumSystemVersion': '13.0',
        'LSUIElement': True,
        'NSMicrophoneUsageDescription': 'WhisprFlow needs microphone access for voice dictation.',
        'NSAppleEventsUsageDescription': 'WhisprFlow needs accessibility to paste text at your cursor.',
    },
)
