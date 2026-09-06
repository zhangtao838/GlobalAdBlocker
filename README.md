# GlobalAdBlocker

全局广告拦截器，iOS 越狱插件。内置 20 万条广告域名规则，支持导入 Loon 格式规则，按 App 单独开关。

## 功能

- **全局广告拦截**：Hook NSURLSession，拦截广告域名请求
- **20 万条内置规则**：精确匹配 290 条 + 后缀匹配 202,375 条
- **按 App 单独开关**：默认所有 App 关闭，手动开启才生效，减小开销
- **导入 Loon 规则**：支持导入 Loon 导出的 .list / .conf 格式规则文件
- **黑白名单**：自定义白名单（不拦截）和黑名单（强制拦截）
- **实时生效**：设置变更后通过 Darwin 通知立即生效，无需注销
- **调试日志**：所有操作都有 `[GlobalAdBlocker]` 标签的日志

## 安装

1. 上传到 GitHub，Actions 自动编译
2. 下载编译好的 deb（roothide 版本用于 RootHide 设备）
3. 用 Sileo/Zebra 安装
4. 注销 SpringBoard

## 使用

1. 打开 设置 → GlobalAdBlocker
2. 开启「启用插件」总开关
3. 进入「按 App 管理」，开启需要拦截广告的 App
4. （可选）进入「规则管理」，导入 Loon 格式规则
5. （可选）进入「黑白名单」，自定义域名

## 规则导入

支持 Loon 格式的规则文件（.list / .conf），自动识别：
- `DOMAIN,example.com` → 精确匹配
- `DOMAIN-SUFFIX,example.com` → 后缀匹配
- `DOMAIN-KEYWORD,example.com` → 后缀匹配（简化处理）

导入后立即生效，所有 App 进程自动重载规则。

## 调试

日志标签：`[GlobalAdBlocker]`

用 Console.app 或 `oslog` 查看：
- 插件初始化
- 规则加载数量
- 拦截的广告域名和对应 App
- 设置变更通知

## 编译

- Theos: roothide/theos
- SDK: iPhoneOS 26.5
- 架构: arm64 + arm64e
- 最低支持: iOS 15.0

## 文件结构

```
GlobalAdBlocker/
├── Tweak.xm                          # 核心代码（规则加载+域名匹配+Hook）
├── Makefile                          # 主 Makefile（SUBPROJECTS 方式）
├── control                           # 包信息
├── GlobalAdBlocker.plist             # 注入配置（UIKit 全 App）
├── prefs/                            # 设置面板
│   ├── Makefile
│   ├── GABRootListController.h/m     # 主页面（Root.plist）
│   ├── GABAppListController.h/m      # App 列表管理
│   ├── GABRuleEditorController.h/m   # 黑白名单编辑
│   ├── GABRuleManagerController.h/m  # 规则管理（导入/恢复）
│   └── Resources/
│       ├── Info.plist
│       ├── Root.plist
│       └── GABIcon.png
├── layout/
│   └── Library/
│       ├── Application Support/
│       │   └── GlobalAdBlocker/
│       │       └── default_rules.json  # 内置规则（20万条）
│       └── PreferenceLoader/
│           └── Preferences/
│               └── com.globaladblocker.plist  # 设置入口
└── .github/workflows/build.yml       # GitHub Actions 编译
```

## 许可证

MIT
