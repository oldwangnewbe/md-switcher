## 实现方式与素材来源

- **账号与启动**：macOS 通过 CrossOver 的 Wine 操作目标容器，Windows 直接使用本机 Steam。两端读取 Steam 的 `loginusers.vdf`，换号时备份并更新登录配置，核对 Steam 实际登录账号后用 App ID `1449850` 启动。密码和 Steam Guard 由 Steam 处理。
- **资源复用**：macOS 使用 APFS 克隆。Windows 可在同一 NTFS 卷上用目录联接共享 `0000` 缓存，也可保留独立缓存，用 NTFS 硬链接或受支持的 ReFS 块克隆补齐原版资源。操作前核对资源路径、版本和游戏进程状态。详见 [Windows 资源说明](../Windows/README.md)。
- **卡图与卡片演出**：通过 MDPro3 本机安装中的卡库、卡片编号映射、`Picture/Art`、`Picture/OverFrame` 和演出素材匹配大师决斗资源。以 UnityPy、Pillow 等处理贴图和 Unity 资源包，校验原始文件与生成结果，保留恢复所需的原件。支持替换已有的召唤或发动演出，以及为有可用素材的卡新增召唤演出。公开源码和安装包不附带 MDPro3 或游戏卡图、演出、游戏资源包，也不分发 Steam 账号或本机存档。
- **动态镜碎**：工具读取 Steam 的游戏启动日志并核对当前账号和游戏进程。两端共用 Windows 原生加载器，把渲染 DLL 加载到 `masterduel.exe`，用 MinHook 接入 IL2CPP 卡面渲染方法，为所选卡使用游戏原生镜碎材质。效果仅在本机进程显示，账号实际持有的卡片品质由游戏服务器记录。
- **桌面集成**：使用 macOS `SMAppService` 注册登录项，用系统热键接口注册 `Control + Option + M`。依赖的第三方许可随组件和 Python 依赖包保留。

## 个人使用、风险与免责声明

这是独立的个人学习和非商业使用项目，与 KONAMI、Valve、CodeWeavers 或 MDPro3 团队无关。游戏名称、卡图、动画等权利归各自权利人所有。请仅使用有权访问的本地素材，并自行确认使用方式符合游戏及平台条款。[KONAMI《大师决斗》使用条款](https://legal.konami.com/games/yugioh_masterduel/terms/tou/cs_other/en/)

本工具会写入本地 Steam 配置与游戏资源，并可在游戏进程中加载本地 DLL。游戏或 CrossOver 更新可能造成失效、崩溃、文件损坏或需要重新下载，游戏运营方也可能限制账号使用。修改前请备份，使用风险由使用者自行承担。在适用法律允许的范围内，本项目按现状提供，不保证可用性、兼容性或账号安全，作者不对使用造成的损失承担责任。

## 构建

安装 Apple Command Line Tools。运行 `./build.sh` 构建 `.app`，运行 `./test.sh` 执行本地测试，运行 `./package.sh` 生成公开版 DMG。卡图处理使用开发工具提供的 `/usr/bin/python3`，构建时会下载 Python 依赖，并用 llvm-mingw 构建镜碎组件。

在 macOS 上安装 .NET 10 SDK 和带 pip 的 Python，运行 `bash Windows/build.sh` 交叉构建 Windows x64 ZIP。

需要生成个人闪刀快捷素材包时，在开发虚拟环境安装 `UnityPy==1.23.0`，运行 `python Scripts/generate_sky_striker.py <主账号的0000目录> <MDPro3目录> build/sky-striker`。将生成的文件夹复制为 `~/Library/Application Support/MD Switcher/SkyStriker` 即可在已安装的应用中使用。该素材包仅保存在本机。
