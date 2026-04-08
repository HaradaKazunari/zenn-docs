---
title: "Webカメラだけで物理マウスを捨てる - NonMouseをM2 Mac + Python 3.14で再起動して自分用にチューニングした話"
emoji: "🖐️"
type: "tech"
topics: ["python", "macos", "mediapipe", "opencv", "hack"]
published: true
publication_name: "three_dots_inc"
---

:::message
この記事は [Claude Code](https://claude.ai/code) を使用して記述しています。
:::

## はじめに

机の上から物理マウスを追放したい、という個人的な欲求からこの作業は始まりました。トラックパッドでは長時間作業がつらく、かといってトラックボールも据え置き感があって「キーボードから手を離して別のデバイスを触る」という体験そのものを消したかったのです。

そこで見つけたのが、Webカメラ + MediaPipe Hands で手のランドマークを検出し、指の動きでマウスカーソルを動かす OSS [takeyamayuki/NonMouse](https://github.com/takeyamayuki/NonMouse) でした。コンセプトは完璧なのですが、M2 MacBook (Apple Silicon) + Python 3.14 という手元の環境ではそのままでは 1 mm も動きません。しかも動かしたあとも「自分の手」に合わせ込むまでのチューニングが必要でした。

この記事は「動かしました」の報告ではなく、ハマり所を全部潰して最終的に物理マウスを本当に外せるところまで持っていった記録です。ターゲット読者は次のような方です。

- macOS で脱マウスしたい人
- mediapipe を自分の用途に使いたい人
- OSS を自分の環境に合わせ込むパーソナルハックが好きな人

前提環境:

- MacBook Air M2 / macOS
- Python 3.14 (pyenv)
- 内蔵 / 外付け Webカメラ どちらでも可 (1080p60 が出ると快適)

## 1. NonMouse と今回のゴール

NonMouse は Webカメラに映った手を MediaPipe Hands で検出し、指先や手のひら中心の座標変化をマウスカーソルの移動量に変換するツールです。本家のデフォルトでは、ピンチ (親指と人差し指をくっつける) をクリックに割り当てるなど、ジェスチャだけで完結する設計になっています。

最終的に私が落ち着いた操作体系は以下です。

- `Command` **押下中のみ** カーソル移動 (手のひら中心 = `landmark[9]` で追従)
- `Alt` **押下中のみ** スクロール (手の y 変位)
- `Command + 左 Shift` = 左クリック
- `Command + k` = 右クリック

ジェスチャでクリックを取るのは、後述する通り誤検出の地獄でした。結局「キー押下中だけ手の動きを読む」という押下トグル方式に倒したのが今回のいちばん大きな設計判断です。

作業リポジトリはローカルの `non-mouse/` で、主な変更ファイルは `nonmouse/__main__.py` / `nonmouse/args.py` / `requirements.txt` の 3 つです。

## 2. M2 Mac + Python 3.14 で動かすまで

ここが一番ハマりました。本家 `requirements.txt` は Intel Mac + Python 3.9 時代のピン留めで固定されており、Apple Silicon + 3.14 では片っ端から `pip install` が失敗します。

### 2-1. 依存関係を最小下限指定に刷新

旧 `requirements.txt` はおおよそこんな感じで固定されていました。

```txt:requirements.txt (before)
mediapipe==0.8.10
numpy==1.19.3
opencv-python==4.5.1.48
pynput==1.7.4
pyobjc-core==7.3
pyobjc-framework-Cocoa==7.3
# ...
```

これを「Apple Silicon の wheel が存在する下限」だけ指定する形に書き直しました。

```txt:requirements.txt (after)
# tested on python==3.13 / 3.14 (Apple Silicon / Intel)
# numpy / protobuf の下限は mediapipe の依存解決に任せる
mediapipe>=0.10.18
numpy
opencv-python>=4.10
opencv-contrib-python>=4.10
pynput>=1.7.7
protobuf
pyinstaller>=6.10
pyobjc-core>=10.3; sys_platform == 'darwin'
pyobjc-framework-Cocoa>=10.3; sys_platform == 'darwin'
pyobjc-framework-Quartz>=10.3; sys_platform == 'darwin'
pyobjc-framework-ApplicationServices>=10.3; sys_platform == 'darwin'
```

ポイントは「**バージョンを固定しない**」ことです。mediapipe 側が numpy/protobuf の要求を厳しく持っているので、こちらで下限を切るとすぐ解決不能になります。mediapipe の下限だけを切り、あとは pip の依存解決に任せるのが一番安全でした。

### 2-2. pyenv で tcl-tk リンク付きビルド

次にハマったのが `tkinter` です。本家は設定 GUI を tkinter で書いているのですが、pyenv で Python 3.14 を普通にインストールすると tcl-tk がリンクされず、起動直後に `ModuleNotFoundError: No module named '_tkinter'` で死にます。

Homebrew で `tcl-tk` を入れてから、以下の環境変数を渡して pyenv で再ビルドします。

```bash
brew install tcl-tk

# M2 Mac (Apple Silicon) での例
export PATH="$(brew --prefix tcl-tk)/bin:$PATH"
export LDFLAGS="-L$(brew --prefix tcl-tk)/lib"
export CPPFLAGS="-I$(brew --prefix tcl-tk)/include"
export PKG_CONFIG_PATH="$(brew --prefix tcl-tk)/lib/pkgconfig"
export PYTHON_CONFIGURE_OPTS="--with-tcltk-includes='-I$(brew --prefix tcl-tk)/include' \
  --with-tcltk-libs='-L$(brew --prefix tcl-tk)/lib -ltcl9.0 -ltk9.0'"

pyenv install 3.14.0
```

ただ、このルートは環境再現性が低く、チーム共有のリポジトリとしては辛いです。結局後述するように `tkinter` 依存を外して TUI 化したので、tcl-tk リンクビルドは**歴史的経緯**として残しておけばよく、実行時には不要になります。

### 2-3. mediapipe 0.10 系で legacy solutions API が消えた

依存を入れ直したあと、本家の `import mediapipe.solutions.hands as mp_hands` で `AttributeError` が出ました。調べると、Apple Silicon wheel の `mediapipe >= 0.10.x` では legacy の `mp.solutions` API 群が同梱されておらず、公式は **Tasks API (`HandLandmarker`)** への移行を推奨しています。

というわけで、本家の hands 呼び出し全部を Tasks API に書き換えます。

```python:nonmouse/__main__.py
import mediapipe as mp
from mediapipe.tasks import python as mp_python
from mediapipe.tasks.python import vision as mp_vision
from mediapipe.tasks.python.vision import drawing_utils as mp_drawing
from mediapipe.tasks.python.vision import HandLandmarksConnections

# ...

hand_options = mp_vision.HandLandmarkerOptions(
    base_options=mp_python.BaseOptions(model_asset_path=MODEL_PATH),
    running_mode=mp_vision.RunningMode.VIDEO,
    num_hands=1,
    min_hand_detection_confidence=HAND_CONFIDENCE,
    min_hand_presence_confidence=HAND_CONFIDENCE,
    min_tracking_confidence=HAND_CONFIDENCE,
)
detector = mp_vision.HandLandmarker.create_from_options(hand_options)
```

Tasks API は VIDEO モードで使う場合、**単調増加のタイムスタンプ** を渡す必要があります。そうしないと `Input timestamp must be monotonically increasing` で落ちます。フレームごとに整数をインクリメントするだけで十分です。

```python:nonmouse/__main__.py
ts_ms = 0
while cap.isOpened():
    # ... (キャプチャ&前処理)
    mp_image = mp.Image(
        image_format=mp.ImageFormat.SRGB,
        data=np.ascontiguousarray(image),
    )
    ts_ms += 1
    results = detector.detect_for_video(mp_image, ts_ms)
    for hand_landmarks in (results.hand_landmarks or []):
        ...
```

また Tasks API では、検出モデルファイル (`hand_landmarker.task`) を自前で配置する必要があります。ユーザーに手動ダウンロードを強いるのは避けたかったので、初回起動時に `~/.cache/nonmouse/` へ自動ダウンロードする実装を入れました。

```python:nonmouse/__main__.py
MODEL_URL = (
    "https://storage.googleapis.com/mediapipe-models/"
    "hand_landmarker/hand_landmarker/float16/1/hand_landmarker.task"
)
MODEL_PATH = os.path.join(
    os.path.expanduser("~/.cache/nonmouse"), "hand_landmarker.task"
)


def _ensure_model():
    if not os.path.exists(MODEL_PATH):
        os.makedirs(os.path.dirname(MODEL_PATH), exist_ok=True)
        print(f"Downloading hand landmarker model to {MODEL_PATH} ...")
        urllib.request.urlretrieve(MODEL_URL, MODEL_PATH)
```

ここまでで「とりあえず M2 + 3.14 で import が通って、手のランドマークが返ってくる」状態にはなりました。次は設定 UI です。

## 3. GUI を捨てて TUI にする

先ほど書いたように、pyenv でビルドした Python には tkinter が入っていないことがあります。それに環境を汚したくありません。本家 `args.py` は tkinter で設定ダイアログを出していたのですが、これを `input()` ベースの TUI に全面置き換えしました。

```python:nonmouse/args.py
def _ask_int(prompt, default, lo, hi):
    while True:
        raw = input(f"{prompt} [{default}]: ").strip()
        if raw == "":
            return default
        try:
            v = int(raw)
        except ValueError:
            print(f"  -> 整数を入力してください ({lo}-{hi})")
            continue
        if lo <= v <= hi:
            return v
        print(f"  -> {lo}-{hi} の範囲で入力してください")


def tk_arg():
    print("================ NonMouse Setup ================")
    print("  Enter キーでデフォルト値を採用します")
    print("-------------------------------------------------")

    print("[Camera]")
    cap_device = _ask_int("  Device number (0-9)", default=1, lo=0, hi=9)

    print("\n[How to place]")
    print("  0 = Normal  (正面から自分を撮影)")
    print("  1 = Above   (手の真上から撮影)")
    print("  2 = Behind  (背後からディスプレイ方向を撮影)")
    mode = _ask_int("  Placement (0-2)", default=1, lo=0, hi=2)

    print("\n[Sensitivity]")
    kando_raw = _ask_int("  Sensitivity", default=70, lo=1, hi=100)
    kando = kando_raw / 10

    print("\n[Preview]")
    show_preview = _ask_yesno("  Show preview?", default=False)

    screenRes = _get_screen_size()
    return cap_device, mode, kando, screenRes, show_preview
```

関数名を `tk_arg` のまま残しているのは、呼び出し元の差分を小さくする保守的な判断です (本当は `setup()` などにリネームしたいところ)。

画面解像度の取得も tkinter に頼っていたので、OS ごとにフォールバックする実装に差し替えました。

```python:nonmouse/args.py
def _get_screen_size():
    p = platform.system()
    if p == "Darwin":
        try:
            from Quartz import CGDisplayBounds, CGMainDisplayID
            bounds = CGDisplayBounds(CGMainDisplayID())
            return int(bounds.size.width), int(bounds.size.height)
        except Exception:
            pass
    elif p == "Windows":
        try:
            import ctypes
            user32 = ctypes.windll.user32
            user32.SetProcessDPIAware()
            return user32.GetSystemMetrics(0), user32.GetSystemMetrics(1)
        except Exception:
            pass
    elif p == "Linux":
        try:
            import subprocess, re
            out = subprocess.check_output(["xrandr"], stderr=subprocess.DEVNULL).decode()
            for line in out.splitlines():
                if " connected" in line:
                    m = re.search(r"(\d+)x(\d+)", line)
                    if m:
                        return int(m.group(1)), int(m.group(2))
        except Exception:
            pass
    return 1920, 1080  # フォールバック
```

なお現在の実装では、`screenRes` は取得しているものの実際のカーソルクランプは OS 任せにしており、内部では使っていません。ログ表示用に残している状態です。

プレビュー表示 (`show_preview`) はデフォルト OFF にしています。本番運用時は HUD を出さず軽く動かし、チューニング時だけ ON にする運用です。

## 4. 操作体系の設計 - ジェスチャを諦めてキーボードに逃がす

ここが設計上の最大の判断ポイントです。

### 4-1. 最初はピンチ / 指立てを試した

本家どおり、最初はジェスチャだけで完結させようと思っていました。

- **ピンチ (親指 + 人差し指)** = 左クリック
- **指立て 3 本** = 右クリック
- **指立て 5 本** = スクロール開始

ところが、実際に作業しながら使うと誤検出が多すぎて破綻します。具体的には:

- **カーソルを動かす動き自体がピンチに見える**: 指を軽く曲げるだけで親指と人差し指の距離が一気に縮み、クリックが暴発する
- **タイピング姿勢からの遷移で手形状が安定しない**: 5 本指を広げた状態と 3 本指のカウントが頻繁に誤分類される
- **手の回転 / 奥行きに弱い**: カメラに対して手を傾けるとランドマーク間距離が相対的に変わり、閾値ベースのピンチ判定が崩れる

結局「キーボードから手を離さずに物理マウスを捨てる」という最初のモチベーションと、ジェスチャで全部やる方針は相性が悪かったのです。

### 4-2. 押下トグル方式へ倒す

発想を変えて、**キーが押されている間だけ手の動きを読む** 押下トグル方式にしました。

- `Command` を押している間だけカーソル移動を行う
- `Alt` を押している間だけスクロールを行う
- `Command` を押している状態で `左 Shift` を叩けば左クリック、`k` を叩けば右クリック

こうすると、通常のキーボード操作中はカメラが何を検出していてもカーソルが動きません。誤検出ゼロで、かつ「マウスしたい瞬間だけ手を浮かせる」という自然なワークフローに寄せられます。

実装は `pynput` のグローバルキーリスナで状態をポーリングします。

```python:nonmouse/__main__.py
from pynput import keyboard as pkeyboard

_cmd_pressed = {"v": False}
_alt_pressed = {"v": False}
_click_events = {"left": False, "right": False}


def _is_cmd(key):
    if platform.system() == "Darwin":
        return key in (pkeyboard.Key.cmd, pkeyboard.Key.cmd_l, pkeyboard.Key.cmd_r)
    else:
        # Linux/Windows には Command がないので Alt で代替
        return key in (pkeyboard.Key.alt, pkeyboard.Key.alt_l, pkeyboard.Key.alt_r)


def _is_alt(key):
    if platform.system() == "Darwin":
        return key in (pkeyboard.Key.alt, pkeyboard.Key.alt_l, pkeyboard.Key.alt_r)
    else:
        return key in (pkeyboard.Key.ctrl, pkeyboard.Key.ctrl_l, pkeyboard.Key.ctrl_r)


def _on_press(key):
    if _is_cmd(key):
        _cmd_pressed["v"] = True
    if _is_alt(key):
        _alt_pressed["v"] = True
    # 左 Shift でも左クリック発火 (cmd 押下中のみ)
    if key == pkeyboard.Key.shift_l and _cmd_pressed["v"]:
        _click_events["left"] = True
    ch = getattr(key, "char", None)
    if ch == "k" and _cmd_pressed["v"]:
        _click_events["right"] = True


def _on_release(key):
    if _is_cmd(key):
        _cmd_pressed["v"] = False
    if _is_alt(key):
        _alt_pressed["v"] = False


key_listener = pkeyboard.Listener(on_press=_on_press, on_release=_on_release)
key_listener.daemon = True
key_listener.start()
```

ポイントは `_click_events` をエッジイベントとして扱うことです。メインループ側で 1 回消費したらフラグを落とすので、長押ししても連打になりません。また `cursor_mode` (= Command 押下中) が離れたタイミングで `_click_events` を強制的にクリアし、誤発火を防いでいます。

```python:nonmouse/__main__.py
cursor_mode = _cmd_pressed["v"]
scroll_mode = _alt_pressed["v"] and not cursor_mode
if not cursor_mode:
    _click_events["left"] = False
    _click_events["right"] = False
    i = 0            # カーソル再アンカー待ち
if not scroll_mode:
    prev_middle_y = None
```

macOS 以外では Command キーが存在しないため、Linux / Windows では `Alt` をカーソル、`Ctrl` をスクロールにフォールバックしています。

## 5. カーソル挙動のチューニング

ここからが本題です。普通に手の座標変化をマウスに流し込んでも「遅い」「滑る」「縦横のスピードが違う」「画面端で戻すと空走りする」といった問題が次々出ます。これを HUD ログを見ながら 1 つずつ潰していきました。

### 5-1. 相対移動アンカー方式

絶対座標 (カメラ画角 → スクリーン座標) にマッピングすると、サブディスプレイの境界をまたいで動かせなかったり、スクリーン比率とカメラ比率の差で変な領域ができたりします。

そこで、**Command を押した瞬間の手位置を `preX / preY` に記録し、次フレーム以降は差分を累積して `mouse.move(dx, dy)` に流す** 相対移動方式にしました。これならサブディスプレイを自由に越境できます。

```python:nonmouse/__main__.py
if cursor_mode:
    if i == 0:
        for _lst in (LiTx, LiTy, list0x, list0y, list1x, list1y):
            _lst.clear()
        preX = hand_landmarks[9].x
        preY = hand_landmarks[9].y
        i += 1

    nowX = calculate_moving_average(hand_landmarks[9].x, ran, LiTx)
    nowY = calculate_moving_average(hand_landmarks[9].y, ran, LiTy)
    raw_dx = (nowX - preX) * image_width
    raw_dy = (nowY - preY) * image_height
    preX = nowX
    preY = nowY
```

追従点に使っているのは `landmark[9]` (中指 MCP = 手のひら中心) です。指先 (8 や 12) は曲げ伸ばしで座標がブレやすく、手のひら中心のほうが安定してカーソル追従できます。

### 5-2. 非線形加速カーブ

線形にマッピングすると、細かい作業をするにはゲインを下げないといけないのに、画面端から端まで動かすにはゲインを上げないといけない、というジレンマが発生します。これは macOS のマウス加速と同じ話です。

そこで、ゲインを「速く動かすほど指数的に伸びる」形にしました。

```python:nonmouse/__main__.py
# カーソル移動の加速カーブ設定
DEADZONE_PX = 0.2        # これ以下の指移動は無視 (ジッター抑制)
ACCEL_POWER = 1.4        # 非線形加速指数 (>1 で大きく振るほど指数的に速くなる)

# ...
speed = float(np.hypot(raw_dx, raw_dy))
if speed <= DEADZONE_PX:
    dx = 0.0
    dy = 0.0
else:
    effective = speed - DEADZONE_PX
    amplified = base_gain * (effective ** ACCEL_POWER)
    scale = amplified / speed
    dx = raw_dx * scale
    dy = raw_dy * scale
```

`ACCEL_POWER = 1.4` は私の環境での実測値で、もう少し上げると「軽く振っただけで画面の端に飛ぶ」感覚になり、下げると「画面端まで届かせるのに何度もアンカーをリセットしたくなる」感じでした。

`base_gain` は TUI の Sensitivity (1-100) をそのまま使うのではなく、`kando * 2.0` で加速カーブ向けの係数に変換しています。

### 5-3. 軸別ゲイン

次に気になったのが「横方向の動きが縦方向より遅い」ことです。これは単に自分の手の動かし方のクセで、水平に振るより垂直に振るほうが大きく動いてしまうのが原因でした。

HUD に `avgOut` (出力 dx/dy の絶対値平均) を出して、1 分間普段使いしたときの比率を測ったところ、縦 `61.2` に対して横 `55.5` という数字が出ました。そこで横方向だけ 10% ブーストします。

```python:nonmouse/__main__.py
# 実測: 右/左 out_x=55.5, 上/下 out_y=61.2 → x を 10% ブースト
AXIS_GAIN_X = 1.10
AXIS_GAIN_Y = 1.00

# ...
dx *= AXIS_GAIN_X
dy *= AXIS_GAIN_Y
```

「自分の手に合わせ込む」と書いてきましたが、その実体はこういう数字いじりです。この係数は私の手と私の机の位置でしか最適ではないので、読者の皆さんは後述する HUD を見て自分の数字を決めてください。

### 5-4. 方向別ゲイン (上下 / 左右の非対称)

さらに測ると、**同じ縦方向でも上と下で速度が違う** ことが分かりました。カメラが手の真上に置いてある Above モードだと、下方向 (画面下) に動かすときの手の動きがどうしても小さくなるのです。

```python:nonmouse/__main__.py
# 方向別ゲイン: 実測 上 out_y=69.78, 下 out_y=52.55 → 下方向を 1.33 倍
GAIN_Y_UP = 1.00
GAIN_Y_DOWN = 1.33
GAIN_X_LEFT = 1.00
GAIN_X_RIGHT = 1.00

# ...
if dx >= 0:
    dx *= GAIN_X_RIGHT
else:
    dx *= GAIN_X_LEFT
if dy >= 0:
    dy *= GAIN_Y_DOWN   # 画像座標系は下が正
else:
    dy *= GAIN_Y_UP
```

このレベルの補正を入れて初めて、「カーソルが自分の手と同じスピードで動いている」という一体感が出ました。

### 5-5. 画面端スナップ

相対移動方式で一番厄介なのが **画面端の戻し** です。右端までカーソルを押し付けた状態で、さらに右に手を動かしてしまうと `preX` だけはどんどん右に進みます。そのあと手を左に戻しても、「右に進めすぎた分」を打ち消すまでカーソルが反応しない、いわゆる空走り状態になります。

これを防ぐには、「dx を出しているのに実際のカーソルは動いていない」状態を検知して、`preX / preY` をそのフレームの手位置にスナップし直します。

```python:nonmouse/__main__.py
pos_before = mouse.position
mouse.move(dx, dy)
pos_after = mouse.position
actual_dx = pos_after[0] - pos_before[0]
actual_dy = pos_after[1] - pos_before[1]

# dx が有意に出ているのに画面は動いていない → その向きは画面端
# preX をスナップし、次フレーム以降その方向への累積を止める
if abs(dx) >= 1.0:
    if (dx > 0 and actual_dx <= 0) or (dx < 0 and actual_dx >= 0):
        preX = hand_landmarks[9].x
if abs(dy) >= 1.0:
    if (dy > 0 and actual_dy <= 0) or (dy < 0 and actual_dy >= 0):
        preY = hand_landmarks[9].y
```

`mouse.position` を move の前後で測り、カーソルが進んでいなければ「その軸は画面端」と判定して preX/preY を現在の手位置にリセットします。これで手を戻した瞬間に即座に逆方向の移動が始まります。

### 5-6. 軸反転フラグ

カメラの置き方によっては画像が 180° 回転しているため、手の動きに対してカーソルが逆方向に飛びます。Above モードは特にこれが顕著です。

```python:nonmouse/__main__.py
INVERT_CURSOR_X = True
INVERT_CURSOR_Y = True

# ...
if INVERT_CURSOR_X:
    raw_dx = -raw_dx
if INVERT_CURSOR_Y:
    raw_dy = -raw_dy
```

モードごとに自動判定してもよかったのですが、カメラの物理的な取り付け向きによる要素も大きいので「フラグで一発反転」のほうが結局便利でした。

## 6. 微動を消す 4 段フィルタ

チューニングの 2 番目の軸がジッター対策です。MediaPipe の手ランドマークは、動いていないつもりでもサブピクセルレベルで常に揺れます。この揺れをそのままマウスに流すと、カーソルが静止してくれず、文字を選択しようとすると数文字ずれたりします。

これに対しては 4 段構えのフィルタを入れました。

```python:nonmouse/__main__.py
# ハンド検出/追跡の信頼度 (大きいほど誤検出が減る)
HAND_CONFIDENCE = 0.9

# スムージング窓フレーム数 (大きいほど滑らかだが遅延が増える)
SMOOTHING_FRAMES = 6

# これ以下の指移動は無視 (加速前のデッドゾーン)
DEADZONE_PX = 0.2

# 最終的な dx/dy がこれ未満ならゼロに丸める
OUTPUT_MIN_PX = 0.0
```

それぞれ役割が違います。

| 段 | 何を抑えるか | 副作用 |
|---|---|---|
| `HAND_CONFIDENCE` | 低品質な検出そのものを捨てる | 高すぎると手のロストが増える |
| `SMOOTHING_FRAMES` | フレーム間の高周波ノイズ | 大きいと操作感が重くなる |
| `DEADZONE_PX` | 加速前に静止判定 | 大きいと微細な調整が効かない |
| `OUTPUT_MIN_PX` | 1px 以下の出力を丸めて完全静止 | 0 でも十分なら 0 で良い |

私の環境では `HAND_CONFIDENCE=0.9` / `SMOOTHING_FRAMES=6` / `DEADZONE_PX=0.2` で、`OUTPUT_MIN_PX` はゼロ (つまり丸めなし) が一番自然でした。`SMOOTHING_FRAMES` は 10 を超えると明確に遅延を感じます。

## 7. デバッグ HUD - 目で見てチューニングする

ここまで「実測値を見ながら係数を決めた」と何度か書いてきました。その実測値を出すための HUD がこれです。プレビュー窓に raw / dx-dy / speed / avgRaw / avgOut / axis / dir / 各モード・各アクションの ACTIVE 状態を全部オーバーレイします。

```python:nonmouse/__main__.py
hud_lines = [
    (f"MODE  : {mode_str}", mode_color),
    (f"ACTIVE: {active_str}", (0, 255, 255)),
    ("-- CURSOR ({}) --".format(CURSOR_HOTKEY_NAME), (255, 255, 0)),
    (f"raw   : ({dbg['raw'][0]:+6.2f},{dbg['raw'][1]:+6.2f}) px", (255, 255, 0)),
    (f"dx/dy : ({dbg['dxdy'][0]:+6.2f},{dbg['dxdy'][1]:+6.2f}) px", (255, 255, 0)),
    (f"speed : {dbg['speed']:6.2f}  gain={base_gain:.2f}", (255, 255, 0)),
    (f"avgRaw: ({dbg['avg_raw'][0]:+6.2f},{dbg['avg_raw'][1]:+6.2f}) |abs|=({dbg['avg_abs_raw'][0]:5.2f},{dbg['avg_abs_raw'][1]:5.2f})", (200, 200, 255)),
    (f"avgOut: ({dbg['avg_dxdy'][0]:+6.2f},{dbg['avg_dxdy'][1]:+6.2f}) |abs|=({dbg['avg_abs_dxdy'][0]:5.2f},{dbg['avg_abs_dxdy'][1]:5.2f})", (200, 200, 255)),
    (f"axis  : x={AXIS_GAIN_X:.2f} y={AXIS_GAIN_Y:.2f}", (200, 200, 255)),
    (f"dir   : L={GAIN_X_LEFT:.2f} R={GAIN_X_RIGHT:.2f} U={GAIN_Y_UP:.2f} D={GAIN_Y_DOWN:.2f}", (200, 200, 255)),
    (f"cursor: {'ACTIVE' if act['cursor'] else 'idle'}", (0, 255, 0) if act['cursor'] else (180, 180, 180)),
    # ... CLICK / SCROLL セクション
]
```

`avgRaw / avgOut` が係数決定の主役です。1 分ほど普段使いしたあとで `|abs|` の値を見ると、自分の手が縦横どちらにバイアスを持っているかが一目で分かります。あとは `AXIS_GAIN_X/Y` と `GAIN_X_LEFT/RIGHT/GAIN_Y_UP/DOWN` をそれらが同じくらいになるまで調整するだけです。

もう一つ工夫しているのが **ACTIVE ラッチ** です。カーソル移動・左クリック・右クリック・スクロールの発火は一瞬で過ぎてしまうので、そのままだと HUD では視認できません。そこで、発火時刻 + 保持時間 (0.4 秒) を記録しておき、その期間内なら HUD 上で「ACTIVE」と光らせます。

```python:nonmouse/__main__.py
ACTIVE_HOLD_S = 0.4
active_until = {"cursor": 0.0, "lclick": 0.0, "rclick": 0.0, "scroll": 0.0}

# 発火時にタイムスタンプを書き込む
if _click_events["left"]:
    _click_events["left"] = False
    mouse.click(Button.left)
    active_until["lclick"] = time.perf_counter() + ACTIVE_HOLD_S

# HUD 描画時に判定
_now = time.perf_counter()
act = {k: 1 if _now < v else 0 for k, v in active_until.items()}
```

これで「Command+左Shift 叩いたのに左クリック発火してる？」を目で確認できます。操作体系のデバッグで本当に助かりました。

本番運用時はこの HUD を OFF にしておく運用です。先述した TUI で `Show preview?` を No にすると、`draw_circle` を含むオーバーレイ処理を no-op 化して CPU をケチっています。

```python:nonmouse/__main__.py
if show_preview:
    _draw_circle = draw_circle
else:
    def _draw_circle(*_a, **_kw):
        pass
```

## 8. 運用してみて

数日間、物理マウスを抜いて生活してみました。

**良かった点:**

- キーボードのホームポジションから手を離さずにマウス操作ができる感覚は想像以上に快適
- ブラウジングや記事閲覧程度ならほぼ不満なし
- ウィンドウ操作 (Mission Control を開いてワークスペース切り替え、など) は指ジェスチャより圧倒的に速くなる

**ツラい点:**

- **細かいドラッグ** (テキスト選択、範囲選択) はまだ Command 押しっぱなしで手を動かす必要があり、手が震えると切れる
- **長時間** 手を浮かせ続けると腕が疲れる (物理マウスを握るほうが実は省エネ)
- **画像編集・お絵かき** のような連続ドラッグは論外

現状「普段のコーディング + ブラウジングは脱マウスできる、クリエイティブ作業は物理デバイスに戻る」という使い分けに落ち着いています。

残課題:

- ドラッグ操作を別ジェスチャに割り当てる (Command 長押し + 手の動き、など)
- 手のロストからの復帰時間をもう少し短くする
- マルチディスプレイでの ACCEL カーブ再調整

## 9. まとめ

この記事で一番伝えたかったのは、「OSS を動かす」と「自分の手に合わせ込む」は完全に別物だということです。NonMouse はコンセプトとしては 2 年以上前から存在する完成されたアイデアですが、手元の環境で物理マウスを本当に外すところまで持っていくには、依存関係の再構築・API 移行・TUI 化・操作体系の再設計・加速カーブのチューニング・HUD の整備、という 6 つ全部をやる必要がありました。

逆に言えば、ここまでやれば OSS は自分の日常に組み込めます。この記事に出てきた係数 (`ACCEL_POWER=1.4`, `AXIS_GAIN_X=1.10`, `GAIN_Y_DOWN=1.33`, `SMOOTHING_FRAMES=6` …) はすべて私の手と机と M2 MacBook の組み合わせでの最適値です。読者の皆さんは HUD を見ながら、自分の数字を決めてみてください。それが「自分用ハック」の一番楽しいところです。

---

本記事は個人的な作業記録として AI 支援 (Claude Code) を使って執筆しています。コードスニペットはすべて手元で実際に動いている実装からの引用です。
