# TrackSplitter

> 按章节（内置章节、CUE 曲目表或文本格式）拆分整轨音频文件，自动写入元数据和专辑封面。

支持 **FLAC、MP3、WAV、AIFF、M4A、AAC、OGG、Opus** 多种格式的输入与输出（通过 `--output-format` 指定）。

## 功能一览

1. **多来源章节**：
   - 读取整轨音频文件（支持 FLAC、MP3、WAV、AIFF、ALAC、M4A、AAC、OGG、Opus）
   - 自动检测同目录 `.cue` / `.qcue` 曲目表（自动识别 Big5 / CP950 / UTF-8 编码）
   - 读取音频文件**内嵌章节**（`--chapter-source embedded`）
   - 支持文本格式章节文件和 FFmpeg `CHAPTER*` 元数据文件（`--chapter-file <path>`）
2. **灵活拆分**：使用 `ffmpeg` 逐轨拆分，可保持原始格式（passthrough），或通过 `--output-format` 转换为其他格式
3. **自动封面抓取**（按优先级尝试）：本地目录图片 → 文件内嵌封面 → MusicBrainz → iTunes → LeftFM（默认关闭，可配置启用）
4. **元数据写入**：标题、艺人、专辑、年份、风格、轨号、总轨数、碟号（视输出格式而异，详见 [docs/METADATA_MATRIX.md](docs/METADATA_MATRIX.md)）

## 环境要求

- **macOS 13+**
- **ffmpeg** — `brew install ffmpeg`
- **Python 3 + mutagen**：
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
# 默认行为：自动查找同目录 .cue 曲目表
tracksplitter "/path/to/陈升-别让我哭.flac"

# 指定输出格式
tracksplitter "/path/to/陈升-别让我哭.flac" --output-format mp3

# 从音频文件内嵌章节读取
tracksplitter "/path/to/album.flac" --chapter-source embedded

# 使用文本/FFmpeg 章节文件
tracksplitter "/path/to/album.flac" --chapter-file /path/to/chapters.txt
```

工具会在音频文件同目录下查找同名 `.cue` 文件，输出到以专辑名命名的子文件夹中。

```
📂 /path/to/陈升-别让我哭/
  ├── 01. 別讓我哭.flac
  ├── 02. 嘿！我要走了.flac
  └── ...
```

### 章节来源

| 方式 | 说明 |
|------|------|
| `--chapter-source auto` | 自动检测同目录 .cue 文件（默认） |
| `--chapter-source embedded` | 读取音频文件内嵌章节标记 |
| `--chapter-source cue` | 通过文件选择器指定 CUE 文件 |
| `--chapter-file <path>` | 指定章节定义文件（见下节）|

### 章节文件格式

`--chapter-file` 支持以下文件类型：

**纯文本格式**（每行 `HH:MM:SS 标题`，前导 `-` 或 `[]` 可选）：

```
00:00:00 Track 1 Title
00:03:45 - Track 2 Title
[00:07:30] Track 3 Title
```

**FFmpeg `CHAPTER*` 元数据格式**（`.meta` / `.ffmetadata`）：

```
;FFMETADATA1
CHAPTER0000=00:00:00.000
CHAPTER0000NAME=Track 1 Title
CHAPTER0001=00:03:45.000
CHAPTER0001NAME=Track 2 Title
```

**CUE / QCOW 格式**：`.cue` / `.qcue` 文件

### 输出格式

默认保持原始格式（passthrough，无重编码）。可用 `--output-format` 指定输出格式：

| 格式 | 说明 | 封面支持 | 元数据覆盖 |
|------|------|----------|------------|
| flac | 无损压缩 | ✅ | 全面 |
| mp3 | 有损压缩 | ✅ | 全面 |
| wav | 无压缩 | ❌ | 基础（ffmpeg -metadata） |
| aiff | Apple 无压缩 | ❌ | 基础（ID3 chunk） |
| alac | Apple 无损（.m4a） | ❌（按封面数据来源） | 全面 |
| m4a | AAC 音频 | ✅ | 全面 |
| aac | AAC 音频（.aac） | ❌ | 基础 |
| ogg | OGG Vorbis | ❌ | 基础 |
| opus | Opus | ❌ | 基础 |

封面和元数据的详细支持情况因格式而异，详见 [docs/METADATA_MATRIX.md](docs/METADATA_MATRIX.md)。

## 项目结构

```
TrackSplitter/
├── Package.swift              # Swift Package Manager 清单
├── CLI/
│   └── main.swift             # 入口 + 参数解析
├── Library/                   # 核心库（CLI 和 GUI 共用）
│   ├── TrackSplitterEngine.swift  # 核心编排引擎
│   ├── AudioSplitter.swift    # ffmpeg 多格式拆分调度
│   ├── CueParser.swift        # CUE 解析器（支持 Big5/CP950/UTF-8）
│   ├── ChapterSource.swift    # 章节来源枚举与解析
│   ├── EmbeddedChapterReader.swift  # 内嵌章节读取（ffprobe）
│   ├── TextChapterParser.swift # 纯文本与 FFmpeg 章节文件解析
│   ├── AlbumArtFetcher.swift  # 封面抓取（本地目录/内嵌/MusicBrainz/iTunes/LeftFM）
│   ├── MetadataEmbedder.swift # Swift/mutagen 桥接层
│   ├── ProcessRunner.swift    # ffmpeg/ffprobe 进程管理
│   └── Resources/
│       └── embed_metadata.py  # Python 元数据写入脚本（SwiftPM 资源）
├── GUI/                       # macOS GUI 应用（Tauri + SwiftUI）
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
│   └── METADATA_MATRIX.md     # 各音频格式元数据与封面支持详情
├── Tests/
│   ├── AudioSplitterTests.swift
│   ├── CueParserTests.swift
│   ├── MetadataEmbedderResultTests.swift
│   ├── MetadataEmbeddingTests.swift
│   ├── AlbumArtFetcherTests.swift
│   └── ChapterParserTests.swift
└── .github/workflows/
    ├── ci.yml                  # CI：hygiene check + 构建 + 测试
    └── release.yml             # Release：版本注入 + 构建 + 发布
```

## 技术细节

### 章节解析

- **CUE**：支持 Big5 → CP950 → UTF-8 多编码识别，时间码从 `MM:SS:FF`（75 帧/秒）转换为十进制秒数
- **内嵌章节**：通过 `ffprobe` 读取音轨的 `CHAPTER` 标记
- **文本章节**：解析 `HH:MM:SS`（2 段 = 分钟:秒，3 段 = 时:分:秒）和 `[HH:MM:SS]` 两种格式
- **FFmpeg 元数据**：解析 `CHAPTER*=` 时间戳与 `CHAPTER*NAME=` 标题

### 拆分

通过 `ffmpeg -ss / -t` 逐轨拆分，最后一轨的时长由 `ffprobe` 获取文件总时长后计算得出。

### 元数据写入

调用 Python 辅助脚本 `embed_metadata.py`（位于 `Library/Resources/`），通过 `mutagen` 库写入各格式原生标签。详见 [docs/METADATA_MATRIX.md](docs/METADATA_MATRIX.md)。

### 封面抓取顺序

1. **本地目录图片**（始终优先，无网络请求，按文件大小选取最大 jpg/png）
2. **文件内嵌封面**（直接从音频文件中读取）
3. **MusicBrainz / Cover Art Archive**（可靠 API）
4. **iTunes Search API**（可靠 API）
5. **LeftFM**（默认关闭，需设置 `config.enableLeftFM = true`；通过 HTML 抓取，不可靠）

## 已知限制

- **封面**：WAV、AIFF、AAC、OGG、Opus 输出格式不支持嵌入封面（会优雅跳过）；部分格式封面支持因数据来源而异
- **CUE 编码**：罕见编码仍可能解析失败；文件建议保存为 UTF-8
- **内嵌章节**：需要音轨本身包含 `CHAPTER` 标记；不同格式支持情况不同
- **LeftFM**：默认禁用，抓取不稳定且使用 HTTP，建议使用 MusicBrainz 或 iTunes 代替
- 各输出格式的元数据字段支持情况不同，详见 [docs/METADATA_MATRIX.md](docs/METADATA_MATRIX.md)

## 开源许可

MIT
