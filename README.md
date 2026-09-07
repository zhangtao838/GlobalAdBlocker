# GlobalAdBlocker v3.0

全局广告拦截器，iOS 越狱插件。**mmap 共享内存 + 二进制哈希表**，内存占用极低，支持导入 Loon 格式规则，按 App 单独开关。

## v3.0 更新（核心架构升级）

- **mmap 共享内存**：规则文件 mmap 映射，所有 App 进程共享同一块物理内存，不再每个进程加载一份
- **二进制哈希表**：规则预编译成二进制格式（FNV-1a 哈希 + 开放寻址法 + 后缀分桶），查找速度比 NSSet 更快
- **内存占用从 15-20MB/进程 降到 5MB 全局共享**：开 10 个 App 也只占 5MB 物理内存
- **懒加载**：只有开启了拦截的 App 才会 mmap 映射规则，未开启的 App 完全不占内存
- **规则文件外置**：`/Library/Application Support/GlobalAdBlocker/rules.bin`，Filza 可直接替换
- **导入即编译**：设置面板导入 Loon 规则时自动编译成二进制格式

## v2.0 更新

- **App 列表改用 AltList 框架**：修复 iOS 17 上 app 列表加载不出来的问题，支持搜索、分组、bundleId 副标题、应用图标

## 依赖

- `mobilesubstrate`
- `preferenceloader`
- `com.opa334.altlist`（AltList 框架，Sileo/Zebra 搜索安装）

## 规则文件

**路径**：`/Library/Application Support/GlobalAdBlocker/rules.bin`

**格式**：二进制预编译格式（不是 JSON），包含：
- 文件头（魔数、版本、规则数量、哈希表大小、分桶信息）
- 精确匹配哈希表（FNV-1a + 开放寻址法）
- 后缀匹配数组（按域名最后一个字节分 256 桶，桶内字典序排序）
- 字符串池（所有域名连续存储）

**两种更新方式**：
1. 设置 → GlobalAdBlocker → 规则管理 → 从文件导入（Loon 格式，自动编译成二进制）
2. 用 `compile_rules.py` 把 JSON 规则编译成二进制，然后 Filza 替换 `rules.bin`，点击「重新加载规则」

## 功能

- **全局广告拦截**：Hook NSURLSession，拦截广告域名请求
- **按 App 单独开关**：默认所有 App 关闭，手动开启才生效
- **导入 Loon 规则**：支持 DOMAIN / DOMAIN-SUFFIX / DOMAIN-KEYWORD 格式，导入即编译
- **实时生效**：设置变更后通过 Darwin 通知立即重新 mmap，无需注销
- **调试日志**：日志文件 `/tmp/globaladblocker.log`

## 编译规则（JSON → 二进制）

```bash
python3 compile_rules.py input.json output.bin
```

JSON 格式：
```json
{
  "exact": ["ads.example.com", "track.example.com"],
  "suffix": ["doubleclick.net", "googlesyndication.com"]
}
```

## 安装

1. 确保已安装 AltList（Sileo 搜索 `AltList`）
2. 上传到 GitHub，Actions 自动编译
3. 下载编译好的 deb，Sileo 安装，注销
4. 设置 → GlobalAdBlocker → 开启插件 → 按 App 管理里开启需要拦截的 App

## 编译

- Theos
- 架构: arm64 + arm64e
- 最低支持: iOS 15.0
- 额外框架: AltList

## 文件结构

```
GlobalAdBlocker/
├── Tweak.xm                          # 核心代码（mmap映射+二进制哈希查找+Hook）
├── GABBinaryRules.h                  # 二进制规则格式定义+查找函数（纯C，主插件和设置面板共用）
├── GABLog.h                          # 日志工具
├── compile_rules.py                  # JSON规则→二进制编译脚本
├── Makefile
├── control                           # 包信息（含 altlist 依赖）
├── GlobalAdBlocker.plist
├── prefs/                            # 设置面板
│   ├── Makefile                      # 链接 AltList
│   ├── GABBinaryRules.h              # 二进制规则定义（设置面板用）
│   ├── GABRootListController.h/m
│   ├── GABAppListController.h/m      # App 列表（继承 AltList MultiSelection）
│   ├── GABRuleManagerController.h/m  # 规则管理（导入Loon→编译二进制→保存）
│   └── Resources/
│       ├── Info.plist
│       ├── Root.plist
│       └── GABIcon.png
├── layout/
│   └── Library/
│       ├── Application Support/
│       │   └── GlobalAdBlocker/
│       │       └── rules.bin         # 默认二进制规则文件（Filza可替换）
│       └── PreferenceLoader/
│           └── Preferences/
│               └── com.globaladblocker.plist
└── .github/workflows/build.yml
```

## 许可证

MIT
