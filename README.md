# Forenyx AI Client (Releases)

> **芯片验证工程师专属的闭源智能编码 Agent 终端。**
> 免源码、零依赖、秒级一键极速安装与部署。

---

## 🚀 极速安装与启动 (Linux & macOS)

请在您的 Linux 或 macOS 终端中运行以下一键部署脚本：

```bash
# 1. 运行安装脚本（将自动检测架构并下载编译好的独立二进制包）
curl -fsSL https://raw.githubusercontent.com/HwJhx/forenyx-releases/main/install.sh | bash

# 2. 刷新您当前终端的环境变量（根据您使用的 Shell 选择对应的刷新命令）
source ~/.bashrc       # Bash 用户
source ~/.zshrc        # Zsh 用户
source ~/.cshrc        # Csh 用户
source ~/.tcshrc       # Tcsh 用户
# 或者直接重新打开一个新的终端窗口

# 3. 运行启动客户端
forenyx
```

---

## 🛠️ 新手配置与最佳实践向导 (SiliconFlow 极速接入)

在您首次运行 `forenyx` 后，请按照以下步骤快速完成底层大模型和极速推理配置：

### 1. 配置 API 认证
在终端命令行输入 `/login` 开启登录向导：

![01_login_cmd](./assets/01_login_cmd.png)

选择 **`Use an API key`**（使用 API 密钥验证方式）进入下一步：

![02_auth_method](./assets/02_auth_method.png)

---

### 2. 选择服务提供商
导航至 **`SiliconFlow (CN)`**，按回车键进行选择。这可以无阻碍地极速接入国内低延迟、高吞吐的高性能大模型服务。

![03_provider_select](./assets/03_provider_select.png)

---

### 3. 选择高代码能力模型
在选定提供商后弹出的模型列表中，使用键盘的方向键上下导航，选择适合芯片验证代码生成的推理模型（如 **`zai-org/GLM-5.2`**），按回车键锁定。

![07_model_select](./assets/07_model_select.png)

---

### 4. 配置输入 Key 与上下文限制
输入您的 SiliconFlow API Key，随后根据验证代码生成的实际需求，配置运行参数：
* **Context Window (上下文窗口)**：输入 `1000000` (1M 上下文)。超长上下文能够轻松吃下整个 UVM 验证环境及复杂的芯片 Spec 说明书。
* **Max Tokens (最大输出字节)**：输入 `256000` (256k 输出)，保障在生成大规模 UVM 验证案例 (Testcase) 时代码完整不截断。

> **⚠️ 注意**：此处配置的 `1000000` 和 `256000` 为当前示例模型 `GLM-5.2` 的上限参数。如果您选择了其他模型，请务必根据该模型官网发布的实际规格（如部分模型最大支持 128k 上下文或 4096 输出）进行配置，以免导致请求报错。

![04_window_setup](./assets/04_window_setup.png)

---

### 5. 优化推理响应速度 (节省 Tokens)
通过高级配置，让生成体验更清爽、更省钱：
1. 在命令行中输入 `/settings` 打开高级设置菜单：

![05_settings_cmd](./assets/05_settings_cmd.png)

2. 导航至 **`Hide thinking`** 选项，按空格键或回车键将其修改为 **`true`**：
   * *💡 提示：开启该功能后，大模型输出时会隐藏冗长的思考过程，这不仅能显著加快回复的吐字速度，还能在日常交互中节省大量的 Tokens 消耗。*

![06_hide_thinking](./assets/06_hide_thinking.png)

现在，您的 Forenyx 商业终端已全面调优完毕，可以开启高效的芯片验证辅助编码之旅！

---

## 🔄 运维命令

### 就地一键升级 (Update)
若公开仓库有最新二进制更新，无需重新跑安装脚本，在客户端任意路径输入：
```bash
forenyx update
```
脚本将自动拉取最新的 `version.json` 和对应的二进制压缩包，就地秒级平滑覆盖更新。

### 绿色自毁卸载 (Uninstall)
若您需要卸载并彻底移出环境变量，在客户端任意路径输入：
```bash
forenyx uninstall
```
客户端将自动进行环境清理并自毁，您可以自由选择是否保留您的自定义技能 (Custom Skills) 和个人历史会话记录。
