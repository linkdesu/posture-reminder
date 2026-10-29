# 占位音频片段

本目录存放两族生成的占位音频。两族都不是最终录音：每个文件都是柔和的合成音，唯一作用是让构建产物带有真实的内置资源。它们刻意不含语音。

- **体态提醒**——六个文件，每个可发声体态一个（`near` … `chin_rest`）。这些是**孩子侧语音行的占位文件**，将在录音阶段替换，由产品负责人（Link）连同语音录音一起负责；任何人都不应把它们作为孩子侧语音发布。最终集合必须是温柔的真人语音行，每个体态一条，以相同文件名放入。
- **番茄钟结束提示音**——两个文件，`end_soft.wav` 与 `end_chime.wav`。这些是**番茄钟的阶段结束提示音，不是体态提醒**：番茄钟界面从 `EndSound` 设置（`soft` / `chime` / `none`）选择一个，并把对应的 `PomodoroCue` 交给 `ReminderPlayer.play(cue:)`，由它加载并开始片段。它们绝不会作为体态提示音播放——体态路径无法触达它们——即使同一个播放器拥有两者。`none` 不选择任何提示音，也没有文件。

不要把两族混淆。体态片段回答“你坐姿不对，坐直”；结束提示音回答“这个专注段结束了”。它们只共享格式，不共享其他任何东西。

设置页的**试听**使用同一条播放路径（`ReminderPlayer.preview(cue:)`），播放当前选中的结束提示音，但它不启动番茄钟，也不写 `cue_played`：那一行只属于计时器真正响起的时刻。

## 文件命名契约

两条命名规则，每族一条：

- **体态片段**恰好是 `<PostureKind.rawValue>.wav`，每个可发声体态一个（六个非实验级体态），`ReminderPlayer` 按该名称查找片段。
- **结束提示音**恰好是 `end_<EndSound.rawValue>.wav`：默认平静音是 `end_soft.wav`，更明亮的选择是 `end_chime.wav`。这两个名称也是 `PomodoroCue` 的 rawValue（`soft` 与 `chime` 是两个命名文件的 `EndSound` case），播放器按该值查找片段。`EndSound.none` 没有文件，因为“没有声音”就是静音，不是资源。

| 族 | 用途 | 文件 | 占位音 |
|---|---|---|---|
| 体态 | `near` 的提醒 | `near.wav` | C5，523.25 Hz |
| 体态 | `head_down` 的提醒 | `head_down.wav` | G4，392.00 Hz |
| 体态 | `head_tilt` 的提醒 | `head_tilt.wav` | A4，440.00 Hz |
| 体态 | `shoulder_tilt` 的提醒 | `shoulder_tilt.wav` | F4，349.23 Hz |
| 体态 | `desk_lean` 的提醒 | `desk_lean.wav` | E4，329.63 Hz |
| 体态 | `chin_rest` 的提醒 | `chin_rest.wav` | D5，587.33 Hz |
| 结束音 | 番茄钟结束音，`EndSound.soft`（默认） | `end_soft.wav` | 一个低音，G3，196.00 Hz |
| 结束音 | 番茄钟结束音，`EndSound.chime` | `end_chime.wav` | 两个上行铃音，G5 783.99 Hz 后接 C6 1046.50 Hz |

实验级体态（`head_forward`、`slouch`）没有片段，也永不触发任何提醒；为它们添加文件不会产生效果。结束提示音没有体态，只由 `EndSound` 设置选择。

替换录音必须保持相同文件名与扩展名。如果格式改变，`ReminderPlayer.clipExtension` 是唯一需要修改的地方，并且每个文件都必须随之改变——缺失的体态片段会记为 `speech_unavailable` 且不播放任何声音；缺失的结束提示音不播放任何声音，也不写 `cue_played` 行。

## 格式：使用 WAV，而不是 m4a

PRD 两者都允许。这里使用 WAV，因为标准库的 `wave` 模块无需外部工具即可生成，因此占位文件在任何装有 Python、没有音频依赖的机器上都能逐字节复现。这些是一次性占位文件，所以更大的体积（每个约 52 KB）无关紧要；最终录音如果录音流程更偏好 m4a，可以使用 m4a。

## 重新生成

全部八个文件由一个确定性脚本生成：没有随机性、没有第三方音频库，因此在任何装有 Python 的机器上重跑都会复现已提交的字节。

每个文件都是 16 位单声道、22.05 kHz、1.2 秒，峰值幅度为满刻度的 0.18（每个片段的峰值样本为 5898），带平缓的升余弦起音与释音，因此没有爆音。

- 六个**体态**片段是单正弦，起音 0.12 秒、释音 0.30 秒。
- `end_soft` 也是单低正弦，但起音更慢（0.30 秒）、释音 0.45 秒——同一形状被拉长，因此听起来比任何提醒都更平静、更低。
- `end_chime` 是两个重叠的铃音（基频加较弱的二、三次谐波），每个都有 0.012 秒快速起音与指数衰减，并在音符最后 0.06 秒做锥形收尾，避免音符边界爆音；随后整对音归一化回与其他文件相同的 0.18 峰值。它刻意比所有体态片段更明亮、更高。

```python
import math, struct, wave, os

SAMPLE_RATE = 22050
DURATION = 1.2
ATTACK = 0.12
RELEASE = 0.30
PEAK = 0.18

clips = {
    "near": 523.25,
    "head_down": 392.00,
    "head_tilt": 440.00,
    "shoulder_tilt": 349.23,
    "desk_lean": 329.63,
    "chin_rest": 587.33,
}

frames = int(SAMPLE_RATE * DURATION)

def write_wav(name, samples):
    with wave.open(os.path.join("PostureLab/Resources/Audio", name + ".wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(struct.pack("<%dh" % len(samples), *samples))

def sine(freq, attack, release):
    """整段片段长度上的单正弦，带升余弦起音与释音。"""
    out = []
    for i in range(frames):
        t = i / SAMPLE_RATE
        if t < attack:
            env = 0.5 - 0.5 * math.cos(math.pi * t / attack)
        elif t > DURATION - release:
            env = 0.5 - 0.5 * math.cos(math.pi * (DURATION - t) / release)
        else:
            env = 1.0
        out.append(math.sin(2 * math.pi * freq * t) * env)
    return out

# 体态提醒：每个可发声体态一条正弦。
for name, freq in clips.items():
    write_wav(name, [int(round(v * PEAK * 32767)) for v in sine(freq, ATTACK, RELEASE)])

# 番茄钟结束提示音。不是体态提醒；只由番茄钟界面播放。
# end_soft：默认平静音——比提醒更慢起音的低正弦。
write_wav("end_soft", [int(round(v * PEAK * 32767)) for v in sine(196.00, 0.30, 0.45)])

# end_chime：两个明亮铃音，第二个与第一个重叠，归一化到 PEAK。
NOTE_DURATION = 0.75
NOTE_ATTACK = 0.012
NOTE_TAIL = 0.06
DECAY = 0.30

def bell(freq, u):
    if u < 0 or u >= NOTE_DURATION:
        return 0.0
    env = math.exp(-u / DECAY)
    if u < NOTE_ATTACK:
        env *= 0.5 - 0.5 * math.cos(math.pi * u / NOTE_ATTACK)
    tail = NOTE_DURATION - u
    if tail < NOTE_TAIL:
        env *= 0.5 - 0.5 * math.cos(math.pi * tail / NOTE_TAIL)
    return env * (math.sin(2 * math.pi * freq * u)
                  + 0.30 * math.sin(4 * math.pi * freq * u)
                  + 0.10 * math.sin(6 * math.pi * freq * u))

chime = [bell(783.99, i / SAMPLE_RATE) + bell(1046.50, i / SAMPLE_RATE - 0.45)
         for i in range(frames)]
peak = max(abs(v) for v in chime)
write_wav("end_chime", [int(round(v / peak * PEAK * 32767)) for v in chime])
```

`project.yml` 包含 `PostureLab` 下的所有内容，因此这些文件会自动打包。
