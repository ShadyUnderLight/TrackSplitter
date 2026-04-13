# TrackSplitter

> 将 FLAC+CUE 整轨专辑拆分为分轨文件，自动写入元数据和专辑封面。

## 功能一览

1. 读取 `.flac` 整轨文件及其对应的 `.cue` 曲目表
2. 解析 CUE 中的曲目标题和时间码
3. 使用 `ffmpeg` 将 FLAC 拆分为独立的分轨文件
4. 自动从网上抓取并嵌入专辑封面（支持 leftfm.com、MusicBrainz、iTunes）
5. 写入完整元数据：标题、艺人、专辑、年份、风格、轨号、总轨数、封面图

## 环境要求

- **macOS 13+**
- **ffmpeg** — `brew install ffmpeg`
- **Python 3 + mutagen** — `pip3 install mutagen --break-system-packages`

## 从源码构建

```bash
git clone https://github.com/ShadyUnderLight/TrackSplitter.git
cd TrackSplitter
swift build --configuration release
```

编译产物位于 `.build/arm64-apple-macosx/release/tracksplitter`。

## 安装到 PATH

```bash
ln -s ~/.swift/projects/TrackSplitter/.build/arm64-apple-macosx/release/tracksplitter /usr/local/bin/tracksplitter
```

## 使用方式

```bash
tracksplitter "/path/to/陈升-别让我哭.flac"
```

工具会在 FLAC 文件同目录下查找同名 `.cue` 文件，输出到以专辑名命名的子文件夹中。

```
📂 /path/to/陈升-别让我哭/
  ├── 01. 別讓我哭.flac
  ├── 02. 嘿！我要走了.flac
  ├── 03. Vivien.flac
  └── ...
```

## 项目结构

```
TrackSplitter/
├── Package.swift              # Swift Package Manager 清单
├── CLI/
│   └── main.swift             # 入口 + 参数解析
├── Library/
│   ├── CueParser.swift        # CUE 解析器（支持 Big5/UTF-8）
│   ├── AlbumArtFetcher.swift  # 封面抓取（leftfm / MusicBrainz / iTunes）
│   ├── FLACSplitter.swift     # ffmpeg 拆分调度
│   ├── MetadataEmbedder.swift # Python/mutagen 桥接
│   └── TrackSplitterEngine.swift  # 核心编排引擎
└── Resources/
    └── embed_metadata.py      # FLAC 元数据写入脚本
```

## 技术细节

### CUE 解析
CUE 曲目表支持多编码识别（Big5 → CP950 → UTF-8），正确处理繁体中文文件名。时间码从 `MM:SS:FF`（75 帧/秒）转换为十进制秒数。

### 拆分
通过 `ffmpeg -ss / -t` 逐轨拆分，最后一轨的时长由 `ffprobe` 获取文件总时长后计算得出。

### 元数据写入
调用 Python 辅助脚本 `embed_metadata.py`，通过 `mutagen` 库写入 FLAC Vorbis 标签并将 JPEG 封面嵌入文件 Picture 区块。

## 已知限制

- 仅支持 FLAC 输出（MP3/AAC 转换尚未实现）
- ffmpeg 和 python3 必须可用（GUI 版本会自动查找 homebrew 路径）
- 封面抓取来源为 leftfm.com / MusicBrainz / iTunes，部分冷门专辑可能抓取失败

## 开源许可

MIT
