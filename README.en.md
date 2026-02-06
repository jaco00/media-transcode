# 🚀 Media Compressor Pro

<p align="center">
<a href="README.md">简体中文</a> | <strong>English</strong>
</p>

An efficient media processing solution specifically designed for the Windows environment. Built with advanced algorithmic logic from senior developers and AI-assisted coding, it helps you reduce the size of massive photo and video libraries by **50%\~80%** while remaining **visually lossless**.

## ✨ Key Highlights

* 📷 **Image Evolution**:

  * Automatically converts JPEG/HEIC to **AVIF** (Next-gen image format).

  * **Color Correction**: Perfectly resolves Apple HEIC ICC color profile shift issues on Windows.

  * **Metadata Retention**: Fully preserves EXIF info, including capture time, GPS, and more.

* 🎬 **Video Re-encoding**:

  * Utilizes **H.265 (HEVC)** encoding, unified in MP4 containers.

  * Intelligent bitrate control for the optimal balance between quality and file size.

* 🛠️ **Industrial-Grade Processing**:

  * Supports **UTF-8** full paths; no garbled Chinese characters.

  * Based on PowerShell 7+ asynchronous logic to fully utilize multi-core performance.

  * Built-in conflict detection to automatically handle duplicate filenames.

## 📂 Features Overview

| Command | Mode | Description | 
 | ----- | ----- | ----- | 
| `zip` | Interactive | Process files one by one with prompts; ideal for initial quality comparison | 
| `all` | Automated | Full power mode; processes all supported media in the directory | 
| `img` | Images only | Scans and converts images to AVIF only | 
| `video` | Video only | Scans and re-encodes videos to H.265 only | 
| `comp` | Comparison | Quickly preview quality differences between source and compressed files | 
| `clean` | Cleanup | Moves source files to a backup directory and restores compressed files | 

## 💻 System Requirements

* **OS**: Windows 10 (22H2+) or Windows 11

* **Runtime**: [PowerShell 7.0+](https://github.com/PowerShell/PowerShell/releases) (Recommended)

* **Dependencies**: `ffmpeg` must be configured in the system PATH.

## 🚀 Quick Start

### 1. First Attempt (Recommended)

Run the interactive mode on a small folder first to ensure the quality meets your needs.
Converted files are saved in the same directory as the source for easy comparison. Note: HEIC files should be viewed with professional software (like XnView), as the default Windows 11 viewer may show color shifts not caused by the conversion process.

```
media.bat zip "E:\Photos"
```

### 2. Archive Cleanup

After processing, move original files to a backup drive and keep only the compressed versions in the source directory:

```
media.bat clean "E:\Photos" "F:\OriginalArchive"
```

### 3. Automated Mode

Once you trust the configuration, you can batch process the entire directory automatically:

```
media.bat all "E:\Photos" "F:\OriginalArchive"
```

### 4. Running Example

## ⚠️ Disclaimer

> **Data is priceless; proceed with caution.**
>
> Always **backup your important source files** before use. The author bears no legal responsibility for any data loss or hardware damage resulting from the use of this tool.

**Built with ❤️ by Developer & AI Collaboration**
