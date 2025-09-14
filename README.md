# LyricEase 登录配置工具

## 项目简介

本工具是一个用于自动配置 LyricEase 音乐播放器登录状态的 PowerShell 脚本。通过读取网易云音乐的 Cookie 信息，自动完成 LyricEase 的用户登录配置。

## 使用前准备

### 获取 Cookie 信息

1. **打开浏览器**，登录网易云音乐网页版 (music.163.com)
2. **打开开发者工具**（F12）
3. **切换到 Application/应用程序 标签页**
4. **在左侧找到 Cookies**，点击展开
5. **找到并复制以下两个 Cookie 值**：
    - `MUSIC_U`
    - `NMTID`

## 使用方法

### 第一步：配置 Cookie 文件

编辑 `cookies.json` 文件，填入你的 Cookie 信息：

```json
{
    "NMTID": "你的NMTID值",
    "MUSIC_U": "你的MUSIC_U值"
}
```

### 第二步：运行脚本

1. **以管理员身份打开 PowerShell**

    - 右键点击 PowerShell 图标
    - 选择"以管理员身份运行"

2. **导航到脚本目录**

    ```powershell
    cd path\to\LyricEaseLoginHelper
    ```

3. **执行脚本**

    ```powershell
    .\main.ps1
    ```

## 故障排除

### 常见问题

**Q: 提示"需要管理员权限"怎么办？**

A: 请右键点击 PowerShell，选择"以管理员身份运行"

**Q: 找不到 LyricEase 应用怎么办？**

A: 请确保已正确安装 LyricEase，或检查应用包名是否包含"LyricEase"

**Q: Cookie 无效怎么办？**

A: 请重新登录网易云音乐网页版，获取最新的 Cookie 信息

**Q: 脚本执行后 LyricEase 仍未登录？**

A: 请检查 Cookie 是否正确，并尝试重启 LyricEase 应用

## 免责声明

本工具仅供学习和个人使用，请遵守网易云音乐的使用条款。使用本工具所产生的任何问题，开发者不承担责任。

## 许可证信息

### 项目许可证

本项目采用 [MIT License](LICENSE) 发布。

### 第三方代码归属

本项目使用了以下开源代码片段：

-   **项目名称**: [WindowsMize](https://github.com/agadiffe/WindowsMize)
-   **作者**: agadiffe
-   **许可证**: MIT License
-   **使用的功能**: UWP 应用注册表配置函数
-   **具体文件**: `Set-UwpAppSetting.ps1` 中的 UWP 注册表操作功能
-   **用途**: 用于配置 LyricEase UWP 应用的登录设置和用户信息
-   **修改说明**: 代码已根据 LyricEase 应用的特定需求进行了适配
