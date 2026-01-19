# Media Compression & Transcoding Tool

## 中文版

### 背景故事
由于多年来积累了大量的图片和视频资料，存储空间日益紧张，需要一个高效、可靠的压缩和归档方案。于是，我提供了核心思路与算法设计，并指导 AI 完成算法实现，最终开发出这个工具。在保证视觉无损的前提下，媒体文件通常可以压缩至原始大小的 **约 50%**。

### 工具特点
- 支持图片统一压缩为 **AVIF**，视频统一压缩为 **H.265 MP4**  
- 自动修复苹果格式图片可能存在的 ICC 色彩问题，确保转换后颜色正常  
- 保留图片的所有 **EXIF** 信息  
- 可选择交互式操作或批量自动处理  

### 系统要求
- Windows 10 或更高版本  
- PowerShell 7.0 或更高版本  
- 支持 UTF-8 路径（批处理文件已设置 `chcp 65001`）  

### 功能概览

| 命令   | 功能                                      |
|--------|-----------------------------------------|
| zip    | 交互式压缩所有媒体文件                     |
| all    | 自动处理所有媒体文件                       |
| img    | 只处理图片（转换为 AVIF）                  |
| video  | 只处理视频（编码为 H.265）                |
| comp   | 对比源文件与压缩后的质量                  |
| clean  | 压缩后删除源文件（可指定备份目录）        |

### 使用示例
```bat
media.bat zip "D:\Photos" "D:\Photos_Backup"
media.bat all "D:\Photos"
media.bat img "D:\Photos\Images"
media.bat video "D:\Photos\Videos"
media.bat comp "D:\Photos\Test"
media.bat clean "D:\Photos" "D:\Photos_Backup"
```

### 首次使用建议
- 使用交互模式：`media.bat zip <图片目录>`  
- 将源文件和转码后的文件放在同一个目录，方便效果比对  
- 默认参数下，视频和图片均接近人眼无损  
- 转码效果确认后，可使用 `media.bat clean <源目录> <备份目录>` 备份源文件  

### 免责声明
操作前请自行备份源文件，本工具不对数据丢失负责。  

---

## English Version

### Story
Over the years, a large collection of images and videos has accumulated, creating storage pressure. I provided the core ideas and algorithm design and guided AI to implement the algorithms, resulting in this tool. Under visually lossless settings, media files can typically be compressed to **around 50%** of their original size.  

### Features
- Images are uniformly compressed to **AVIF**, videos to **H.265 MP4**  
- Fixes ICC color issues in Apple image formats to maintain correct colors  
- Preserves all **EXIF** information in images  
- Supports interactive or batch processing  

### System Requirements
- Windows 10 or later  
- PowerShell 7.0 or later  
- UTF-8 path support (`chcp 65001` is set in the batch file)  

### Command Overview

| Command | Function                                  |
|---------|-------------------------------------------|
| zip     | Interactive compression for all media     |
| all     | Automatic processing of all media         |
| img     | Process images only (convert to AVIF)     |
| video   | Process videos only (encode to H.265)    |
| comp    | Compare source and compressed quality     |
| clean   | Delete source files after compression (backup optional) |

### Usage Examples
```bat
media.bat zip "D:\Photos" "D:\Photos_Backup"
media.bat all "D:\Photos"
media.bat img "D:\Photos\Images"
media.bat video "D:\Photos\Videos"
media.bat comp "D:\Photos\Test"
media.bat clean "D:\Photos" "D:\Photos_Backup"
```

### First Time Use Recommendation
- Use interactive mode: `media.bat zip <image folder>`  
- Keep source and transcoded files in the same directory for easy comparison  
- By default, video and images are visually lossless  
- Once satisfied, run `media.bat clean <source dir> <backup dir>` to back up and remove original files  

### Disclaimer
Please back up your source files before operation. The tool is not responsible for data loss.

