# 用 GitHub Actions 云端编译 CR6608 固件

本机 WSL 被公司系统策略锁死，无法在本地编译。本方案把构建搬到 GitHub 的免费 Linux 服务器上，编译好后把固件下载回本机。**全程在网页点鼠标，不用装任何软件。**

---

## 你需要准备的

- 一个 GitHub 账号（没有的话去 github.com 免费注册，1 分钟）
- 5 分钟时间

---

## 第 1 步：创建仓库并上传文件

1. 打开 https://github.com/new 新建一个仓库
   - Repository name：随便填，比如 `cr6608-firmware`
   - 选 **Public**（私有仓库的 Actions 有额度限制，公有免费）
   - **不要**勾选 "Add a README file" 等任何初始化选项，要一个完全空的仓库
   - 点 **Create repository**

2. 把我给你的 `github-publish` 文件夹里的内容上传上去：
   - 在空仓库页面点击 **uploading an existing file**
   - 把 `github-publish` 文件夹里的**全部文件和文件夹**拖进去，包括：
     - `build.sh`
     - `config.env`
     - `overlay/` 文件夹（整个拖进去）
     - `.github/` 文件夹（整个拖进去，里面是工作流）
   - ⚠️ 注意：`.github` 是隐藏文件夹，拖整个文件夹进去即可，不要漏掉
   - 点 **Commit changes**

> 提交后仓库结构应该是：
> ```
> ├── .github/workflows/build.yml
> ├── build.sh
> ├── config.env
> └── overlay/etc/...
> ```

---

## 第 2 步：（重要）改密码

上传后，在仓库里点开 `config.env`，点右上角的铅笔图标编辑，把这两行的密码改成你自己的：

```
: "${ROOT_PASSWORD:=ChangeMe-2026}"     ← 改成你想要的 root 密码
: "${WIFI_PASSWORD:=ChangeMe-2026}"     ← 改成你想要的 Wi-Fi 密码
```

管理地址已经设成 `192.168.9.1`，不用改。插件清单（PassWall / SSR-Plus / TurboACC / ZeroTier）也已配好。

改完点 **Commit changes**。

---

## 第 3 步：启动编译

1. 点仓库顶部的 **Actions** 标签
2. 左侧会看到 **Build CR6608 OpenWrt Firmware**，点它
3. 右侧点 **Run workflow** → 再点绿色的 **Run workflow**
4. 开始编译，预计 **10~20 分钟**。可以点进去看实时日志

---

## 第 4 步：下载固件

1. 编译完成后（工作流显示绿色对勾），点进这次运行
2. 页面下方 **Artifacts** 区域，点 **CR6608-OpenWrt-firmware** 下载（是个 zip）
3. 解压后得到：
   - `openwrt-25.12.6-cr6608-factory.bin` ← **从原厂固件刷入用这个**
   - `openwrt-25.12.6-cr6608-sysupgrade.bin` ← 从 OpenWrt 升级用这个
   - `sha256sums.txt` 和 `package-manifest.txt`

---

## 刷机提醒

- CR6608 通常需要先解锁 SSH / 进 recovery 才能刷第三方固件，刷机前**务必备份 Bootloader、Nvram、Bdata 分区**——这台机器没有官方恢复固件。
- 首次启动后管理地址：`http://192.168.9.1`，root 密码是你在 config.env 里设的。
- PassWall 和 SSR-Plus 都装了，但**运行时只能启用一个**，否则转发规则冲突。

---

## 编译失败怎么办

把 Actions 页面里的红色错误日志截图发我，我帮你看。常见原因：
- 第三方源 `down.dllkids.xyz` 临时不可用 → 重跑一次通常就好
- 包名变更 → 我来更新 config.env
