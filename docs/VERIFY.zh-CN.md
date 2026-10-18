# 验证构建结果

English: [VERIFY.md](VERIFY.md)

一步一步确认复刻是否成功，以及失败时去哪里查。下面的期望输出记录自参考环境（M5 Mac、macOS 27.2、Xcode 27.2、iPad Pro 11 英寸 M5、iPadOS 27.2）。

## 第一级：不需要游戏文件

```
for f in setup.sh scripts/*.sh; do bash -n "$f"; done
python3 -I -m py_compile tools/*.py && rm -rf tools/__pycache__
```

两条都应当没有任何输出。

## 第二级：需要游戏文件，不需要 iPad

| 命令 | 期望 |
|---|---|
| `./setup.sh check` | 每一行都是 `✓`，最后是"体检通过。" |
| `make fetch` | "Unity iOS 运行时已就绪"（首次需要下载 530 MB，并校验 SHA-256） |
| `make binaries` | 列出的 `GameAssembly` 依赖只有 iOS 路径（`/System/Library/Frameworks/Foundation.framework/Foundation`，没有 `Versions/`） |
| `make stubs` | 四个 framework：`GLStub`、`steam_api`、`GalaxyCSharpGlue`、`InControlNative` |
| `make project` | 三处 Trampoline 补丁已修改、BC 播放器库补丁已生成、注册了 62 个模块和 8163 个 icall、XcodeGen 完成 |
| `make build-nosign` | `** BUILD SUCCEEDED **`（播放器库的 LTO 链接需要几分钟） |
| `make data` | 约 2179 个文件：1877 个 UnityFS 包、76 个序列化文件，其余是原始数据。同一卷上几秒完成（APFS 克隆） |

## 第三级：在 iPad 上

```
make build install push-data
make smoke
```

`make smoke` 启动已安装的 App，不做任何输入，运行 75 秒；把控制台日志和每 15 秒一张的截图收集到 `build/smoke/<时间>/`，并检查：

| 检查项 | 在日志里找的标记 | 失败时去看 |
|---|---|---|
| 外壳找到游戏数据 | `[DEPort] GameData: ` | [GAME_FILES.zh-CN.md](GAME_FILES.zh-CN.md)、`make push-data` |
| icall 覆盖已安装 | `[DEPort] icall overrides installed` | 移植笔记 2.3、第四节 |
| 虚拟输入已启用 | `[DEPort] virtual input enabled` | 移植笔记第五节 |
| 屏幕按钮已挂载 | `[DEPort] touch overlay attached` | 移植笔记第五节 |
| 强制横屏 | `[DEPort] orientation: landscape autorotation` | 移植笔记第三节 |
| Unity 引擎初始化 | `Initialize engine version: ` | 移植笔记第二节、崩溃报告 |
| 全部场景加载完成 | `TOTAL SCENE LOADING took` | 移植笔记 2.6 |
| 进入主菜单 | `Scene Loading Scenes/Lobby` | 移植笔记第三、四节 |
| 相机比例铺满屏幕 | `[DEPort] aspect: wantedAspectRatio … -> ` | 移植笔记第六节 |
| HUD 框铺满屏幕 | `[DEPort] aspect: Global UI Fitter ` | 移植笔记第六节 |
| 没有 `MissingMethodException` | （不应出现） | 移植笔记 2.3 |
| 没有 `DllNotFoundException` / `EntryPointNotFoundException` | （不应出现） | 移植笔记 2.2 |
| 没有崩溃 | 除 14 以外没有 `App terminated due to signal N`（14 是计时结束） | 崩溃报告（移植笔记第七节） |
| BC 纹理走硬件 | `[DEPort] BC textures: hardware`，且没有 `decompressing texture` | 移植笔记 2.5 |

然后看截图（人工看，或者用能看图的模型）：

| 截图 | 期望 |
|---|---|
| `snap-000.jpg`（约 15 秒） | 启动阶段的画面（视时间点不同，是黑底的版权声明，或深灰底的 ZA/UM 动画）铺满整个屏幕，上下不露出任何主菜单元素 |
| `snap-003.jpg`（约 60 秒） | 横屏主菜单，油画背景铺满屏幕，没有黑边 |

参考值：主菜单内存占用约 4.9 GB，游戏中约 5.8 GB，距系统强制结束还有约 6.5 GB 余量（iPad Pro 11 英寸 M5）。

## 人工检查清单

| 操作 | 期望 |
|---|---|
| 点菜单项 | 第一次点就生效 |
| 在菜单项或物体上长按，然后滑动 | 悬停高亮跟着手指走；松手不会点下去 |
| 在游戏里对地面快速点两下 | 角色跑起来 |
| 点左侧的眼睛按钮，然后点一个对话选项 | 可交互物高亮；这一点会先松开高亮，再选中选项 |
| 看游戏里右下角的 HUD 按钮 | 落在屏幕底边那条深色装饰条上 |
| 用游戏自己的 HUD 按钮打开背包 / 日志 / 角色 | 正常打开和关闭 |
| 存档与读档 | 存档出现在读档列表里，并且能读取 |

## 自动操作

不碰设备时，`DE_AUTOTAP` 会在指定时间点击（归一化坐标，原点在左上角），配合 `DE_SNAPSHOT_EVERY` 看结果：

```
DEVICECTL_CHILD_DE_LOG_TO_CONSOLE=1 DEVICECTL_CHILD_DE_SNAPSHOT_EVERY=20 \
DEVICECTL_CHILD_DE_AUTOTAP="45:0.219,0.279" \
  perl -e 'alarm 90; exec @ARGV' xcrun devicectl device process launch --device <id> --terminate-existing --console <bundle id>
make logs     # 截图和 Player.log 会取回到 build/logs
```

菜单位置取决于状态：有存档时第一项是"继续游戏"（铺满屏幕的布局下约为 `0.219,0.279`）；没有存档时第一项是"新游戏"。先截一张图，再按图计算坐标。自动点击作用于真实的游戏和存档。
