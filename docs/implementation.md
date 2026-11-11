## 实现方式与素材来源

- **账号与启动**：SwiftUI 界面调用 CrossOver 的 Wine，在目标容器读取 Steam `loginusers.vdf`、进程与注册表。换号时备份并更新登录配置，核对 Steam 实际登录账号后用 App ID `1449850` 启动。工具依赖 Steam 自己处理密码和 Steam Guard。启动参数按当前显示模式设置，语言同步使用本机游戏设置。
- **资源复用**：使用 APFS 克隆主账号已下载的本地缓存和对应索引，按账号保留存档，并提供备份恢复。操作前核对资源路径、版本和游戏进程状态。
- **卡图与召唤动画**：通过 MDPro3 本机安装中的卡库、卡片编号映射、`Picture/Art`、`Picture/OverFrame` 和动画素材匹配大师决斗资源。以 UnityPy、Pillow 等处理贴图和 Unity 资源包，校验原始文件与生成结果，保留恢复所需的原件。动画替换用于游戏已有的召唤演出。公开源码和 DMG 不附带 MDPro3 或游戏卡图、动画、游戏资源包，也不分发 Steam 账号或本机存档。
- **动态镜碎**：换号器读取 Steam 的游戏启动日志并核对当前账号和游戏进程。CrossOver 内运行的原生加载器把渲染 DLL 加载到 `masterduel.exe`，用 MinHook 接入 IL2CPP 卡面渲染方法，为所选卡使用游戏原生镜碎材质。效果仅在本机进程显示，账号实际持有的卡片品质由游戏服务器记录。
- **桌面集成**：使用 macOS `SMAppService` 注册登录项，用系统热键接口注册 `Control + Option + M`。依赖的第三方许可随组件和 Python 依赖包保留。

## 个人使用、风险与免责声明

这是独立的个人学习和非商业使用项目，与 KONAMI、Valve、CodeWeavers 或 MDPro3 团队无关。游戏名称、卡图、动画等权利归各自权利人所有。请仅使用有权访问的本地素材，并自行确认使用方式符合游戏及平台条款。[KONAMI《大师决斗》使用条款](https://legal.konami.com/games/yugioh_masterduel/terms/tou/cs_other/en/)

本工具会写入本地 Steam 配置与游戏资源，并可在游戏进程中加载本地 DLL。游戏或 CrossOver 更新可能造成失效、崩溃、文件损坏或需要重新下载，游戏运营方也可能限制账号使用。修改前请备份，使用风险由使用者自行承担。在适用法律允许的范围内，本项目按现状提供，不保证可用性、兼容性或账号安全，作者不对使用造成的损失承担责任。

## 构建

安装 Apple Command Line Tools。运行 `./build.sh` 构建 `.app`，运行 `./test.sh` 执行本地测试，运行 `./package.sh` 生成公开版 DMG。卡图处理使用开发工具提供的 `/usr/bin/python3`，构建时会下载 Python 依赖，并用 llvm-mingw 构建镜碎组件。

需要生成个人闪刀快捷素材包时，在开发虚拟环境安装 `UnityPy==1.23.0`，运行 `python Scripts/generate_sky_striker.py <主账号的0000目录> <MDPro3目录> build/sky-striker`。将生成的文件夹复制为 `~/Library/Application Support/MD Switcher/SkyStriker` 即可在已安装的应用中使用。该素材包仅保存在本机。
