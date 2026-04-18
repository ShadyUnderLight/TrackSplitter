# TrackSplitter

> 将整轨音频+CUE 曲目表拆分为分轨文件，自动写入元数据和专辑封面。

支持 **FLAC、MP3、WAV、AIFF、ALAC、M4A、AAC、OGG、Opus** 多种格式的输入与输出（通过 `--output-format` 指定）。

## 功能一览

1. 读取整轨音频文件（支持 FLAC、MP3、WAV、AIFF、ALAC、M4A、AAC、OGG、Opus）及同名 `.cue` 曲目表
2. 解析 CUE 中的曲目标题、艺人和时间码（自动识别 Big5 / CP950 / UTF-8 编码）
3. 使用 `ffmpeg` 拆分为独立分轨文件（可保持原始格式，或通过 `--output-format` 转换为其他格式）
4. 自动抓取并嵌入专辑封面（同目录图片 → 文件内嵌封面 → MusicBrainz → iTunes，左岸音乐可选启用）
5. 写入元数据（标题、艺人、专辑、年份、风格、轨号、总轨数、封面图；字段支持情况因格式而异，详见 METADATA_MATRIX.md）

## 环境要求

- **macOS 13+**
- **ffmpeg** — `brew install ffmpeg`
- **Python 3 + mutagen** — 推荐使用虚拟环境安装：
  ```bash
  python3 -m venv ~/.tracksplitter-venv
  ~/.tracksplitter-venv/bin/pip install mutagen
  ```
  调用 `tracksplitter` 时使用该虚拟环境，或调整 PATH。

## 从源码构建

```bash
git clone https://github.com/ShadyUnderLight/TrackSplitter.git
cd TrackSplitter
swift build --configuration release
```

编译产物位于 `.build/arm64-apple-macosx/release/tracksplitter`。

## 安装到 PATH

```bash
ln -s /path/to/TrackSplitter/.build/arm64-apple-macosx/release/tracksplitter /usr/local/bin/tracksplitter
```

## 使用方式

```bash
tracksplitter "/path/to/陈升-别让我哭.flac"
tracksplitter "/path/to/陈升-别让我哭.flac" --output-format mp3
```

工具会在音频文件同目录下查找同名 `.cue` 文件，输出到以专辑名命名的子文件夹中。

```
📂 /path/to/陈升-别让我哭/
  ├── 01. 別讓我哭.flac
  ├── 02. 嘿！我要走了.flac
  └── ...
```

### 输出格式

默认保持原始格式（passthrough，无重编码）。可用 `--output-format` 指定输出格式：

| 格式 | 说明 | 备注 |
|------|------|------|
| flac | 无损压缩 | 元数据全覆盖 |
| mp3 | 有损压缩 | 元数据全覆盖，通用性最强 |
| wav | 无压缩 | 不支持封面 |
| aiff | Apple 无压缩 | 封面支持不稳定 |
| alac | Apple 无损（.m4a） | 封面支持不稳定 |
| m4a | AAC 音频 | 元数据全覆盖 |
| aac | AAC 音频（.aac） | 封面支持不稳定 |
| ogg | OGG Vorbis | 封面支持不稳定 |
| opus | Opus | 封面支持不稳定 |

元数据和封面支持详情参见 [docs/METADATA_MATRIX.md](docs/METADATA_MATRIX.md)。

## 项目结构

```
TrackSplitter/
├── Package.swift              # Swift Package Manager 清单
├── CLI/
│   └── main.swift             # 入口 + 参数解析
├── Library/                   # 核心库（CLI 和 GUI 共用）
│   ├── AudioSplitter.swift    # ffmpeg 多格式拆分调度
│   ├── CueParser.swift        # CUE 解析器（支持 Big5/CP950/UTF-8）
│   ├── AlbumArtFetcher.swift  # 封面抓取（左岸音乐 / MusicBrainz）
│   ├── MetadataEmbedder.swift # Python/mutagen 桥接（MetadataWriter 协议）
│   ├── ProcessRunner.swift     # ffmpeg/ffprobe 进程管理
│   ├── TrackSplitterEngine.swift  # 核心编排引擎
│   ├── Version.swift.in       # 版本信息模板（追踪）
│   └── Resources/
│       └── embed_metadata.py  # 元数据写入脚本（SwiftPM 资源）
├── GUI/                       # macOS GUI 应用
│   ├── App/
│   │   ├── main.swift
│   │   ├── TrackSplitterApp.swift
│   │   ├── AppState.swift
│   │   └── Info.plist
│   ├── Views/
│   │   ├── ContentView.swift
│   │   ├── DropZoneView.swift
│   │   ├── ProcessingView.swift
│   │   └── TrackListView.swift
│   ├── ViewModels/
│   │   └── SplitterViewModel.swift
│   └── Models/
│       └── SupportedAudioFormats.swift
├── Scripts/
│   └── inject_version.sh       # 版本注入脚本（构建时运行）
├── docs/
│   └── METADATA_MATRIX.md     # 各音频格式元数据支持详情
├── Tests/
│   ├── AudioSplitterTests.swift
│   ├── CueParserTests.swift
│   ├── MetadataEmbedderResultTests.swift
│   ├── MetadataEmbeddingTests.swift   # 端到端元数据写入验证
│   └── AlbumArtFetcherTests.swift
└── .github/workflows/
    ├── ci.yml                  # CI：hygiene check + 构建 + 测试
    └── release.yml             # Release：版本注入 + 构建 + 发布
```

## 技术细节

### CUE 解析
曲目表支持多编码识别（Big5 → CP950 → UTF-8），正确处理繁体中文文件名。时间码从 `MM:SS:FF`（75 帧/秒）转换为十进制秒数。

### 拆分
通过 `ffmpeg -ss / -t` 逐轨拆分，最后一轨的时长由 `ffprobe` 获取文件总时长后计算得出。

### 元数据写入
调用 Python 辅助脚本 `embed_metadata.py`（位于 `Library/Resources/`），通过 `mutagen` 库写入各格式原生标签。详见 [docs/METADATA_MATRIX.md](docs/METADATA_MATRIX.md)。

## 已知限制

- 封面抓取按优先级尝试：同目录图片 → 文件内嵌封面 → MusicBrainz → iTunes；左岸音乐默认禁用（可通过配置启用）；冷门专辑可能在所有来源均无封面
- WAV、AIFF、OGG、Opus 输出格式不支持嵌入封面（会优雅跳过）
- 各输出格式的元数据字段支持情况不同，详见 [docs/METADATA_MATRIX.md](docs/METADATA_MATRIX.md)

## 开源许可

MIT
